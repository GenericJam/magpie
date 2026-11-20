# Magpie

A pocket sampler for Android: record or import sounds, put them on 64 pads
(4 banks of 16), play them with your fingers or MIDI, and sequence them in
patterns. It ships with 100 acoustic drum and percussion one-shots, so it
plays from the first launch. Built with [Mob](https://hexdocs.pm/mob)
(Elixir on the phone) and a native audio engine.

## Install

Download `Magpie.apk` from the
[latest release](https://github.com/GenericJam/magpie/releases/latest) and
open it on the phone (allow installs from your browser or file manager when
Android asks), or `adb install Magpie.apk`. Android 9 or newer; arm64,
32-bit ARM and x86-64.

## Building

See [AGENTS.md](AGENTS.md): the toolchain, the tests and the release path.

## Licence

Magpie is licensed under the [MIT License](LICENSE). The starter drums are
CC0 (VCSL by Versilian Studios LLC and contributors), and the bundled fonts
are under the SIL Open Font License; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
