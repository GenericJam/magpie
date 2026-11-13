// Magpie's MIDI plumbing on Android (android.media.midi). No MIDI byte passes
// through the BEAM: what arrives goes straight to the magpie_audio NIF's C
// (nativeIn, with its timestamp), and what Magpie sends comes from the NIF's
// sending thread (send, with the CLOCK_MONOTONIC time it is heard at).
//
// 1. The Magpie port: MagpieMidiService is a MidiDeviceService with one input
//    port (other apps send to Magpie: notes, clock) and one output port
//    (other apps listen: pads' notes, Magpie's clock), both "Magpie". Android
//    binds the service in the app's process when an app opens a port.
// 2. Devices: a MidiManager.DeviceCallback reports devices plugged in or
//    removed ("added" / "removed"); open(id) opens one both ways (every
//    output port connected to a receiver feeding nativeIn, input port 0 for
//    send) and reports "opened" or "open_failed"; close(id) closes it. Which
//    devices to open is Magpie.Midi's policy, in Elixir.
// 3. Bluetooth-MIDI (ported from Humdinger's bridge): a BLE scan for the
//    BLE-MIDI service and MidiManager.openBluetoothDevice, which makes the
//    peripheral a MIDI device ("added", type bluetooth) every app can see.
//
// The natives are registered by c_src/magpie_audio.c, which finds this class
// through the activity's class loader, then calls attach(); nothing is
// handed to them before that. Events go to the NIF as (tag, JSON as UTF-8
// bytes) and on to Magpie.Midi as {:magpie_midi, tag, json}.
package com.genericjam.magpie.midi

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.LocationManager
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiDeviceService
import android.media.midi.MidiDeviceStatus
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.io.Closeable
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONObject

object MagpieMidi : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    private const val TAG = "MagpieMidi"

    // Registered by magpie_audio.c. `source` picks the C parser (0: the port,
    // 1..15: an opened device's output ports, one each). A source gets a new,
    // higher `generation` when a port takes it, when it is given back, and
    // (the port) when its service is created or a sender opens or closes its
    // input (renew), and C hears of it (nativeActivate) before that port can
    // deliver: C parses under the source's lock only the current generation's
    // bytes, from a fresh parser (a closed port's thread may still deliver a
    // last message), and ends the voices the source's earlier port held
    // (unplugged mid-note).
    @JvmStatic external fun nativeIn(source: Int, generation: Long, data: ByteArray, offset: Int, count: Int, timestamp: Long)

    @JvmStatic external fun nativeActivate(source: Int, generation: Long)

    @JvmStatic external fun nativeEvent(tag: String, json: ByteArray)

    private const val SOURCES = 16

    // The Bluetooth-SIG BLE-MIDI service (MIDI over Bluetooth LE spec).
    private const val BLE_MIDI_SERVICE = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700"
    private const val BLUETOOTH_CAPABILITY = "midi_bluetooth"

    // MidiDeviceInfo property holding a MidiDeviceService's ServiceInfo
    // (PROPERTY_SERVICE_INFO, hidden from the SDK's android.jar).
    private const val PROPERTY_SERVICE_INFO = "service_info"

    private val main = Handler(Looper.getMainLooper())

    @Volatile private var appContext: Context? = null

    // The natives are registered: bytes and events may go to C.
    @Volatile private var attached = false

    // ── The Magpie port ─────────────────────────────────────────────────────

    @Volatile private var service: MagpieMidiService? = null
    @Volatile private var portSenders = 0
    @Volatile private var portListeners = 0

    internal fun serviceCreated(s: MagpieMidiService) {
        service = s
    }

    internal fun serviceDestroyed(s: MagpieMidiService) {
        if (service === s) {
            service = null
            portStatus(0, 0)
        }
    }

    // A sender opened or closed the port's input: the next one gets a fresh
    // parser, and what the last one held ends (renew). With no sender left the
    // receiver keeps its old generation, so a closed client's bytes still in
    // the port's socket are dropped; the next sender's open (before it gets
    // the port) gives it the new one. The receiver is shared, so one client
    // of several closing renews it at once (a late message of that client's
    // would be parsed).
    internal fun portStatus(senders: Int, listeners: Int) {
        if (senders != portSenders) synchronized(sourceLock) { renew(0, receiver = senders > 0) }
        portSenders = senders
        portListeners = listeners
        event("port", JSONObject().put("inputs", senders).put("outputs", listeners))
    }

    // `generation` changes only for the port's receiver (renew(0)); a device
    // port's receiver is replaced instead.
    internal class Receiver(val source: Int, @Volatile var generation: Long) : MidiReceiver() {
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            if (attached && count > 0) nativeIn(source, generation, msg, offset, count, timestamp)
        }
    }

    // ── Bridge ──────────────────────────────────────────────────────────────

    @JvmStatic
    fun register() {}

    // MobActivityAware: MainActivity.onCreate, main thread.
    override fun setActivity(activity: Activity) {
        appContext = activity.applicationContext
        watchDevices()
    }

    override fun permissionsFor(cap: String): Array<String>? =
        if (cap == BLUETOOTH_CAPABILITY) bluetoothPermissions() else null

    // From the NIF once its natives are registered.
    @JvmStatic
    fun attach() {
        attached = true
        // Generations renewed before the natives were there.
        synchronized(sourceLock) {
            for (i in 0 until SOURCES) if (generations[i] > 0) nativeActivate(i, generations[i])
        }
        event("port", JSONObject().put("inputs", portSenders).put("outputs", portListeners))
    }

    private fun event(tag: String, json: JSONObject) {
        if (attached) nativeEvent(tag, json.toString().toByteArray(Charsets.UTF_8))
    }

    // ── Sending (the NIF's sending thread) ──────────────────────────────────

    // Every destination gets the bytes with the time they are heard at
    // (System.nanoTime base). A destination that went away mid-send is
    // skipped; its removal follows through the device callback.
    @Volatile private var destinations: Array<MidiInputPort> = emptyArray()

    @JvmStatic
    fun send(data: ByteArray, count: Int, timestamp: Long) {
        if (portListeners > 0) {
            val receiver = service?.outputPortReceivers?.firstOrNull()
            if (receiver != null) {
                try {
                    receiver.send(data, 0, count, timestamp)
                } catch (e: IOException) {
                    // A client left mid-send.
                }
            }
        }
        for (port in destinations) {
            try {
                port.send(data, 0, count, timestamp)
            } catch (e: IOException) {
                // Unplugged mid-send.
            } catch (e: IllegalStateException) {
                // Closed under us.
            }
        }
    }

    // ── Devices ─────────────────────────────────────────────────────────────

    private class Opened(
        val device: MidiDevice,
        val sources: List<Int>,
        val input: MidiInputPort?,
        val outputs: List<MidiOutputPort>,
    )

    private val opened = ConcurrentHashMap<Int, Opened>()
    private val sourceLock = Any()
    private val sourcesUsed = BooleanArray(SOURCES).also { it[0] = true }
    private var lastSource = 0 // under sourceLock
    private var lastGeneration = 0L // under sourceLock
    private val generations = LongArray(SOURCES) // under sourceLock: each source's current one

    private fun midiManager(): MidiManager? =
        appContext?.getSystemService(Context.MIDI_SERVICE) as? MidiManager

    private var watching = false // main thread only

    @Suppress("DEPRECATION") // the executor + transport overload is API 33+
    private fun watchDevices() {
        if (watching) return
        val mm = midiManager() ?: return
        mm.registerDeviceCallback(object : MidiManager.DeviceCallback() {
            override fun onDeviceAdded(info: MidiDeviceInfo) {
                event("added", describe(info))
            }

            override fun onDeviceRemoved(info: MidiDeviceInfo) {
                forgetBluetooth(info.id)
                closeDevice(info.id, false)
                event("removed", describe(info))
            }
        }, main)
        watching = true
    }

    @JvmStatic
    @Suppress("DEPRECATION") // getDevicesForTransport is API 33+
    fun devices(): ByteArray {
        val arr = JSONArray()
        midiManager()?.devices?.forEach { arr.put(describe(it)) }
        return arr.toString().toByteArray(Charsets.UTF_8)
    }

    // "" when opening started ("opened" / "open_failed" follow), else why not.
    @JvmStatic
    @Suppress("DEPRECATION")
    fun open(id: Int): String {
        val mm = midiManager() ?: return "no_midi_service"
        val info = mm.devices.firstOrNull { it.id == id } ?: return "unknown_device"
        if (opened.containsKey(id)) {
            main.post { event("opened", JSONObject().put("id", id)) }
            return ""
        }
        main.post {
            mm.openDevice(info, { device ->
                if (device == null) {
                    event("open_failed", JSONObject().put("id", id).put("reason", "open_failed"))
                } else {
                    connect(id, device)
                }
            }, main)
        }
        return ""
    }

    // Main thread, like closeDevice and the device callback.
    @Suppress("DEPRECATION")
    private fun connect(id: Int, device: MidiDevice) {
        // Opened twice before the first open finished, or removed meanwhile.
        val existing = opened[id]
        if (existing != null || midiManager()?.devices?.none { it.id == id } != false) {
            closeQuietly(device)
            if (existing != null) {
                event(
                    "opened",
                    JSONObject().put("id", id).put("receiving", existing.outputs.size)
                        .put("sending", existing.input != null),
                )
            } else {
                event("open_failed", JSONObject().put("id", id).put("reason", "unknown_device"))
            }
            return
        }
        // An input port has one opener at a time: null while another app has it.
        val input = if (device.info.inputPortCount > 0) device.openInputPort(0) else null
        val outputs = ArrayList<MidiOutputPort>()
        val sources = ArrayList<Int>()
        var outOfSources = false
        for (i in 0 until device.info.outputPortCount) {
            val port = device.openOutputPort(i) ?: continue
            val receiver = takeSource()
            if (receiver == null) {
                closeQuietly(port)
                outOfSources = true
                break
            }
            port.connect(receiver)
            outputs.add(port)
            sources.add(receiver.source)
        }
        if (input == null && outputs.isEmpty()) {
            closeQuietly(device)
            val reason = if (outOfSources) "unavailable" else "open_failed"
            event("open_failed", JSONObject().put("id", id).put("reason", reason))
            return
        }
        opened[id] = Opened(device, sources, input, outputs)
        rebuildDestinations()
        event(
            "opened",
            JSONObject().put("id", id).put("receiving", outputs.size).put("sending", input != null),
        )
    }

    @JvmStatic
    fun close(id: Int) {
        main.post { closeDevice(id, true) }
    }

    private fun closeDevice(id: Int, tell: Boolean) {
        val o = opened.remove(id) ?: return
        rebuildDestinations()
        o.outputs.forEach { closeQuietly(it) }
        o.input?.let { closeQuietly(it) }
        closeQuietly(o.device)
        o.sources.forEach { giveSource(it) }
        if (tell) event("closed", JSONObject().put("id", id))
    }

    private fun rebuildDestinations() {
        destinations = opened.values.mapNotNull { it.input }.toTypedArray()
    }

    // A receiver for the next free source. Round robin from the last one
    // taken, so a source just given back is taken again only when no other is
    // free.
    private fun takeSource(): Receiver? {
        synchronized(sourceLock) {
            val i = (1 until SOURCES).map { (lastSource + it - 1) % (SOURCES - 1) + 1 }.firstOrNull { !sourcesUsed[it] }
                ?: return null
            sourcesUsed[i] = true
            lastSource = i
            return Receiver(i, renew(i))
        }
    }

    // Given back: a closed port's late message is dropped from now on.
    private fun giveSource(i: Int) {
        synchronized(sourceLock) {
            if (i > 0) {
                sourcesUsed[i] = false
                renew(i)
            }
        }
    }

    // The Magpie port's receiver for a newly created service (a fresh parser,
    // nothing left from an earlier service's stream).
    internal fun portReceiver(): Receiver =
        synchronized(sourceLock) { Receiver(0, renew(0)).also { portRx = it } }

    @Volatile private var portRx: Receiver? = null

    // Under sourceLock: source `i`'s next generation, made current in C (or
    // by attach, if the natives aren't there yet). The port's receiver sends
    // with it from now on unless `receiver` is false (before C hears: its
    // next sender's first message isn't dropped).
    private fun renew(i: Int, receiver: Boolean = true): Long {
        val g = ++lastGeneration
        generations[i] = g
        if (i == 0 && receiver) portRx?.generation = g
        if (attached) nativeActivate(i, g)
        return g
    }

    // The address is the Bluetooth device's ("" for USB and virtual devices).
    @Suppress("DEPRECATION") // typed getParcelable is API 33+
    private fun describe(info: MidiDeviceInfo): JSONObject {
        val props = info.properties
        val owner = props.getParcelable<ServiceInfo>(PROPERTY_SERVICE_INFO)?.packageName
        val address = props.getParcelable<BluetoothDevice>(MidiDeviceInfo.PROPERTY_BLUETOOTH_DEVICE)?.address
        val type = when (info.type) {
            MidiDeviceInfo.TYPE_USB -> "usb"
            MidiDeviceInfo.TYPE_BLUETOOTH -> "bluetooth"
            else -> "virtual"
        }
        return JSONObject()
            .put("id", info.id)
            .put("name", deviceName(info))
            .put("type", type)
            .put("inputs", info.inputPortCount)
            .put("outputs", info.outputPortCount)
            .put("own", owner != null && owner == appContext?.packageName)
            .put("address", address ?: "")
    }

    // USB and Bluetooth devices carry PROPERTY_NAME; some only declare
    // manufacturer + product.
    private fun deviceName(info: MidiDeviceInfo): String {
        val props = info.properties
        props.getString(MidiDeviceInfo.PROPERTY_NAME)?.takeIf { it.isNotBlank() }?.let { return it }
        val parts = listOfNotNull(
            props.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER),
            props.getString(MidiDeviceInfo.PROPERTY_PRODUCT),
        ).filter { it.isNotBlank() }
        return if (parts.isEmpty()) "MIDI device" else parts.joinToString(" ")
    }

    // ── Bluetooth-MIDI ──────────────────────────────────────────────────────

    // API <= 30: BLE scans need fine location (BLUETOOTH / BLUETOOTH_ADMIN are
    // install-time). API 31+: the Nearby-devices permissions, plus location
    // because the manifest's BLUETOOTH_SCAN doesn't claim neverForLocation.
    private fun bluetoothPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT <= 30) {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }

    private var scanCallback: ScanCallback? = null // main thread
    private var scanner: BluetoothLeScanner? = null // main thread
    private val bleDevices = ConcurrentHashMap<String, MidiDevice>()

    private fun bluetoothAdapter(ctx: Context): BluetoothAdapter? =
        (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun hasBluetoothPermissions(ctx: Context): Boolean =
        bluetoothPermissions().all { ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun locationOn(ctx: Context): Boolean =
        (ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.isLocationEnabled == true

    // "" when the scan started, else why not. Results arrive as ble_found,
    // then one ble_scan_done when it ends.
    @JvmStatic
    fun bleScan(ms: Int): String {
        val ctx = appContext ?: return "no_activity"
        val adapter = bluetoothAdapter(ctx) ?: return "no_bluetooth"
        if (!hasBluetoothPermissions(ctx)) return "no_permission"
        if (!adapter.isEnabled) return "bluetooth_off"
        if (!locationOn(ctx)) return "location_off"
        val leScanner = adapter.bluetoothLeScanner ?: return "bluetooth_off"
        main.post { startScan(leScanner, ms) }
        return ""
    }

    private val scanTimeout = Runnable { finishScan(JSONObject()) }

    private fun startScan(leScanner: BluetoothLeScanner, ms: Int) {
        main.removeCallbacks(scanTimeout)
        stopScanQuietly()
        val seen = HashSet<String>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val address = result.device.address
                if (!seen.add(address)) return
                event(
                    "ble_found",
                    JSONObject()
                        .put("address", address)
                        .put("name", result.scanRecord?.deviceName ?: "")
                        .put("rssi", result.rssi),
                )
            }

            override fun onScanFailed(errorCode: Int) {
                scanCallback = null
                main.removeCallbacks(scanTimeout)
                event("ble_scan_done", JSONObject().put("error", "scan_failed"))
            }
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString(BLE_MIDI_SERVICE)).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            leScanner.startScan(filters, settings, callback)
        } catch (e: SecurityException) {
            event("ble_scan_done", JSONObject().put("error", "no_permission"))
            return
        }
        scanCallback = callback
        scanner = leScanner
        main.postDelayed(scanTimeout, ms.toLong())
    }

    private fun finishScan(result: JSONObject) {
        main.removeCallbacks(scanTimeout)
        if (scanCallback == null) return
        stopScanQuietly()
        event("ble_scan_done", result)
    }

    private fun stopScanQuietly() {
        val callback = scanCallback ?: return
        scanCallback = null
        try {
            scanner?.stopScan(callback)
        } catch (e: SecurityException) {
            // Permission revoked mid-scan.
        } catch (e: IllegalStateException) {
            // Bluetooth switched off mid-scan.
        }
    }

    // "" when the connection was started, else why not: ble_connected (with
    // the MIDI device id; "added" follows for a new one) or ble_failed.
    @JvmStatic
    fun bleConnect(address: String): String {
        val ctx = appContext ?: return "no_activity"
        val mm = midiManager() ?: return "no_midi_service"
        val adapter = bluetoothAdapter(ctx) ?: return "no_bluetooth"
        if (!BluetoothAdapter.checkBluetoothAddress(address)) return "bad_address"
        if (!hasBluetoothPermissions(ctx)) return "no_permission"
        if (!adapter.isEnabled) return "bluetooth_off"
        bleDevices[address]?.let { open ->
            main.post { event("ble_connected", connected(address, open)) }
            return ""
        }
        val device = adapter.getRemoteDevice(address)
        main.post {
            try {
                mm.openBluetoothDevice(device, { midi ->
                    if (midi == null) {
                        event("ble_failed", JSONObject().put("address", address).put("reason", "open_failed"))
                    } else {
                        bleDevices.put(address, midi)?.let { closeQuietly(it) }
                        event("ble_connected", connected(address, midi))
                    }
                }, main)
            } catch (e: SecurityException) {
                event("ble_failed", JSONObject().put("address", address).put("reason", "no_permission"))
            }
        }
        return ""
    }

    private fun connected(address: String, midi: MidiDevice): JSONObject =
        JSONObject().put("address", address).put("id", midi.info.id).put("name", deviceName(midi.info))

    @JvmStatic
    fun bleDisconnect(address: String) {
        bleDevices.remove(address)?.let { closeQuietly(it) }
    }

    private fun forgetBluetooth(deviceId: Int) {
        val address = bleDevices.entries.firstOrNull { it.value.info.id == deviceId }?.key ?: return
        bleDevices.remove(address)?.let { closeQuietly(it) }
    }

    private fun closeQuietly(c: Closeable) {
        try {
            c.close()
        } catch (e: IOException) {
            Log.w(TAG, "close: $e")
        }
    }
}

// The Magpie port. Declared in the manifest with res/xml/magpie_midi_port.xml:
// one input port and one output port, "Magpie". Android creates it when an
// app opens a port.
class MagpieMidiService : MidiDeviceService() {
    private val receivers: Array<MidiReceiver> = arrayOf(MagpieMidi.portReceiver())

    override fun onCreate() {
        super.onCreate()
        MagpieMidi.serviceCreated(this)
    }

    override fun onDestroy() {
        MagpieMidi.serviceDestroyed(this)
        super.onDestroy()
    }

    override fun onGetInputPortReceivers(): Array<MidiReceiver> = receivers

    override fun onDeviceStatusChanged(status: MidiDeviceStatus) {
        MagpieMidi.portStatus(if (status.isInputPortOpen(0)) 1 else 0, status.getOutputPortOpenCount(0))
    }
}
