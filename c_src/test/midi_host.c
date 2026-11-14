/*
 * Host harness for Magpie's MIDI in c_src/sampler.c, c_src/midi.c and
 * c_src/midi_out.c: the parser, notes in through the kit's table (channel
 * filter, keys mode, releases, all-notes-off, no echo), notes out (note-on
 * on the voice's first frame, note-off when it stops sounding at full),
 * clock send (every tick on its exact frame through tempo changes, Start /
 * song position / Stop, the free-running clock while stopped), an incoming
 * clock ignored (not followed yet), and the outputs against a fake mob_midi
 * port that stalls (refused and discarded note-offs still go out).
 *
 * Needs deps/mob_midi (mix deps.get) for mob_midi.h.
 *
 *   cc -O2 -Wall -Wextra -o /tmp/midi_host c_src/test/midi_host.c -lm && /tmp/midi_host
 *   cc -g -O1 -fsanitize=address,undefined -o /tmp/midi_host_asan c_src/test/midi_host.c -lm && /tmp/midi_host_asan
 *
 * Exit 1 on any failure; each check prints one line.
 */

#include <stdio.h>
#include <stdlib.h>

#include "../../deps/mob_midi/priv/include/mob_midi.h"

#include "../sampler.c"
#include "../midi_out.c"

#define RATE 48000

static int failures = 0;

#define CHECK(cond, ...)                                                                                               \
    do {                                                                                                               \
        bool ok_ = (cond);                                                                                             \
        printf("%s ", ok_ ? "  ok  " : "  FAIL");                                                                      \
        printf(__VA_ARGS__);                                                                                           \
        printf("\n");                                                                                                  \
        if (!ok_) failures++;                                                                                          \
    } while (0)

static unsigned rng = 1;
static unsigned next_rand(void) {
    rng = rng * 1103515245u + 12345u;
    return (rng >> 16) & 0x7fff;
}

/* ── Scaffolding ──────────────────────────────────────────────────────────── */

static sp_engine *new_engine(void) {
    sp_engine *e = malloc(sizeof(sp_engine));
    sp_init(e, RATE);
    return e;
}

static void free_engine(sp_engine *e) {
    sp_garbage g;
    while (sp_pop_garbage(e, &g)) sp_free_garbage(&g);
    for (int i = 0; i < SP_SLOTS; i++) sp_sample_free(e->slots[i]);
    for (sp_sample *s = e->retired; s;) {
        sp_sample *n = s->next_retired;
        sp_sample_free(s);
        s = n;
    }
    free(e->seq.pattern);
    free(e->seq.next);
    free(e->midi.map);
    free(e);
}

static void push(sp_engine *e, sp_cmd c) {
    if (!sp_push(e, &c)) {
        printf("  FAIL command queue full\n");
        failures++;
    }
}

/* A constant sample `frames` long (0.5 full scale). */
static void load(sp_engine *e, int slot, int64_t frames) {
    int16_t *data = malloc((size_t)frames * sizeof(int16_t));
    for (int64_t i = 0; i < frames; i++) data[i] = 16384;
    push(e, (sp_cmd){.type = SP_CMD_SAMPLE, .u.sample = {slot, sp_sample_wrap(data, frames, 1, RATE)}});
}

static void set_pad(sp_engine *e, int pad, int slot, int mode, int root, int choke) {
    sp_pad p = {.slot = slot, .gain = 1.0f, .mode = (uint8_t)mode, .root = (uint8_t)root, .choke = (uint8_t)choke};
    push(e, (sp_cmd){.type = SP_CMD_PAD, .pad = (uint8_t)pad, .u.pad = p});
}

static sp_midi_map *map_new(int in_channel, int out_channel, int clock) {
    sp_midi_map *m = calloc(1, sizeof(*m));
    m->in_channel = (uint8_t)in_channel;
    m->out_channel = (uint8_t)out_channel;
    m->clock = (uint8_t)clock;
    for (int i = 0; i < SP_PADS; i++) m->out_note[i] = -1;
    return m;
}

static void set_map(sp_engine *e, sp_midi_map *m) { push(e, (sp_cmd){.type = SP_CMD_MIDI_MAP, .u.map = m}); }

static void midi(sp_engine *e, uint8_t status, uint8_t d1, uint8_t d2, int64_t t_ns) {
    push(e, (sp_cmd){.type = SP_CMD_MIDI, .u.midi = {status, d1, d2, 0}, .t_ns = t_ns});
}

/* A message from input `src` (0: the Magpie port, 1..15: devices). */
static void midi_from(sp_engine *e, uint8_t src, uint8_t status, uint8_t d1, uint8_t d2) {
    push(e, (sp_cmd){.type = SP_CMD_MIDI, .u.midi = {status, d1, d2, src}});
}

static void trigger(sp_engine *e, int pad, int vel) {
    push(e, (sp_cmd){.type = SP_CMD_TRIGGER, .pad = (uint8_t)pad, .vel = (uint8_t)vel});
}

static void release(sp_engine *e, int pad) { push(e, (sp_cmd){.type = SP_CMD_RELEASE, .pad = (uint8_t)pad}); }

static void cmd(sp_engine *e, int type, double value) { push(e, (sp_cmd){.type = (uint8_t)type, .u.value = value}); }

/* What came out: events and MIDI, in order. */
static sp_event evs[1 << 16];
static int n_evs;
static mo_event outs[1 << 16];
static int n_outs;
static bool out_ordered = true;

static void collect(sp_engine *e) {
    sp_event ev;
    while (sp_pop_event(e, &ev))
        if (n_evs < (int)(sizeof(evs) / sizeof(evs[0]))) evs[n_evs++] = ev;
    mo_event m;
    while (mo_pop(&e->midi.out, &m)) {
        if (n_outs > 0 && m.frame < outs[n_outs - 1].frame) out_ordered = false;
        if (n_outs < (int)(sizeof(outs) / sizeof(outs[0]))) outs[n_outs++] = m;
    }
    sp_garbage g;
    while (sp_pop_garbage(e, &g)) sp_free_garbage(&g);
}

static void reset_log(void) {
    n_evs = 0;
    n_outs = 0;
    out_ordered = true;
}

static float scratch[2 * 4096];

/* Render `frames` in blocks of `block` (random 1..997 when 0). */
static void render(sp_engine *e, int64_t frames, int block) {
    for (int64_t done = 0; done < frames;) {
        int n = block > 0 ? block : 1 + (int)(next_rand() % 997);
        if (n > frames - done) n = (int)(frames - done);
        sp_render(e, scratch, n);
        collect(e);
        done += n;
    }
}

static int count_out(uint8_t b0) {
    int n = 0;
    for (int i = 0; i < n_outs; i++) n += outs[i].b[0] == b0;
    return n;
}

static const mo_event *find_out(uint8_t b0, int nth) {
    for (int i = 0; i < n_outs; i++)
        if (outs[i].b[0] == b0 && nth-- == 0) return &outs[i];
    return NULL;
}

static int voices_on(const sp_engine *e, int pad) {
    int n = 0;
    for (int i = 0; i < SP_VOICES; i++) n += e->voices[i].state == SP_V_ON && e->voices[i].pad == pad;
    return n;
}

static int voice_note(const sp_engine *e, int pad) {
    for (int i = 0; i < SP_VOICES; i++)
        if (e->voices[i].state == SP_V_ON && e->voices[i].pad == pad) return e->voices[i].note;
    return -999;
}

/* ── Parser ───────────────────────────────────────────────────────────────── */

static mi_msg parsed[64];
static int n_parsed;

static void on_msg(void *ctx, mi_msg m) {
    (void)ctx;
    if (n_parsed < 64) parsed[n_parsed++] = m;
}

static bool msg_is(int i, uint8_t s, uint8_t d1, uint8_t d2, uint8_t n) {
    return i < n_parsed && parsed[i].status == s && parsed[i].d1 == d1 && parsed[i].d2 == d2 && parsed[i].n == n;
}

static void test_parser(void) {
    printf("parser\n");
    mi_parser p = {0};
    n_parsed = 0;
    const uint8_t a[] = {0x90, 60, 100, 62, 0, 0xB3, 7, 99, 8, 1};
    mi_parse(&p, a, sizeof a, on_msg, NULL);
    CHECK(n_parsed == 4 && msg_is(0, 0x90, 60, 100, 3) && msg_is(1, 0x90, 62, 0, 3) && msg_is(2, 0xB3, 7, 99, 3) &&
              msg_is(3, 0xB3, 8, 1, 3),
          "running status: note-on, a running note-on (velocity 0 kept for the renderer), CC and a running CC");

    n_parsed = 0;
    const uint8_t b[] = {0x90, 64, 0xF8, 90, 0xFE, 0xC2, 5, 0xD1, 40};
    mi_parse(&p, b, sizeof b, on_msg, NULL);
    CHECK(n_parsed == 4 && msg_is(0, 0xF8, 0, 0, 1) && msg_is(1, 0x90, 64, 90, 3) && msg_is(2, 0xC2, 5, 0, 2) &&
              msg_is(3, 0xD1, 40, 0, 2),
          "a clock tick inside a note-on goes first, the note-on completes; active sensing dropped; 2-byte messages");

    n_parsed = 0;
    const uint8_t c1[] = {0xF0, 0x7E, 0x10, 0x01}, c2[] = {0x02, 0xF7, 0x80, 61};
    const uint8_t c3[] = {64, 0xF2, 0x10};
    const uint8_t c4[] = {0x02, 0x40, 0x41, 0xFA};
    mi_parse(&p, c1, sizeof c1, on_msg, NULL);
    mi_parse(&p, c2, sizeof c2, on_msg, NULL);
    mi_parse(&p, c3, sizeof c3, on_msg, NULL);
    mi_parse(&p, c4, sizeof c4, on_msg, NULL);
    CHECK(n_parsed == 3 && msg_is(0, 0x80, 61, 64, 3) && msg_is(1, 0xF2, 0x10, 0x02, 3) && msg_is(2, 0xFA, 0, 0, 1),
          "SysEx skipped, a message split across reads, song position; "
          "data after a system common message has no running status");
}

/* ── Notes in ─────────────────────────────────────────────────────────────── */

static void test_notes_in(void) {
    printf("notes in through the table\n");
    sp_engine *e = new_engine();
    load(e, 0, RATE * 10);
    set_pad(e, 0, 0, SP_ONE_SHOT, 36, 0);
    set_pad(e, 1, 0, SP_GATE, 38, 0);
    set_pad(e, 13, 0, SP_KEYS, 60, 0);
    set_pad(e, 20, 0, SP_ONE_SHOT, 36, 0); /* another bank, same note: layered */
    sp_midi_map *m = map_new(2, 2, SP_CLOCK_INTERNAL);
    m->notes[36] = (1ull << 0) | (1ull << 20);
    m->notes[38] = 1ull << 1;
    for (int n = 0; n < 128; n++)
        if (!m->notes[n]) m->notes[n] = 1ull << 13; /* keys take the rest */
    m->out_note[0] = 36;
    m->out_note[1] = 38;
    m->out_note[13] = 60;
    set_map(e, m);
    render(e, 256, 256);
    reset_log();

    midi(e, 0x90, 36, 100, 0); /* channel 1: not ours */
    render(e, 256, 256);
    CHECK(voices_on(e, 0) == 0, "a note on channel 1 with in_channel 2 plays nothing");

    midi(e, 0x91, 36, 100, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 0) == 1 && voices_on(e, 20) == 1, "note 36 on channel 2 plays both pads whose note it is");
    CHECK(e->voices[0].gain > 0.61f && e->voices[0].gain < 0.63f, "velocity passes through: 100 → gain (100/127)² = %.3f",
          e->voices[0].gain);
    CHECK(n_outs == 0, "MIDI-started voices send nothing out (no echo)");

    midi(e, 0x91, 38, 90, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 1) == 1, "note 38 starts the gate pad");
    midi(e, 0x91, 38, 0, 0); /* note-on velocity 0 = off */
    render(e, 256, 256);
    CHECK(voices_on(e, 1) == 0, "note-on with velocity 0 releases it");

    midi(e, 0x91, 67, 80, 0);
    midi(e, 0x91, 72, 80, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 13) == 2, "two unclaimed notes play the keys pad twice");
    midi(e, 0x81, 67, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 13) == 1 && voice_note(e, 13) == 72, "note-off 67 releases only that note's voice (72 sounds)");
    double step = 0;
    for (int i = 0; i < SP_VOICES; i++)
        if (e->voices[i].state == SP_V_ON && e->voices[i].pad == 13) step = e->voices[i].step;
    CHECK(fabs(step - pow(2.0, 12 / 12.0)) < 1e-9, "keys: 72 over root 60 plays an octave up (step %.6f)", step);

    midi(e, 0x81, 36, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 0) == 1, "note-off doesn't stop a one-shot");

    midi(e, 0xB1, 123, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 13) == 0 && voices_on(e, 0) == 1, "CC 123 releases the keys voice, the one-shot rings");
    midi(e, 0xB1, 120, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 0) == 0 && voices_on(e, 20) == 0, "CC 120 cuts every MIDI voice");

    trigger(e, 0, 100);
    render(e, 256, 256);
    midi(e, 0xB1, 120, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 0) == 1, "CC 120 leaves a touched voice alone");

    set_map(e, map_new(0, 1, SP_CLOCK_INTERNAL));
    render(e, 256, 256);
    midi(e, 0x95, 36, 100, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 0) == 1 && voices_on(e, 20) == 0, "a new table (nothing mapped) plays nothing, any channel");
    set_map(e, NULL);
    render(e, 256, 256);
    free_engine(e);
}

/* A new table while MIDI voices sound: each is released by the note-off of
 * the note and channel that started it, whatever the table says now. */
static sp_midi_map *table_map(int in_channel, int gate_note, int drum_note) {
    sp_midi_map *m = map_new(in_channel, 1, SP_CLOCK_INTERNAL);
    m->notes[gate_note] = 1ull << 1;
    if (drum_note >= 0) m->notes[drum_note] = 1ull << 0;
    for (int n = 0; n < 128; n++)
        if (!m->notes[n]) m->notes[n] = 1ull << 13;
    return m;
}

static void test_table_change(void) {
    printf("notes in: the table changes while voices sound\n");
    sp_engine *e = new_engine();
    load(e, 0, RATE * 10);
    set_pad(e, 0, 0, SP_ONE_SHOT, 36, 0);
    set_pad(e, 1, 0, SP_GATE, 38, 0);
    set_pad(e, 13, 0, SP_KEYS, 60, 0);
    set_map(e, table_map(1, 38, -1));
    render(e, 256, 256);

    midi(e, 0x90, 38, 100, 0);
    render(e, 256, 256);
    set_map(e, table_map(2, 38, -1));
    render(e, 256, 256);
    midi(e, 0x80, 38, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 1) == 0, "a gate voice from channel 1, the table moved to channel 2: its channel-1 note-off "
                                "releases it");

    set_map(e, table_map(0, 38, -1));
    render(e, 256, 256);
    midi(e, 0x90, 67, 100, 0);
    render(e, 256, 256);
    set_map(e, table_map(0, 38, 67));
    render(e, 256, 256);
    midi(e, 0x80, 67, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 13) == 0, "a keys note held, its note given to a drum pad: the note-off releases the keys voice");

    midi(e, 0x90, 38, 100, 0);
    render(e, 256, 256);
    set_map(e, table_map(0, 41, -1)); /* the gate pad's midi_note changed */
    render(e, 256, 256);
    midi(e, 0x90, 38, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 1) == 0, "a gate pad's note changed while it sounds: the old note's note-off releases it");

    midi(e, 0x90, 41, 100, 0);
    render(e, 256, 256);
    midi(e, 0x82, 41, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 1) == 1, "omni: a note-off on another channel leaves the voice its note started on channel 1");
    midi(e, 0x80, 41, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 1) == 0, "  its own channel's releases it");

    trigger(e, 1, 100);
    render(e, 256, 256);
    midi(e, 0x80, 41, 0, 0);
    render(e, 256, 256);
    CHECK(voices_on(e, 1) == 0, "a touched gate voice: the pad's note-off still releases it, through the table");

    /* CC 123 on the channel a voice was started on, after the table moved to
     * another channel: released. */
    set_map(e, table_map(1, 38, -1));
    render(e, 256, 256);
    midi(e, 0x90, 38, 100, 0);
    render(e, 256, 256);
    set_map(e, table_map(2, 38, -1));
    render(e, 256, 256);
    midi(e, 0xB1, 123, 0, 0);
    render(e, 256, 256);
    bool kept = voices_on(e, 1) == 1;
    midi(e, 0xB0, 123, 0, 0);
    render(e, 256, 256);
    CHECK(kept && voices_on(e, 1) == 0,
          "CC 123: another channel's leaves a voice; its own channel's releases it after the table moved off it");

    /* Inputs: a note-off from another input leaves a voice; the input gone
     * releases what it held (a one-shot rings on). Input 63: mob_midi's
     * highest source id, the top bit of the gone mask. */
    set_map(e, table_map(0, 38, 36));
    render(e, 256, 256);
    midi_from(e, 63, 0x90, 38, 100);
    midi_from(e, 63, 0x90, 36, 100);
    midi_from(e, 4, 0x90, 67, 100);
    render(e, 256, 256);
    midi_from(e, 4, 0x80, 38, 0);
    render(e, 256, 256);
    kept = voices_on(e, 1) == 1;
    atomic_fetch_or(&e->midi.gone, 1ull << 63);
    for (int i = 0; i < SP_CMDS; i++) push(e, (sp_cmd){.type = SP_CMD_SWING, .u.value = 0.5}); /* the queue full */
    render(e, 256, 256);
    CHECK(kept && voices_on(e, 1) == 0 && voices_on(e, 0) == 1 && voices_on(e, 13) == 1,
          "another input's note-off leaves a voice; its input gone releases its gate voice, the one-shot rings, "
          "another input's keys voice sounds");

    /* No stream: a note-off still releases (applied offline, at once);
     * a note-on doesn't play. */
    midi_from(e, 4, 0x80, 67, 0);
    midi_from(e, 4, 0x90, 38, 100);
    sp_drain(e, false);
    collect(e);
    CHECK(voices_on(e, 13) == 0 && voices_on(e, 1) == 0, "no stream: a note-off releases its voice, a note-on plays "
                                                         "nothing");

    /* An input gone with its note-on still queued (unplugged before the next
     * block): the release goes after the note-on, in queue order, and a
     * note-on its next port sends after that plays on. */
    render(e, 256, 256);
    midi_from(e, 3, 0x90, 38, 100);
    push(e, (sp_cmd){.type = SP_CMD_MIDI_GONE, .u.midi = {.src = 3}});
    midi_from(e, 3, 0x90, 67, 100);
    render(e, 256, 256);
    bool ordered = voices_on(e, 1) == 0 && voices_on(e, 13) == 1;
    midi_from(e, 3, 0x80, 67, 0);
    render(e, 256, 256);
    ordered = ordered && voices_on(e, 13) == 0;
    /* The full queue refused the gone, or a note-off (the bit): applied
     * after what was queued, so a note-on still queued ends too. */
    midi_from(e, 3, 0x90, 38, 100);
    while (sp_push(e, &(sp_cmd){.type = SP_CMD_MIDI, .u.midi = {0xE0, 0, 64, 3}})) {
    }
    atomic_fetch_or(&e->midi.gone, 1u << 3);
    render(e, 256, 256);
    CHECK(ordered && voices_on(e, 1) == 0,
          "an input gone with its note-on still queued: released after it (in queue order; as the bit with the queue "
          "full); its next port's note-on after the gone plays");
    set_map(e, NULL);
    render(e, 256, 256);
    free_engine(e);
}

/* ── Notes out ────────────────────────────────────────────────────────────── */

static void test_notes_out(void) {
    printf("notes out\n");
    sp_engine *e = new_engine();
    load(e, 0, 1000);      /* a short one-shot */
    load(e, 1, RATE * 10); /* long */
    set_pad(e, 0, 0, SP_ONE_SHOT, 36, 0);
    set_pad(e, 1, 1, SP_GATE, 38, 0);
    set_pad(e, 2, 1, SP_KEYS, 60, 0);
    set_pad(e, 3, 1, SP_ONE_SHOT, 42, 1);
    set_pad(e, 4, 1, SP_ONE_SHOT, 46, 1);
    set_pad(e, 5, 1, SP_ONE_SHOT, 60, 0); /* no midi_note: sends nothing */
    sp_midi_map *m = map_new(0, 10, SP_CLOCK_INTERNAL);
    m->out_note[0] = 36;
    m->out_note[1] = 38;
    m->out_note[2] = 60;
    m->out_note[3] = 42;
    m->out_note[4] = 46;
    set_map(e, m);
    render(e, 100, 100);
    reset_log();

    trigger(e, 0, 99);
    render(e, 2000, 100);
    const mo_event *on = find_out(0x99, 0), *off = find_out(0x89, 0);
    CHECK(on && on->frame == 100 && on->b[1] == 36 && on->b[2] == 99, "touch: note-on 36 vel 99 on channel 10 at its first frame (%lld)",
          on ? (long long)on->frame : -1);
    CHECK(off && off->frame == 1100 && off->b[1] == 36, "a one-shot's note-off when it ends (frame %lld, want 1100)",
          off ? (long long)off->frame : -1);

    reset_log();
    trigger(e, 1, 80);
    render(e, 300, 100);
    release(e, 1);
    render(e, 300, 100);
    on = find_out(0x99, 0);
    off = find_out(0x89, 0);
    CHECK(on && off && on->b[1] == 38 && off->b[1] == 38 && off->frame - on->frame == 300,
          "gate: note-off on the release's frame, 300 frames after the note-on");

    reset_log();
    push(e, (sp_cmd){.type = SP_CMD_NOTE_ON, .pad = 2, .note = 67, .vel = 70});
    render(e, 100, 100);
    push(e, (sp_cmd){.type = SP_CMD_NOTE_OFF, .pad = 2, .note = 67});
    render(e, 100, 100);
    on = find_out(0x99, 0);
    off = find_out(0x89, 0);
    CHECK(on && off && on->b[1] == 67 && off->b[1] == 67, "keys: the note it plays goes out (67), and its note-off");

    reset_log();
    trigger(e, 3, 100);
    render(e, 100, 100);
    trigger(e, 4, 100);
    render(e, 100, 100);
    off = find_out(0x89, 0);
    CHECK(off && off->b[1] == 42 && off->frame == find_out(0x99, 1)->frame,
          "choke: the open hat's start sends the closed hat's note-off on the same frame");
    trigger(e, 5, 100);
    render(e, 100, 100);
    CHECK(count_out(0x99) == 2, "a pad without a midi_note sends nothing");

    /* The sequencer: a step's note-on on its frame, its gate pad's off a step later. */
    reset_log();
    sp_pattern *p = sp_pattern_new(2);
    p->id = 1;
    p->length = 16 * SP_STEP;
    p->steps[0] = (sp_step){0, 1, 100, -1};
    p->steps[1] = (sp_step){4 * SP_STEP, 1, 100, -1};
    push(e, (sp_cmd){.type = SP_CMD_PATTERN, .u.pattern = {p, false}});
    cmd(e, SP_CMD_TEMPO, 120);
    push(e, (sp_cmd){.type = SP_CMD_PLAY});
    render(e, RATE, 0);
    int64_t start = find_out(0x99, 0) ? find_out(0x99, 0)->frame : -1;
    const mo_event *off1 = find_out(0x89, 0), *on2 = find_out(0x99, 1);
    /* 120 bpm: a step is 6000 frames. */
    CHECK(off1 && on2 && off1->frame - start == 6000 && on2->frame - start == 24000,
          "sequenced gate pad: note-on on the step, note-off on the next step's frame (+%lld), the next note-on 4 steps on (+%lld)",
          off1 ? (long long)(off1->frame - start) : -1, on2 ? (long long)(on2->frame - start) : -1);
    push(e, (sp_cmd){.type = SP_CMD_STOP});
    render(e, 1000, 0);
    CHECK(count_out(0x99) == count_out(0x89), "every note-on has its note-off (%d / %d)", count_out(0x99),
          count_out(0x89));
    CHECK(out_ordered, "out messages queued in frame order (random blocks)");
    free_engine(e);
}

/* ── Clock send ───────────────────────────────────────────────────────────── */

/* The sequencer's position at frame f, from first principles: play at
 * frame 0 at `bpm1`, `bpm2` from frame `fc` (applied at the block starting
 * there). */
static double ticks_at(double f, double bpm1, double bpm2, int64_t fc) {
    double t1 = bpm1 * SP_PPQN / (60.0 * RATE), t2 = bpm2 * SP_PPQN / (60.0 * RATE);
    return f < fc ? f * t1 : (double)fc * t1 + (f - (double)fc) * t2;
}

static void test_clock_send(void) {
    printf("clock send\n");
    const double tempos[][2] = {{120, 120}, {97, 133.5}, {40, 240}, {240, 41}, {173.25, 96}};
    for (size_t ti = 0; ti < sizeof(tempos) / sizeof(tempos[0]); ti++) {
        double b1 = tempos[ti][0], b2 = tempos[ti][1];
        sp_engine *e = new_engine();
        set_map(e, map_new(0, 1, SP_CLOCK_SEND));
        cmd(e, SP_CMD_TEMPO, b1);
        render(e, 64, 64);
        int64_t play_at = e->frame;
        reset_log();
        push(e, (sp_cmd){.type = SP_CMD_PLAY});
        render(e, 3 * RATE, 0);
        int64_t fc = e->frame - play_at;
        cmd(e, SP_CMD_TEMPO, b2);
        render(e, 3 * RATE, 0);
        int64_t end = e->frame - play_at;

        const mo_event *spp = find_out(0xF2, 0), *start = find_out(0xFA, 0), *first = find_out(0xF8, 0);
        bool head = n_outs > 3 && &outs[0] == spp && &outs[1] == start && &outs[2] == first && spp->frame == play_at &&
                    start->frame == play_at && first->frame == play_at && spp->b[1] == 0 && spp->b[2] == 0;
        int bad = 0, k = 0;
        for (int i = 0; i < n_outs; i++) {
            if (outs[i].b[0] != 0xF8) continue;
            double f = (double)(outs[i].frame - play_at), x = 4.0 * k;
            /* The first frame at or after the tick's position. */
            if (!(ticks_at(f, b1, b2, fc) >= x - 1e-6 && ticks_at(f - 1, b1, b2, fc) < x - 1e-6)) bad++;
            k++;
        }
        int want = (int)floor(ticks_at((double)(end - 1), b1, b2, fc) / 4 + 1e-9) + 1;
        CHECK(head && bad == 0 && k == want,
              "%g → %g bpm at frame %lld: song position 0, Start, then %d ticks each on the first frame at or after its "
              "position (%d off, %d expected)",
              b1, b2, (long long)fc, k, bad, want);
        CHECK(out_ordered, "  in frame order");

        /* Stop: Stop on its frame, the clock runs on in phase at the tempo. */
        reset_log();
        int64_t stop_at = e->frame;
        double m_stop = ticks_at((double)(stop_at - play_at), b1, b2, fc);
        push(e, (sp_cmd){.type = SP_CMD_STOP});
        render(e, RATE, 0);
        const mo_event *stop = find_out(0xFC, 0), *t0 = find_out(0xF8, 0), *t1 = find_out(0xF8, 1),
                       *t9 = find_out(0xF8, 9);
        double period = 60.0 * RATE / (b2 * 24.0);
        double next = (floor(m_stop / 4) + 1) * 4, want0 = (double)fc + (next - ticks_at((double)fc, b1, b2, fc)) /
                                                                         (b2 * SP_PPQN / (60.0 * RATE));
        CHECK(stop && stop->frame == stop_at && t0 && t1 && t9 &&
                  llabs(t0->frame - play_at - (int64_t)ceil(want0 - 1e-6)) <= 1 &&
                  llabs((t9->frame - t1->frame) - (int64_t)llround(8 * period)) <= 1,
              "  stopped: Stop on the stop frame, the next tick where it was due, then every %.1f frames", period);
        free_engine(e);
    }

    /* Stopped from the start, at a tempo change: a free-running clock. */
    sp_engine *e = new_engine();
    set_map(e, map_new(0, 1, SP_CLOCK_SEND));
    cmd(e, SP_CMD_TEMPO, 100);
    reset_log();
    render(e, RATE, 0);
    int n = count_out(0xF8);
    CHECK(n == 40 && find_out(0xF8, 0)->frame == 0 && find_out(0xF8, 39)->frame == 46800,
          "stopped at 100 bpm: a tick every 1200 frames from the first block (%d in a second)", n);
    set_map(e, map_new(0, 1, SP_CLOCK_INTERNAL));
    reset_log();
    render(e, RATE, 0);
    CHECK(n_outs == 0, "internal clock: nothing goes out");
    free_engine(e);
}

/* ── Clock in: not followed ───────────────────────────────────────────────── */

#define CLOCK0 1000000000LL

/* The engine hears frame f at CLOCK0 + f/RATE (sp_set_clock(e, 0, CLOCK0)). */
static int64_t heard_ns(int64_t frame) { return CLOCK0 + frame * 1000000000LL / RATE; }

/* An incoming clock is not followed (yet): 2 s of a 140 bpm master (Start,
 * ticks, Stop, song position 8 + Continue, ticks) do nothing. Internal:
 * the sequencer stays stopped and nothing goes out. Send, playing at the
 * kit's 100 bpm: it plays on at that tempo and its own clock goes out
 * unchanged, no transport. */
static void test_clock_in(void) {
    printf("clock in: ignored\n");
    const int period = RATE * 60 / (140 * 24); /* frames per incoming tick */
    for (int send = 0; send < 2; send++) {
        sp_engine *e = new_engine();
        sp_set_clock(e, 0, CLOCK0);
        set_map(e, map_new(0, 1, send ? SP_CLOCK_SEND : SP_CLOCK_INTERNAL));
        cmd(e, SP_CMD_TEMPO, 100);
        if (send) push(e, (sp_cmd){.type = SP_CMD_PLAY});
        render(e, 240, 240);
        double tpf = e->seq.tpf;
        reset_log();
        midi(e, 0xFA, 0, 0, heard_ns(e->frame));
        for (int b = 0; b < 400; b++) {
            if (b == 200) {
                midi(e, 0xFC, 0, 0, heard_ns(e->frame));
                midi(e, 0xF2, 8, 0, heard_ns(e->frame));
                midi(e, 0xFB, 0, 0, heard_ns(e->frame));
            }
            for (int64_t f = e->frame + period - 1 - (e->frame + period - 1) % period; f < e->frame + 240; f += period)
                midi(e, 0xF8, 0, 0, heard_ns(f));
            render(e, 240, 240);
        }
        int ticks = count_out(0xF8), transport = count_out(0xFA) + count_out(0xFC) + count_out(0xF2);
        if (send)
            CHECK(e->seq.playing && e->seq.tpf == tpf && ticks >= 79 && ticks <= 81 && transport == 0,
                  "clock send, playing: an incoming clock and transport change nothing (%d ticks out in 2 s at 100 "
                  "bpm, %d transport)",
                  ticks, transport);
        else
            CHECK(!e->seq.playing && n_outs == 0 && e->seq.tpf == tpf,
                  "internal clock: an incoming Start, ticks, Stop, song position and Continue do nothing");
        free_engine(e);
    }
}

/* ── Notes out: one note open per channel and note; note-offs always out ── */

static void test_out_pairing(void) {
    printf("notes out: pairing\n");
    sp_engine *e = new_engine();
    load(e, 0, RATE * 10);
    set_pad(e, 0, 0, SP_ONE_SHOT, 36, 0);
    set_pad(e, 1, 0, SP_GATE, 38, 0);
    sp_midi_map *m = map_new(0, 1, SP_CLOCK_INTERNAL);
    m->out_note[0] = 36;
    m->out_note[1] = 38;
    set_map(e, m);
    render(e, 100, 100);

    reset_log();
    trigger(e, 0, 100);
    render(e, 100, 100);
    trigger(e, 0, 90);
    render(e, 100, 100);
    CHECK(n_outs == 3 && outs[0].b[0] == 0x90 && outs[1].b[0] == 0x80 && outs[1].frame == 200 && outs[2].b[0] == 0x90 &&
              outs[2].frame == 200 && outs[2].b[2] == 90,
          "a one-shot retriggered while it rings: the first voice's note-off, then the new note-on, on one frame");
    render(e, RATE * 11, 0);
    CHECK(count_out(0x90) == 2 && count_out(0x80) == 2, "  and the second's note-off when it ends (%d on, %d off)",
          count_out(0x90), count_out(0x80));

    /* A voice ended while no audio runs (a pad change with stop, applied by
     * sp_drain): its note-off waits for the next block, late, not lost. */
    reset_log();
    trigger(e, 1, 100);
    render(e, 100, 100);
    sp_pad one_shot = {.slot = 0, .gain = 1.0f, .mode = SP_ONE_SHOT, .root = 38};
    push(e, (sp_cmd){.type = SP_CMD_PAD, .pad = 1, .stop = 1, .u.pad = one_shot});
    sp_drain(e, false);
    collect(e);
    int offs_offline = count_out(0x80);
    render(e, 100, 100);
    CHECK(count_out(0x90) == 1 && offs_offline == 0 && count_out(0x80) == 1 && voices_on(e, 1) == 0,
          "a gate voice cut with no stream: its note-off goes out with the next block");
    free_engine(e);

    /* The out queue full of other messages: a note-on that doesn't get in
     * leaves its voice with no note open, so no note-off follows it
     * (released in a later block, or in the same one). */
    e = new_engine();
    load(e, 0, RATE * 10);
    set_pad(e, 1, 0, SP_GATE, 38, 0);
    m = map_new(0, 1, SP_CLOCK_INTERNAL);
    m->out_note[1] = 38;
    set_map(e, m);
    render(e, 100, 100);
    mo_event fill = {.frame = 0, .len = 1, .kind = MO_CLOCK, .b = {0xF8}};
    for (int same = 0; same < 2; same++) {
        reset_log();
        while (mo_push(&e->midi.out, &fill, SP_VOICES)) continue;
        trigger(e, 1, 100);
        if (same) release(e, 1);
        sp_render(e, scratch, 100);
        collect(e);
        release(e, 1);
        render(e, 100, 100);
        CHECK(count_out(0x90) == 0 && count_out(0x80) == 0,
              "out queue full: a gate's note-on refused, no note-off when it is released %s (%d on, %d off)",
              same ? "in the same block" : "a block later", count_out(0x90), count_out(0x80));
    }
    reset_log();
    trigger(e, 1, 100);
    render(e, 100, 100);
    release(e, 1);
    render(e, 100, 100);
    CHECK(count_out(0x90) == 1 && count_out(0x80) == 1, "  with room again, note-on and note-off");
    free_engine(e);

    /* The out queue keeps its last places for note-offs. */
    static mo_ring r;
    memset(&r, 0, sizeof(r));
    mo_event tick = {.frame = 0, .len = 1, .kind = MO_CLOCK, .b = {0xF8}};
    mo_event off = {.frame = 0, .len = 3, .kind = MO_NOTE, .b = {0x80, 36, 64}};
    int in = 0;
    while (mo_push(&r, &tick, SP_VOICES)) in++;
    int offs = 0;
    while (mo_push(&r, &off, 0)) offs++;
    CHECK(in == MO_RING - SP_VOICES && offs == SP_VOICES, "a full out queue: %d ticks in, then still %d note-offs", in, offs);

    /* A stream restart: what an earlier stream left in the queue goes on as
     * the notes whose other half went out. */
    memset(&r, 0, sizeof(r));
    const mo_event left[] = {
        {.len = 3, .kind = MO_NOTE, .b = {0x80, 40, 64}},  /* its note-on went out: goes */
        {.len = 3, .kind = MO_NOTE, .b = {0x90, 36, 100}}, /* never out … */
        tick,
        {.len = 3, .kind = MO_NOTE, .b = {0x80, 36, 64}},  /* … nor its note-off */
        {.len = 3, .kind = MO_NOTE, .b = {0x91, 36, 100}}, /* another channel, still held: goes */
        {.len = 3, .kind = MO_NOTE, .b = {0x90, 38, 100}}, /* still held: goes */
    };
    for (size_t i = 0; i < sizeof(left) / sizeof(left[0]); i++) mo_push(&r, &left[i], 0);
    static mo_event stale[MO_RING];
    int n_stale = mo_take_stale(&r, stale);
    CHECK(n_stale == 3 && stale[0].b[0] == 0x80 && stale[0].b[1] == 40 && stale[1].b[0] == 0x91 &&
              stale[2].b[0] == 0x90 && stale[2].b[1] == 38,
          "a stream restart: an unsent note-on and its note-off are dropped; a sent one's note-off and a held "
          "voice's note-on go (%d)",
          n_stale);
}

/* ── MIDI hits while playing ──────────────────────────────────────────────── */

static void test_hits(void) {
    printf("live record from MIDI\n");
    sp_engine *e = new_engine();
    sp_set_clock(e, 0, CLOCK0);
    load(e, 0, RATE);
    set_pad(e, 0, 0, SP_ONE_SHOT, 36, 0);
    sp_midi_map *m = map_new(0, 1, SP_CLOCK_INTERNAL);
    m->notes[36] = 1;
    set_map(e, m);
    cmd(e, SP_CMD_TEMPO, 120);
    push(e, (sp_cmd){.type = SP_CMD_PLAY});
    render(e, 240, 240);
    int64_t play = e->frame - 240;
    render(e, 6000 * 5, 240);
    reset_log();
    /* Played when step 3 (+3 ticks) was heard, arriving now. */
    int64_t when = heard_ns(play + 3 * 6000 + 3 * 250);
    midi(e, 0x90, 36, 77, when);
    render(e, 240, 240);
    const sp_event *hit = NULL;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_HIT) hit = &evs[i];
    CHECK(hit && hit->a == 3 && hit->b == 3 && hit->vel == 77,
          "a note while playing is a hit stamped where it was played (step %d tick %d)", hit ? hit->a : -1,
          hit ? hit->b : -99);
    const sp_event *trig = NULL;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_TRIGGERED) trig = &evs[i];
    CHECK(trig && trig->b == 1 && trig->t_ns == when, "its triggered event is marked MIDI and carries its timestamp");
    free_engine(e);
}

/* ── Outputs (midi_out.c) against a fake mob_midi port ──────────────────── */

/* The port: mob_midi_send answers `mode`; what it takes queues until
 * port_deliver hands it to the listener, whose sounding notes it tracks; a
 * discard drops the queue. */
static struct {
    int mode;
    uint8_t queued[16384];
    size_t n_queued;
    bool sounding[MIDI_NOTES];
    int discards;
} port;

int mob_midi_send(mob_midi_port handle, const uint8_t *bytes, size_t len, int64_t at_ns) {
    (void)handle;
    (void)at_ns;
    if (port.mode != MOB_MIDI_OK) return port.mode;
    if (port.n_queued + len > sizeof(port.queued)) return MOB_MIDI_ERR_QUEUE_FULL;
    memcpy(port.queued + port.n_queued, bytes, len);
    port.n_queued += len;
    return MOB_MIDI_OK;
}

int mob_midi_discard(mob_midi_port handle) {
    (void)handle;
    port.discards++;
    port.n_queued = 0;
    return port.discards;
}

/* Every message is whole, with its status byte (the renderer's). */
static void port_deliver(void) {
    for (size_t i = 0; i < port.n_queued;) {
        uint8_t st = port.queued[i];
        if (st >= 0xF0) {
            i++;
            continue;
        }
        int b = (st & 0x0F) * 128 + port.queued[i + 1];
        if ((st & 0xF0) == 0x90 && port.queued[i + 2] > 0) port.sounding[b] = true;
        else if ((st & 0xF0) == 0x80 || (st & 0xF0) == 0x90) port.sounding[b] = false;
        i += 3;
    }
    port.n_queued = 0;
}

static int port_sounding(void) {
    int n = 0;
    for (int i = 0; i < MIDI_NOTES; i++) n += port.sounding[i];
    return n;
}

static void port_reset(int mode) {
    memset(&port, 0, sizeof(port));
    port.mode = mode;
}

static mo_event ev_note(bool on, int ch, int note) {
    return (mo_event){.kind = MO_NOTE, .len = 3, .b = {(uint8_t)((on ? 0x90 : 0x80) | ch), (uint8_t)note, on ? 100 : 64}};
}

static const mo_event EV_TICK = {.kind = MO_CLOCK, .len = 1, .b = {0xF8}};

static void out_batch(midi_out *o, const mo_event *evs, int count) {
    uint8_t buf[256];
    int n = 0;
    for (int i = 0; i < count; i++) {
        memcpy(buf + n, evs[i].b, evs[i].len);
        n += evs[i].len;
    }
    out_send(o, buf, n, evs, count, 0);
}

static void out_one(midi_out *o, mo_event ev) { out_batch(o, &ev, 1); }

static void test_outputs(void) {
    printf("outputs (a port that stalls)\n");
    midi_out o = {.handle = 1};
    port_reset(MOB_MIDI_OK);

    /* A note-off refused: owed, and first out once the port drained. */
    out_one(&o, ev_note(true, 0, 36));
    port_deliver();
    port.mode = MOB_MIDI_ERR_QUEUE_FULL;
    out_one(&o, ev_note(false, 0, 36));
    out_one(&o, EV_TICK);
    out_one(&o, ev_note(true, 0, 38));
    bool refusing = o.refusing && port.discards == 1 && port_sounding() == 1;
    port.mode = MOB_MIDI_OK;
    out_one(&o, EV_TICK);
    bool first = port.n_queued == 4 && port.queued[0] == 0x80 && port.queued[1] == 36 && port.queued[3] == 0xF8;
    port_deliver();
    out_one(&o, ev_note(false, 0, 38));
    port_deliver();
    CHECK(refusing && first && !o.refusing && port_sounding() == 0,
          "a refused note-off: one discard while refusing, owed and sent before the next batch once drained; the "
          "note-on refused meanwhile owes nothing");

    /* A note-off the port took, dropped by the discard at the refusal: owed,
     * and sent with nothing else to send (out_retry). */
    uint64_t paid = OUT_STATS.offs_owed;
    out_one(&o, ev_note(true, 2, 40));
    port_deliver();
    out_one(&o, ev_note(false, 2, 40));
    port.mode = MOB_MIDI_ERR_QUEUE_FULL;
    out_one(&o, EV_TICK);
    out_retry(&o);
    bool still = port_sounding() == 1 && o.refusing;
    port.mode = MOB_MIDI_OK;
    out_retry(&o);
    port_deliver();
    CHECK(still && !o.refusing && port_sounding() == 0 && OUT_STATS.offs_owed > paid,
          "a note-off the discard dropped: owed, sent by the retry once drained (none while still refusing)");

    /* The note held again (a note-on taken after its note-off): the owed
     * note-off isn't sent, so it doesn't cut the note; its own one ends it.
     * (A fresh output: note-offs taken since the last refusal, 36 and 40
     * above, would be owed too, harmless extra ones.) */
    o = (midi_out){.handle = 1};
    port_reset(MOB_MIDI_OK);
    out_one(&o, ev_note(true, 0, 42));
    port_deliver();
    out_one(&o, ev_note(false, 0, 42));
    out_one(&o, ev_note(true, 0, 42));
    port.mode = MOB_MIDI_ERR_QUEUE_FULL;
    out_one(&o, EV_TICK);
    port.mode = MOB_MIDI_OK;
    out_retry(&o);
    out_one(&o, EV_TICK);
    bool kept = port.n_queued == 1 && port.queued[0] == 0xF8;
    port_deliver();
    kept = kept && port.sounding[42];
    out_one(&o, ev_note(false, 0, 42));
    port_deliver();
    CHECK(kept && port_sounding() == 0, "a note held again isn't sent its owed note-off; its voice's own ends it");

    /* Nobody listening (Magpie's own output): nothing is owed. */
    out_one(&o, ev_note(true, 0, 50));
    port_deliver();
    port.mode = MOB_MIDI_ERR_NO_LISTENER;
    out_one(&o, ev_note(false, 0, 50));
    CHECK(!o.refusing && !out_owes(&o) && !bit_test(o.held, 50), "no listener: nothing held or owed");

    /* Random stalls under a renderer's notes (one open per channel and
     * note, every note-on its note-off): once every voice has ended and the
     * port drained, nothing sounds at the listener. */
    rng = 7;
    int stuck_runs = 0;
    for (int run = 0; run < 200; run++) {
        o = (midi_out){.handle = 1};
        port_reset(MOB_MIDI_OK);
        bool open[8] = {false};
        for (int k = 0; k < 400; k++) {
            unsigned r = next_rand() % 100;
            if (r < 8) port.mode = port.mode == MOB_MIDI_OK ? MOB_MIDI_ERR_QUEUE_FULL : MOB_MIDI_OK;
            if (r < 30 && port.mode == MOB_MIDI_OK) port_deliver();
            mo_event evs[4];
            int count = 0;
            int msgs = 1 + (int)(next_rand() % 3);
            for (int m = 0; m < msgs; m++) {
                int i = (int)(next_rand() % 8);
                if (next_rand() % 4 == 0) {
                    evs[count++] = EV_TICK;
                } else if (open[i]) {
                    evs[count++] = ev_note(false, i & 1, 36 + i);
                    open[i] = false;
                } else {
                    evs[count++] = ev_note(true, i & 1, 36 + i);
                    open[i] = true;
                }
            }
            out_batch(&o, evs, count);
            if (next_rand() % 5 == 0) out_retry(&o);
        }
        mo_event offs[8];
        int n_offs = 0;
        for (int i = 0; i < 8; i++)
            if (open[i]) offs[n_offs++] = ev_note(false, i & 1, 36 + i);
        port.mode = MOB_MIDI_OK;
        out_retry(&o);
        if (n_offs) out_batch(&o, offs, n_offs);
        out_retry(&o);
        port_deliver();
        stuck_runs += port_sounding() > 0;
    }
    CHECK(stuck_runs == 0, "200 runs of random stalls, discards and deliveries: no note left sounding (%d runs with one)",
          stuck_runs);
}

int main(void) {
    test_parser();
    test_notes_in();
    test_table_change();
    test_notes_out();
    test_clock_send();
    test_clock_in();
    test_out_pairing();
    test_hits();
    test_outputs();
    printf(failures ? "FAILED: %d\n" : "passed: 0 failures\n", failures);
    return failures ? 1 : 0;
}
