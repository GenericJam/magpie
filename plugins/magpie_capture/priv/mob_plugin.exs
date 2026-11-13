# Magpie's "Other apps" recording source: Android AudioPlaybackCapture
# (API 29+) behind the MediaProjection consent, in a mediaProjection
# foreground service. Android only. No NIF: c_src/magpie_audio.c finds
# com.genericjam.magpie.capture.MagpieCapture through the activity's class
# loader, registers its natives (nativeStarted, nativeWrite, nativeEnded)
# and calls start/stop. See decisions/2026-11-13-recording-other-apps.md.
%{
  name: :magpie_capture,
  description: "Magpie's other-apps recording source (AudioPlaybackCapture into the magpie_audio NIF)",
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  android: %{
    # RECORD_AUDIO is the app's own (AndroidManifest.xml): AudioRecord needs it
    # under a playback-capture config too. A MediaProjection must run in a
    # foreground service typed mediaProjection (API 34 split out its own
    # permission).
    permissions: [
      "android.permission.FOREGROUND_SERVICE",
      "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"
    ],
    bridge_kt: "priv/native/android/MagpieCapture.kt",
    bridge_class: "com.genericjam.magpie.capture.MagpieCapture",
    manifest_application_snippets: [
      """
      <service
          android:name="com.genericjam.magpie.capture.MagpieCaptureService"
          android:exported="false"
          android:foregroundServiceType="mediaProjection" />
      """
    ]
  }
}
