# Magpie ↔ sibling apps (v1)

Magpie uses the family's shared pairing and Erlang distribution setup, defined in FMutate's
`protocol.md` (§1 pairing, §2 transport, §3 trust). Build that once as a shared module and
use it in every app. This file lists what is specific to Magpie.

## 1. Pairing (shared module, both directions)

Every family app can **host** a pairing (show a QR code + typed code: "My code" tab) and **join**
one (scan / type: "Scan" tab). Board: `boards/Connect.dc.html`.

- QR / link: `<app>://pair?v=1&app=magpie&node=magpie&host=…&port=…&fp=…&t=…` (same fields as
  FMutate's; `app` names the host).
- Single-use token, 5 minutes, 5 tries; the host shows "<App> wants to connect · Allow"; on Allow
  each side stores a per-peer cookie (`:erlang.set_cookie/2`) and the peer's cert fingerprint.
- Same phone: loopback + the `PAIR` signature permission. Other phone: TLS distribution, cert
  pinned, Wi-Fi only.
- Node name: `magpie@<host>`. Fixed distribution port; no epmd.
- The Connect screen lists each paired app with **what it can do** (chips) and Disconnect.

## 2. Magpie exposes (calls and casts to `{:global, :magpie}`)

All messages: `{:magpie, 1, payload}`.

### 2.1 Play

```elixir
{:pad, bank, slot, :down, velocity}   # cast; bank "A".."D", slot 0..15
{:pad, bank, slot, :up}
{:note, note, :down, velocity}        # cast; same as MIDI note-on, maps through midi_note / keys mode
{:note, note, :up}
{:transport, :play | :stop | {:tempo, bpm}}
```

Same merge rules as touch. Pads pressed remotely light **violet** for the length of the hit, and
the magpie button shows "driven by <app>" for 2 s after the last remote input.

### 2.2 Library (only while "Share the stash" is on)

```elixir
{:list_samples, filter}        # → {:ok, [%{id, name, seconds, rate, channels, source, tags}]}
                               #   filter: %{source: :all | :recorded | :fmutate | :pack | :imported, q: "text"}
{:get_sample, id, format}      # → {:ok, binary} | {:error, :not_found}
                               #   format: :wav16 | %{rate: 22050, bits: 8, mono: true} (resampled for small firmwares)
{:put_sample, binary, meta}    # → {:ok, id}   e.g. FMutate pushing a firmware's sample pack
```

Sample ids are content hashes (SHA-256 of the PCM), so the same sound is stored once.

### 2.3 Subscriptions

```elixir
{:subscribe, pid, topics}      # topics ⊆ [:pads, :transport, :library]
```

Events: `{:pad_hit, bank, slot, velocity}`, `{:transport, state, bpm, step}`, `{:library_changed}`.

## 3. Magpie needs from FMutate (add to FMutate's protocol)

```elixir
{:record_audio, opts}          # call to FMutate
                               #   opts: [max_seconds: 60, start: :now | :on_sound, rate: 48000]
                               # → {:ok, ref}; FMutate then sends
{:recorded, ref, wav_binary}   #   when stopped or max reached
{:stop_recording, ref}         # → :ok
```

FMutate records its own audio output into memory and sends the WAV over the link. This is a
whole-file transfer, not live audio streaming, which stays out of distribution.

Sampler firmwares in FMutate that want samples call Magpie's §2.2 calls; FMutate converts the
result to the firmware's own format.

## 4. MIDI (no pairing needed)

- Virtual MIDI port "Magpie" in and out; USB/BLE MIDI.
- Note-on → pad with that `midi_note` (velocity passes through); keys-mode pads play chromatically
  around their root.
- Pads send their `midi_note` out when hit.
- Clock: internal / follow / send (MIDI clock, start/stop, song position).

## 5. Messages from Humdinger

Humdinger sends ordinary MIDI notes (virtual port or the distribution `{:note, …}` cast). Nothing
Magpie-specific is needed. A keys-mode pad lets someone hum a melody on any sample.
