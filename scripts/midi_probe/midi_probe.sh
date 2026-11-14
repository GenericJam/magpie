#!/usr/bin/env bash
# Build MidiProbe.java, push it to the phone and run it there as the adb
# shell user (app_process): another process that opens Magpie's MIDI device,
# sends it notes or a clock and prints what Magpie sends back, all stamped
# with CLOCK_MONOTONIC. See MidiProbe.java for the modes and the output.
#
#   scripts/midi_probe/midi_probe.sh <serial> <device name> devices
#   scripts/midi_probe/midi_probe.sh <serial> Magpie listen 10
#   scripts/midi_probe/midi_probe.sh <serial> Magpie stall 20
#   scripts/midi_probe/midi_probe.sh <serial> Magpie notes 10 20 200 1 36,38
#   scripts/midi_probe/midi_probe.sh <serial> Magpie clock 8 120 8
#
# PROBE_PUSH_ONLY=1 builds and pushes /data/local/tmp/magpie_midi_probe.dex
# without running it (scripts/midi_check.exs does that, then runs it
# itself). Needs JDK 17+ and the Android SDK (platforms/android-35,
# build-tools with d8).
set -euo pipefail

serial=${1:?usage: midi_probe.sh <serial> <device name> <mode> [args...]}
shift

sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
android_jar=$sdk/platforms/android-35/android.jar
d8=$(ls -d "$sdk"/build-tools/*/d8 | sort -V | tail -n 1)
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

javac --release 17 -classpath "$android_jar" -d "$work" "$here/MidiProbe.java"
"$d8" --min-api 28 --lib "$android_jar" --output "$work" "$work"/*.class
adb -s "$serial" push "$work/classes.dex" /data/local/tmp/magpie_midi_probe.dex >/dev/null
[ "${PROBE_PUSH_ONLY:-0}" = 1 ] && exit 0

name=${1:?device name}
shift
adb -s "$serial" shell CLASSPATH=/data/local/tmp/magpie_midi_probe.dex \
  app_process /system/bin MidiProbe "'$name'" "$@"
