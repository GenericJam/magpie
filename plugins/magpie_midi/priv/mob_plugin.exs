# Magpie's Android MIDI: the virtual "Magpie" port (in and out), the MIDI
# device watcher, opening USB and Bluetooth devices, Bluetooth-MIDI scan and
# connect. Android only. No NIF: c_src/magpie_audio.c finds
# com.genericjam.magpie.midi.MagpieMidi through the activity's class loader,
# registers its natives (nativeIn, nativeEvent) and calls it. See
# decisions/2026-11-13-midi.md.
%{
  name: :magpie_midi,
  description: "Magpie's MIDI port, device watcher and Bluetooth-MIDI connect (into the magpie_audio NIF)",
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  android: %{
    permissions: [
      # Bluetooth-MIDI. API <= 30: BLUETOOTH / BLUETOOTH_ADMIN (install-time)
      # and fine location for BLE scans. API 31+: the Nearby-devices
      # permissions (plus location, as BLUETOOTH_SCAN isn't neverForLocation).
      # Requested at runtime as the :midi_bluetooth capability.
      "android.permission.BLUETOOTH",
      "android.permission.BLUETOOTH_ADMIN",
      "android.permission.BLUETOOTH_SCAN",
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.ACCESS_FINE_LOCATION",
      "android.permission.ACCESS_COARSE_LOCATION"
    ],
    bridge_kt: "priv/native/android/MagpieMidi.kt",
    bridge_class: "com.genericjam.magpie.midi.MagpieMidi",
    # The port's service. Android binds it (BIND_MIDI_DEVICE_SERVICE) when an
    # app opens the port; the meta-data points at its device info.
    manifest_application_snippets: [
      """
      <service
          android:name="com.genericjam.magpie.midi.MagpieMidiService"
          android:exported="true"
          android:permission="android.permission.BIND_MIDI_DEVICE_SERVICE">
          <intent-filter>
              <action android:name="android.media.midi.MidiDeviceService" />
          </intent-filter>
          <meta-data
              android:name="android.media.midi.MidiDeviceService"
              android:resource="@xml/magpie_midi_port" />
      </service>
      """
    ],
    res_files: ["priv/native/android/res/xml/magpie_midi_port.xml"]
  }
}
