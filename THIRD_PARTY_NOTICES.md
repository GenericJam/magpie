# Licensing scope and third-party notices

## Magpie-owned code: MIT

The root [LICENSE](LICENSE) grants the MIT License for original Magpie code,
copyright (c) 2026 GenericJam: the Elixir app (`lib/`), the audio engine
(`c_src/`), the `magpie_capture` plugin, scripts, design files and docs, except
for the third-party material below or anything carrying its own notice. It
does not replace any upstream copyright, attribution or licence.

## Shipped in the APK under other licences

| Material | Where | Licence | Notice |
|---|---|---|---|
| Starter drums: 100 one-shots from the Versilian Community Sample Library (VCSL) by Versilian Studios LLC and contributors | `priv/samples/starter-drums/` | CC0 1.0 Universal | [NOTICE.md](priv/samples/starter-drums/NOTICE.md), [LICENSE.txt](priv/samples/starter-drums/LICENSE.txt) |
| Inter (Copyright (c) 2016 The Inter Project Authors) | `android/app/src/main/res/font/inter_*.ttf` | SIL Open Font License 1.1 | [LICENSES/Inter-OFL-1.1.txt](LICENSES/Inter-OFL-1.1.txt) |
| JetBrains Mono (Copyright 2020 The JetBrains Mono Project Authors) | `android/app/src/main/res/font/jetbrainsmono_*.ttf` | SIL Open Font License 1.1 | [LICENSES/JetBrainsMono-OFL-1.1.txt](LICENSES/JetBrainsMono-OFL-1.1.txt) |
| Bricolage Grotesque (Copyright 2022 The Bricolage Grotesque Project Authors) | `android/app/src/main/res/font/bricolagegrotesque_extrabold.ttf` | SIL Open Font License 1.1 | [LICENSES/BricolageGrotesque-OFL-1.1.txt](LICENSES/BricolageGrotesque-OFL-1.1.txt) |
| Erlang/OTP runtime, Elixir, and the Hex packages ecto, ecto_sql, db_connection, decimal, jason, telemetry | the APK's `otp.zip` | Apache License 2.0 | [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt) |
| Mob, mob_midi, mob_bluetooth, ecto_sqlite3, exqlite | the APK's `otp.zip` and native libraries | MIT (each its own copyright) | each package's own licence |
| SQLite (bundled by exqlite) | native libraries | public domain | |
| OpenSSL (Erlang's `crypto`) | native libraries | Apache License 2.0 | [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt) |
| AndroidX, Jetpack Compose, Kotlin standard library | the APK's dex code | Apache License 2.0 | [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt) |

The CC0 drums keep their CC0 status independently of Magpie's MIT licence.
The fonts stay under the OFL: they may be bundled and redistributed with the
app, but not sold by themselves, and a modified font must not use the
reserved name.

Generated or copied framework code (Mob's Android bridge in
`android/app/src/main/java/com/genericjam/magpie/Mob*.kt`, `io/mob/`, `jni/`)
retains Mob's licence and copyright; it is not newly owned by Magpie merely
because it is present in this repository or the APK. `android/gradlew` and the
Gradle wrapper keep their Apache-2.0 headers (copyright 2015 the original
authors).

## In the APK

The Android build copies `LICENSE`, this file and `LICENSES/` into the APK's
assets under `licenses/` (`copyLicenseAssets` in `android/app/build.gradle`);
the starter drums' `NOTICE.md` and `LICENSE.txt` ship beside the samples.
