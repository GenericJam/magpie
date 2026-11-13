package com.genericjam.magpie.capture

// Magpie's "Other apps" recording source: what this phone is playing, through
// Android's AudioPlaybackCapture (API 29+). Only apps that allow capture are
// heard (apps targeting API 29+ do by default; voice calls and DRM never);
// Magpie's own output (pads, count-in clicks) is left out.
//
// start(rate) asks for the MediaProjection consent; once granted,
// MagpieCaptureService runs as a mediaProjection foreground service (the
// only place getMediaProjection is legal), opens an AudioRecord on the
// playback capture (16-bit stereo at the engine's rate) and a read thread
// hands each block, with the CLOCK_MONOTONIC time its first frame was
// captured, to nativeWrite. The natives are registered by the magpie_audio
// NIF (c_src/magpie_audio.c), which finds this class through the activity's
// class loader and calls start/stop from a BEAM dirty scheduler; the
// outcome goes back through nativeStarted / nativeEnded ("denied",
// "stopped" when the user ends the projection, "error").
//
// Locking: `lock` guards the session and the consent dialog's launch;
// natives are never called while it is held (the NIF calls stop() with its
// own lock held, and the natives take that lock).

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import java.lang.ref.WeakReference
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

object MagpieCapture : io.mob.plugin.MobActivityAware {
    private const val TAG = "MagpieCapture"
    private const val CHANNELS = 2
    private const val READ_FRAMES = 960 // 20 ms at 48 kHz
    internal const val EXTRA_SESSION = "com.genericjam.magpie.capture.SESSION"

    @JvmStatic external fun nativeStarted(session: Long, rate: Int, channels: Int): Boolean

    @JvmStatic external fun nativeWrite(session: Long, buffer: ByteBuffer, frames: Int, t0Ns: Long)

    @JvmStatic external fun nativeEnded(session: Long, reason: String)

    private val main = Handler(Looper.getMainLooper())
    private val keyPrefix = "magpie_capture_${UUID.randomUUID()}_"

    @Volatile private var activityRef: WeakReference<Activity>? = null

    // One start() at a time: its session number, the engine's rate and, once
    // the user has agreed, the projection's result.
    private class Request(val session: Long, val rate: Int) {
        var resultCode = 0
        var data: Intent? = null
    }

    private val lock = Any()
    private var session = -1L // the NIF's number for the current start; -1 after a stop: older consents and service starts are stale
    private var pending: Request? = null
    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var reader: Thread? = null
    private var service: WeakReference<Service>? = null

    @Volatile private var reading = false

    // MobPluginBootstrap calls register() and hands over the Activity.
    @JvmStatic fun register() {}

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    // From the NIF: "" once the consent dialog is on its way, else why not.
    // `sessionId` comes back with every native call, so the NIF ignores
    // calls from an earlier session.
    @JvmStatic
    fun start(rate: Int, sessionId: Long): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "unsupported"
        val activity = activityRef?.get() ?: return "no_activity"
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return "no_permission"
        }
        val owner = activity as? ActivityResultRegistryOwner ?: return "unsupported"
        val req = synchronized(lock) {
            if (pending != null) return "busy"
            stopLocked()
            Request(sessionId, rate).also {
                session = sessionId
                pending = it
            }
        }
        main.post { askConsent(activity, owner, req) }
        return ""
    }

    // From the NIF: capture off; the read thread has ended when this returns.
    @JvmStatic
    fun stop() {
        synchronized(lock) {
            session = -1L
            stopLocked()
        }
    }

    // Checked and launched under `lock`, so a stop() either comes first (no
    // dialog) or after the launch (the dialog is up; onConsent drops its
    // answer). launch() only asks the system to start the dialog; its
    // result arrives later on the main thread.
    private fun askConsent(activity: Activity, owner: ActivityResultRegistryOwner, req: Request) {
        val launched = synchronized(lock) {
            if (pending !== req) return // stopped before the dialog could open
            try {
                val mpm = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                var launcher: ActivityResultLauncher<Intent>? = null
                launcher = owner.activityResultRegistry.register(
                    keyPrefix + req.session,
                    ActivityResultContracts.StartActivityForResult(),
                ) { result ->
                    launcher?.unregister()
                    onConsent(activity, req, result.resultCode, result.data)
                }
                launcher.launch(mpm.createScreenCaptureIntent())
                true
            } catch (e: Throwable) {
                Log.e(TAG, "consent: ${e.message}", e)
                false
            }
        }
        if (!launched) fail(req, "error")
    }

    private fun onConsent(activity: Activity, req: Request, resultCode: Int, data: Intent?) {
        val granted = resultCode == Activity.RESULT_OK && data != null
        synchronized(lock) {
            if (pending !== req) return // stopped meanwhile: the projection is never taken
            if (granted) {
                req.resultCode = resultCode
                req.data = data
            } else {
                pending = null
            }
        }
        if (!granted) {
            nativeEnded(req.session, "denied")
            return
        }
        try {
            activity.startForegroundService(
                Intent(activity, MagpieCaptureService::class.java).putExtra(EXTRA_SESSION, req.session),
            )
        } catch (e: Throwable) {
            Log.e(TAG, "capture service: ${e.message}", e)
            fail(req, "error")
        }
    }

    private fun fail(req: Request, reason: String) {
        val current = synchronized(lock) {
            (pending === req).also { if (it) pending = null }
        }
        if (current) nativeEnded(req.session, reason)
    }

    // MagpieCaptureService, foregrounded as mediaProjection (main thread).
    @RequiresApi(Build.VERSION_CODES.Q)
    internal fun begin(svc: Service, sessionId: Long, startId: Int) {
        var failure: String? = null
        val req = synchronized(lock) {
            val r = pending
            if (r == null || r.session != sessionId || r.data == null) {
                svc.stopSelf(startId)
                return
            }
            pending = null
            service = WeakReference(svc)
            failure = try {
                open(svc, r)
            } catch (e: Throwable) {
                Log.e(TAG, "capture: ${e.message}", e)
                "error"
            }
            if (failure != null) stopLocked()
            r
        }
        failure?.let {
            nativeEnded(req.session, it)
            return
        }
        val rate = synchronized(lock) { record?.sampleRate } ?: return
        if (!nativeStarted(req.session, rate, CHANNELS)) {
            synchronized(lock) { if (session == req.session) stopLocked() }
            return
        }
        synchronized(lock) { if (session == req.session && record != null) startReader(req.session) }
    }

    // The projection, the playback capture and its AudioRecord. Caller holds lock.
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun open(svc: Service, req: Request): String? {
        if (ContextCompat.checkSelfPermission(svc, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return "error"
        }
        val mpm = svc.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val proj = mpm.getMediaProjection(req.resultCode, req.data!!) ?: return "error"
        projection = proj
        proj.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() = projectionStopped(proj)
            },
            main,
        )
        val config = AudioPlaybackCaptureConfiguration.Builder(proj)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .excludeUid(svc.applicationInfo.uid)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(req.rate)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val min = AudioRecord.getMinBufferSize(req.rate, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(min * 2, READ_FRAMES * CHANNELS * 2 * 4))
            .setAudioPlaybackCaptureConfig(config)
            .build()
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return "error"
        }
        rec.startRecording()
        record = rec
        Log.i(TAG, "capture open: ${rec.sampleRate} Hz, $CHANNELS channels")
        return null
    }

    // The read thread: blocks of 16-bit PCM to the NIF, stamped with the
    // capture time of their first frame. Caller holds lock.
    private fun startReader(sessionId: Long) {
        val rec = record ?: return
        val rate = rec.sampleRate
        reading = true
        reader = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val buf = ByteBuffer.allocateDirect(READ_FRAMES * CHANNELS * 2).order(ByteOrder.nativeOrder())
            val ts = AudioTimestamp()
            var total = 0L
            var failed = false
            while (reading && session == sessionId) {
                buf.clear()
                val n = rec.read(buf, buf.capacity(), AudioRecord.READ_BLOCKING)
                if (n < 0) {
                    failed = reading
                    break
                }
                if (n == 0) continue
                val frames = n / (CHANNELS * 2)
                val t0 = if (rec.getTimestamp(ts, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
                    ts.nanoTime + (total - ts.framePosition) * 1_000_000_000L / rate
                } else {
                    System.nanoTime() - frames * 1_000_000_000L / rate
                }
                nativeWrite(sessionId, buf, frames, t0)
                total += frames
            }
            if (failed) {
                Log.e(TAG, "capture read failed")
                main.post { readFailed(sessionId) }
            }
        }, "magpie-capture").also { it.start() }
    }

    private fun readFailed(sessionId: Long) {
        val current = synchronized(lock) {
            (session == sessionId).also {
                if (it) {
                    session = -1L
                    stopLocked()
                }
            }
        }
        if (current) nativeEnded(sessionId, "error")
    }

    // The user ended the projection (the system's cast/record chip, or
    // another app took it).
    private fun projectionStopped(proj: MediaProjection) {
        var ended = -1L
        synchronized(lock) {
            if (projection === proj) {
                ended = session
                session = -1L
                stopLocked()
            }
        }
        if (ended >= 0) nativeEnded(ended, "stopped")
    }

    // Everything off. Caller holds lock.
    private fun stopLocked() {
        pending = null
        reading = false
        try {
            record?.stop() // wakes the read thread
        } catch (_: Throwable) {
        }
        try {
            reader?.join(1000)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        reader = null
        try {
            record?.release()
        } catch (_: Throwable) {
        }
        record = null
        val proj = projection
        projection = null
        try {
            proj?.stop()
        } catch (_: Throwable) {
        }
        try {
            service?.get()?.stopSelf()
        } catch (_: Throwable) {
        }
        service = null
    }

    internal fun notification(svc: Service): Notification {
        val channel = "magpie_capture"
        val nm = svc.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(channel, "Recording other apps", NotificationManager.IMPORTANCE_LOW))
        return Notification.Builder(svc, channel)
            .setContentTitle("Magpie is listening to other apps")
            .setSmallIcon(svc.applicationInfo.icon)
            .setOngoing(true)
            .build()
    }
}

// The mediaProjection foreground service the capture runs in (declared by the
// plugin's manifest snippet). It only foregrounds itself and hands over.
class MagpieCaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = MagpieCapture.notification(this)
        val sessionId = intent?.getLongExtra(MagpieCapture.EXTRA_SESSION, -1L) ?: -1L
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            MagpieCapture.begin(this, sessionId, startId)
        } else {
            startForeground(1, notification)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }
}
