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
| Inter (Copyright (c) 2016 The Inter Project Authors) | `android/app/src/main/res/font/inter_*.ttf`, `priv/fonts/Inter-*.ttf` | SIL Open Font License 1.1 | [LICENSES/Inter-OFL-1.1.txt](LICENSES/Inter-OFL-1.1.txt) |
| JetBrains Mono (Copyright 2020 The JetBrains Mono Project Authors) | `android/app/src/main/res/font/jetbrainsmono_*.ttf`, `priv/fonts/JetBrainsMono-*.ttf` | SIL Open Font License 1.1 | [LICENSES/JetBrainsMono-OFL-1.1.txt](LICENSES/JetBrainsMono-OFL-1.1.txt) |
| Bricolage Grotesque (Copyright 2022 The Bricolage Grotesque Project Authors) | `android/app/src/main/res/font/bricolagegrotesque_extrabold.ttf`, `priv/fonts/BricolageGrotesque-ExtraBold.ttf` | SIL Open Font License 1.1 | [LICENSES/BricolageGrotesque-OFL-1.1.txt](LICENSES/BricolageGrotesque-OFL-1.1.txt) |
| Erlang/OTP 29 runtime (including its Ryu code), Elixir, and the Hex packages ecto, ecto_sql, db_connection, decimal, jason, telemetry, nimble_parsec | the APK's `otp.zip` and native libraries | Apache License 2.0 | [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt) |
| PCRE2 (Copyright (c) 1997-2007 University of Cambridge and others), linked into the Erlang runtime | native libraries | BSD-3-Clause | [LICENSES/PCRE2-BSD-3-Clause.txt](LICENSES/PCRE2-BSD-3-Clause.txt) |
| Zstandard (Copyright (c) Meta Platforms, Inc. and affiliates), linked into the Erlang runtime | native libraries | BSD-3-Clause | [LICENSES/zstd-BSD-3-Clause.txt](LICENSES/zstd-BSD-3-Clause.txt) |
| AsmJit (Copyright (c) 2008-2025 Petr Kobalicek), the Erlang runtime's JIT | native libraries | zlib | [LICENSES/asmjit-Zlib.txt](LICENSES/asmjit-Zlib.txt) |
| Mob (Copyright (c) 2026 Kevin Smith), including its Android bridge in the dex code | the APK's `otp.zip`, dex code and native libraries | MIT | [LICENSES/Mob-MIT.txt](LICENSES/Mob-MIT.txt) |
| mob_midi, mob_bluetooth | the APK's `otp.zip`, dex code and native libraries | MIT (declared on Hex; the packages ship no licence file) | |
| mob_audio_io (Copyright (c) 2026 GenericJam) | the APK's `otp.zip` and native libraries | MIT | [LICENSES/mob_audio_io-MIT.txt](LICENSES/mob_audio_io-MIT.txt) |
| exqlite and ecto_sqlite3 (both Copyright (c) 2021 Matthew A. Johnston) | the APK's `otp.zip` and native libraries | MIT | [LICENSES/exqlite-MIT.txt](LICENSES/exqlite-MIT.txt) |
| jQuery and jQuery Migrate (Copyright OpenJS Foundation and other contributors), tablesorter 2.32 (Copyright (c) 2007 Christian Bach), in Erlang/OTP's `common_test` | the APK's `otp.zip` | MIT | [LICENSES/jQuery-MIT.txt](LICENSES/jQuery-MIT.txt), [LICENSES/tablesorter-MIT.txt](LICENSES/tablesorter-MIT.txt) |
| SQLite (bundled by exqlite) | native libraries | public domain | |
| OpenSSL (Erlang's `crypto`) | native libraries | Apache License 2.0 | [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt) |
| AndroidX (Compose, Activity, AppCompat, CameraX, Media3), Kotlin standard library, kotlinx.coroutines, Coil, OkHttp, Okio | the APK's dex code | Apache License 2.0 | [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt) |
| The Public Suffix List (`okhttp3/internal/publicsuffix/publicsuffixes.gz`, compiled by OkHttp from https://publicsuffix.org/list/public_suffix_list.dat) | the APK | Mozilla Public License 2.0 | [LICENSES/MPL-2.0.txt](LICENSES/MPL-2.0.txt); source form at https://publicsuffix.org/list/ |

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
