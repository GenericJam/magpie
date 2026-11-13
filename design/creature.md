# The magpie (mascot)

A scruffy magpie that steals sounds. Every sample is a shiny trinket; its nest is the pad grid.
Sly where Humdinger's Mimi is a dreamer; googly eyes like the whole family.

Working reference: `boards/Bird.dc.html` (port its maths). Moods sheet: `boards/Main.dc.html`.

## Geometry (viewBox 64 × 56; scale `s` multiplies everything; size 1 = 64 × 56 pt)

| Part | Shape | Values |
|---|---|---|
| Tail | polygon, wing colour | (17, body+4) → (1, 53) → (5, 56) → (22, body+10) |
| Legs | 2 rounded rects | x 27 and 34, y 43, 2 × 8, `legs` |
| Body | ellipse | centre (30, 30), rx 17, ry 14.5, `body`, 1.2 stroke `outline` |
| Belly | ellipse | centre (33, body+7), rx 11, ry 8.5, `belly` |
| Wing | ellipse | centre (22, body+1), rx 10, ry 6 (7.5 when playing), `wing` |
| Shoulder patch | ellipse | centre (24, body−3), rx 5.5, ry 2.4, `belly` |
| Head | circle | centre (41, 18), r 10, `body`, 1.2 stroke `outline` |
| Eyes | 2 white circles | centres (37, head−2) and (45.5, head−2), r 4.5 (5.2 when listening) |
| Pupils | dark circles | r 2.2, offset up to 2 in the look direction |
| Beak | triangle | (49, head+0.5) → (60, head+2) → (49, head+4), `beak` |
| Beak open (grab) | two triangles | upper and lower jaws, gap ≈ 2.5 |
| Trinket (grab) | rounded rect | 8 × 8, radius 2, at x 56, in the beak; pad colour; 2.5 × 2 white glint |

Colours are in `magpie_style.ex` (`bird`). Sleep/no-mic: body `#4A4560`, belly `#8F89A3`,
wing `#5A5470`, eyes closed (3.5-unit horizontal strokes).

## Moods

| State | Pose |
|---|---|
| Idle | blinks every 3–6 s; pupils follow tilt |
| Recording | eyes bigger, pupils up-right, sound arcs beside the head |
| Got it (new sample) | beak open holding a pad-coloured trinket |
| Playing | body and head bob 2 units to the tempo; wing raised; tick marks either side |
| Kit saved | head up, pupils down at a pile of trinkets under it |
| Paused | greyed, eyes closed, "zZ" |
| No mic | greyed, eyes closed |
| Driven by another app | idle pose, the menu button gets a violet ring |

## Animation (move and scale only; no rotation, no gradients)

- **Grab:** on a finished recording, the magpie dips (body y +3, 80 ms), the trinket appears in
  the beak, then it lifts back (120 ms). On the pads screen, the new pad's tint fades from 0 to 26 %.
- **Bob:** each beat, body and head move up 2 units and spring back; wing ry 6 → 7.5 → 6.
- **Blink:** eye ry → 15 % → 100 % over 90 ms.
- **Pupils:** offset = tilt × 2 units, spring ~120 ms.

## Where it appears

- The 44 pt menu button on the pads, sequencer and bus-mode screens (mood = transport state).
- Recording screen (listening), library header (proud), pairing screen, empty states.
- Never over pads or the sequencer grid.
