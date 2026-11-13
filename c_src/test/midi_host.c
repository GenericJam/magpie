/*
 * Host harness for Magpie's MIDI in c_src/sampler.c and c_src/midi.c:
 * the parser, notes in through the kit's table (channel filter, keys
 * mode, releases, all-notes-off, no echo), notes out (note-on on the
 * voice's first frame, note-off when it stops sounding at full), clock
 * send (every tick on its exact frame through tempo changes, Start / song
 * position / Stop, the free-running clock while stopped) and clock follow
 * (lock and jitter on a clock with jittery timestamps, tempo changes,
 * Stop, Continue from a song position, a gap; lost ticks alone, in
 * clusters and soon after the fit restarts, dropouts, tempo drops).
 *
 *   cc -O2 -Wall -Wextra -o /tmp/midi_host c_src/test/midi_host.c -lm && /tmp/midi_host
 *   cc -g -O1 -fsanitize=address,undefined -o /tmp/midi_host_asan c_src/test/midi_host.c -lm && /tmp/midi_host_asan
 *
 * Exit 1 on any failure; each check prints one line.
 */

#include <stdio.h>
#include <stdlib.h>

#include "../sampler.c"

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

/* Uniform in [-1, 1]. */
static double unit(void) { return (double)next_rand() / 16383.5 - 1.0; }

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
    push(e, (sp_cmd){.type = SP_CMD_MIDI, .u.midi = {status, d1, d2}, .t_ns = t_ns});
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

/* ── Clock follow ─────────────────────────────────────────────────────────── */

#define LAT 720          /* frames the stream renders ahead of what is heard */
#define BLOCK 240        /* the callback's burst */
#define CLOCK0 1000000000LL

/* The master: ticks at `bpm` from time `t0` (ns), each arriving with a
 * uniform jitter of ±`jit_ms`; ticks drop_lo..drop_hi − 1, and those marked
 * in `lost`, are lost on the way. The engine hears frame f at CLOCK0 +
 * f/RATE. */
typedef struct {
    double t0, period_ns, jit_ms;
    int64_t k;          /* the next tick */
    double next_ns;     /* its nominal time */
    double change_ns;   /* from here at `bpm2` */
    double period2_ns;
    int64_t drop_lo, drop_hi;
    bool lost[1 << 14];
    double nominal[1 << 14]; /* nominal arrival of tick k */
} master_t;

static int64_t heard_ns(int64_t frame) { return CLOCK0 + frame * 1000000000LL / RATE; }

static double ns_frame(double ns) { return (ns - (double)CLOCK0) * RATE / 1e9; }

static void master_init(master_t *m, double t0, double bpm, double jit_ms) {
    m->t0 = t0;
    m->period_ns = 60e9 / (bpm * 24.0);
    m->period2_ns = m->period_ns;
    m->change_ns = INFINITY;
    m->jit_ms = jit_ms;
    m->k = 0;
    m->next_ns = t0;
    m->drop_lo = m->drop_hi = -1;
    memset(m->lost, 0, sizeof(m->lost));
}

/* Render one burst; before it, every tick that has arrived by the time the
 * callback runs (when frame e->frame − LAT is heard). */
static void follow_block(sp_engine *e, master_t *m) {
    double now = (double)heard_ns(e->frame - LAT);
    while (m->next_ns <= now) {
        if (m->k < (1 << 14)) m->nominal[m->k] = m->next_ns;
        if ((m->k < m->drop_lo || m->k >= m->drop_hi) && !(m->k < (1 << 14) && m->lost[m->k]))
            midi(e, 0xF8, 0, 0, (int64_t)(m->next_ns + m->jit_ms * 1e6 * unit()));
        m->k++;
        m->next_ns += m->next_ns >= m->change_ns ? m->period2_ns : m->period_ns;
    }
    sp_render(e, scratch, BLOCK);
    collect(e);
}

static void test_follow(void) {
    printf("clock follow\n");
    const double jitters[] = {0.0, 1.0, 2.0};
    for (size_t ji = 0; ji < sizeof(jitters) / sizeof(jitters[0]); ji++) {
        sp_engine *e = new_engine();
        sp_set_clock(e, 0, CLOCK0);
        set_map(e, map_new(0, 1, SP_CLOCK_FOLLOW));
        cmd(e, SP_CMD_TEMPO, 90); /* the kit's tempo: not what is followed */
        static master_t m;
        master_init(&m, (double)heard_ns(LAT + BLOCK), 123.0, jitters[ji]);
        reset_log();
        for (int i = 0; i < 200; i++) follow_block(e, &m); /* 1 s of clock before Start */
        const sp_event *tempo = NULL;
        for (int i = 0; i < n_evs; i++)
            if (evs[i].type == SP_EV_TEMPO) tempo = &evs[i];
        CHECK(tempo && fabs(tempo->a / 1000.0 - 123.0) < 0.3, "jitter ±%.0f ms: tempo while stopped %.2f bpm (123)",
              jitters[ji], tempo ? tempo->a / 1000.0 : 0);

        /* Start: the tick after it is step 0. */
        midi(e, 0xFA, 0, 0, (int64_t)m.next_ns - 100000);
        int64_t k_start = m.k;
        reset_log();
        for (int i = 0; i < 2000; i++) follow_block(e, &m); /* 10 s */

        /* Each step should be heard when the master's tick 6·s after Start
         * arrives (its nominal time). */
        double err_ms[1024];
        int n = 0, steps = 0;
        int64_t prev_frame = -1;
        int last_step = -1;
        bool every = true;
        for (int i = 0; i < n_evs && n < 1024; i++) {
            if (evs[i].type != SP_EV_PLAYHEAD) continue;
            if (last_step >= 0 && evs[i].a != (last_step + 1) % 16) every = false;
            last_step = evs[i].a;
            int64_t k = k_start + 6 * (int64_t)steps;
            if (k < m.k) err_ms[n++] = ((double)evs[i].frame - ns_frame(m.nominal[k])) * 1000.0 / RATE;
            if (prev_frame >= 0 && evs[i].frame <= prev_frame) every = false;
            prev_frame = evs[i].frame;
            steps++;
        }
        /* Lock: from the step after which every error stays within the
         * bound (half the input jitter plus half a millisecond). */
        double bound = 0.5 + 0.5 * jitters[ji];
        int locked = n;
        for (int i = n - 1; i >= 0 && fabs(err_ms[i]) <= bound; i--) locked = i;
        double sum = 0, sq = 0, worst = 0;
        int count = 0;
        for (int i = locked; i < n; i++) {
            sum += err_ms[i];
            sq += err_ms[i] * err_ms[i];
            if (fabs(err_ms[i]) > worst) worst = fabs(err_ms[i]);
            count++;
        }
        double mean = count ? sum / count : 0, rms = count ? sqrt(sq / count) : 0;
        CHECK(every && n > 70, "  %d steps in order, none twice or skipped", n);
        CHECK(err_ms[0] > 0 && err_ms[0] < (LAT + 2 * BLOCK) * 1000.0 / RATE,
              "  the downbeat sounds late by the write-ahead: %.1f ms (≤ %.1f)", err_ms[0],
              (LAT + 2 * BLOCK) * 1000.0 / RATE);
        CHECK(locked <= 8, "  locked within %.1f ms from step %d (%.2f s after Start)", bound, locked,
              locked * 60.0 / 123.0 / 4);
        CHECK(fabs(mean) < 0.25 && worst <= bound,
              "  after lock: error mean %+.3f ms, rms %.3f ms, worst %.3f ms (over %d steps)", mean, rms, worst, count);
        free_engine(e);
    }

    /* Tempo changes, small (under the jitter's reach) and large: every step
     * from a second after the change against its tick. */
    const double changes[][2] = {{120, 121.5}, {140, 100}, {90, 92}};
    for (size_t ci = 0; ci < sizeof(changes) / sizeof(changes[0]); ci++) {
        sp_engine *e = new_engine();
        sp_set_clock(e, 0, CLOCK0);
        set_map(e, map_new(0, 1, SP_CLOCK_FOLLOW));
        static master_t m;
        master_init(&m, (double)heard_ns(LAT + BLOCK), changes[ci][0], 1.0);
        for (int i = 0; i < 200; i++) follow_block(e, &m);
        midi(e, 0xFA, 0, 0, (int64_t)m.next_ns - 100000);
        int64_t k_start = m.k;
        reset_log();
        for (int i = 0; i < 400; i++) follow_block(e, &m);
        m.change_ns = m.next_ns;
        m.period2_ns = 60e9 / (changes[ci][1] * 24.0);
        for (int i = 0; i < 1200; i++) follow_block(e, &m);
        double worst = 0;
        int after = 0, steps = 0;
        for (int i = 0; i < n_evs; i++) {
            if (evs[i].type != SP_EV_PLAYHEAD) continue;
            int64_t k = k_start + 6 * (int64_t)steps++;
            if (k >= m.k || m.nominal[k] < m.change_ns + 1e9) continue;
            double err = fabs((double)evs[i].frame - ns_frame(m.nominal[k])) * 1000.0 / RATE;
            if (err > worst) worst = err;
            after++;
        }
        CHECK(after > 20 && worst < 1.0, "%g → %g bpm (jitter ±1 ms): %d steps from 1 s after the change, worst %.3f ms",
              changes[ci][0], changes[ci][1], after, worst);
        free_engine(e);
    }

    /* A tempo change, Stop, Continue from a song position, a gap. */
    sp_engine *e = new_engine();
    sp_set_clock(e, 0, CLOCK0);
    set_map(e, map_new(0, 1, SP_CLOCK_FOLLOW));
    static master_t m;
    master_init(&m, (double)heard_ns(LAT + BLOCK), 100.0, 1.0);
    for (int i = 0; i < 200; i++) follow_block(e, &m);
    midi(e, 0xFA, 0, 0, (int64_t)m.next_ns - 100000);
    int64_t k_start = m.k;
    reset_log();
    for (int i = 0; i < 400; i++) follow_block(e, &m);
    m.change_ns = m.next_ns;
    m.period2_ns = 60e9 / (130.0 * 24.0);
    for (int i = 0; i < 1200; i++) follow_block(e, &m);
    /* Every step against its tick, from a second after the change. */
    double worst = 0;
    int after = 0, steps = 0;
    for (int i = 0; i < n_evs; i++) {
        if (evs[i].type != SP_EV_PLAYHEAD) continue;
        int64_t k = k_start + 6 * (int64_t)steps++;
        if (k >= m.k || m.nominal[k] < m.change_ns + 1e9) continue;
        double err = fabs((double)evs[i].frame - ns_frame(m.nominal[k])) * 1000.0 / RATE;
        if (err > worst) worst = err;
        after++;
    }
    const sp_event *tempo = NULL;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_TEMPO) tempo = &evs[i];
    CHECK(tempo && fabs(tempo->a / 1000.0 - 130.0) < 0.3 && after > 30 && worst < 1.0,
          "100 → 130 bpm (jitter ±1 ms): followed tempo %.2f; %d steps from 1 s after the change, worst %.3f ms off "
          "their ticks",
          tempo ? tempo->a / 1000.0 : 0, after, worst);

    reset_log();
    midi(e, 0xFC, 0, 0, (int64_t)m.next_ns);
    for (int i = 0; i < 4; i++) follow_block(e, &m);
    const sp_event *tr = NULL;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_TRANSPORT) tr = &evs[i];
    CHECK(tr && tr->a == 0 && !e->seq.playing, "Stop stops the sequencer (a transport event)");
    int heads = 0;
    for (int i = 0; i < 100; i++) follow_block(e, &m);
    for (int i = 0; i < n_evs; i++) heads += evs[i].type == SP_EV_PLAYHEAD;
    CHECK(heads == 0, "  and the clock running on doesn't move it");

    /* Song position 8 (two beats), Continue: the next tick is step 8. */
    reset_log();
    midi(e, 0xF2, 8, 0, (int64_t)m.next_ns);
    midi(e, 0xFB, 0, 0, (int64_t)m.next_ns);
    int64_t k_cont = m.k;
    for (int i = 0; i < 200; i++) follow_block(e, &m);
    const sp_event *first = NULL;
    for (int i = 0; i < n_evs && !first; i++)
        if (evs[i].type == SP_EV_PLAYHEAD) first = &evs[i];
    double first_err = first ? ((double)first->frame - ns_frame(m.nominal[k_cont])) * 1000.0 / RATE : 0;
    CHECK(first && first->a == 8, "song position 8 + Continue: the first step is step %d (8), %.1f ms after its tick",
          first ? first->a : -1, first_err);

    /* Start while playing restarts from step 0. */
    reset_log();
    midi(e, 0xFA, 0, 0, (int64_t)m.next_ns);
    for (int i = 0; i < 20; i++) follow_block(e, &m);
    first = NULL;
    for (int i = 0; i < n_evs && !first; i++)
        if (evs[i].type == SP_EV_PLAYHEAD) first = &evs[i];
    CHECK(first && first->a == 0, "Start while playing restarts at step 0");

    /* A gap of a second in the clock: the fit starts over, no step jumps back. */
    m.next_ns += 1e9;
    reset_log();
    for (int i = 0; i < 600; i++) follow_block(e, &m);
    int64_t prev = -1;
    bool forward = true;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_PLAYHEAD) {
            if (evs[i].frame <= prev) forward = false;
            prev = evs[i].frame;
        }
    tempo = NULL;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_TEMPO) tempo = &evs[i];
    CHECK(forward && tempo && fabs(tempo->a / 1000.0 - 130.0) < 0.3,
          "a 1 s gap: steps keep moving forward and the tempo comes back to %.2f", tempo ? tempo->a / 1000.0 : 0);

    /* Back to internal: the kit's tempo again. */
    cmd(e, SP_CMD_TEMPO, 90);
    set_map(e, map_new(0, 1, SP_CLOCK_INTERNAL));
    for (int i = 0; i < 2; i++) follow_block(e, &m);
    CHECK(fabs(e->seq.tpf - sp_tpf(90, RATE)) < 1e-12, "leaving follow: the sequencer goes at the kit's 90 bpm");
    free_engine(e);

    /* In internal mode an incoming clock does nothing. */
    e = new_engine();
    sp_set_clock(e, 0, CLOCK0);
    set_map(e, map_new(0, 1, SP_CLOCK_INTERNAL));
    master_init(&m, (double)heard_ns(LAT + BLOCK), 100.0, 0);
    midi(e, 0xFA, 0, 0, (int64_t)m.next_ns);
    reset_log();
    for (int i = 0; i < 200; i++) follow_block(e, &m);
    CHECK(!e->seq.playing && n_evs == 0, "internal clock: Start and ticks are ignored");
    free_engine(e);
}

/* ── Clock follow: lost ticks, a dropout, a halved tempo ─────────────────── */

/* Following a master at `bpm` (jitter ±1 ms): 1 s of clock, Start, 2 s. */
static sp_engine *follow_run(master_t *m, double bpm, int64_t *k_start) {
    sp_engine *e = new_engine();
    sp_set_clock(e, 0, CLOCK0);
    set_map(e, map_new(0, 1, SP_CLOCK_FOLLOW));
    master_init(m, (double)heard_ns(LAT + BLOCK), bpm, 1.0);
    for (int i = 0; i < 200; i++) follow_block(e, m);
    midi(e, 0xFA, 0, 0, (int64_t)m->next_ns - 100000);
    *k_start = m->k;
    reset_log();
    for (int i = 0; i < 400; i++) follow_block(e, m);
    return e;
}

/* Every step whose tick is due from `from_ns` on, against that tick (lost
 * or not): the worst error in ms, and how many steps. */
static double worst_from(const master_t *m, int64_t k_start, double from_ns, int *count) {
    double worst = 0;
    int after = 0, steps = 0;
    for (int i = 0; i < n_evs; i++) {
        if (evs[i].type != SP_EV_PLAYHEAD) continue;
        int64_t k = k_start + 6 * (int64_t)steps++;
        if (k >= m->k || m->nominal[k] < from_ns) continue;
        double err = fabs((double)evs[i].frame - ns_frame(m->nominal[k])) * 1000.0 / RATE;
        if (err > worst) worst = err;
        after++;
    }
    *count = after;
    return worst;
}

static void test_follow_loss(void) {
    printf("clock follow: lost ticks\n");
    static master_t m;
    int64_t k_start;
    int n;

    /* Ticks lost on the way while the master plays on: the steps stay on
     * the master's grid (one or two: renumbered when the next tick comes;
     * two seconds: numbered by the time gone by, the sequencer running on
     * at the fitted tempo meanwhile). */
    const int lost[] = {1, 2, 96};
    for (size_t li = 0; li < sizeof(lost) / sizeof(lost[0]); li++) {
        sp_engine *e = follow_run(&m, 120.0, &k_start);
        m.drop_lo = m.k + 5;
        m.drop_hi = m.drop_lo + lost[li];
        for (int i = 0; i < 1200; i++) follow_block(e, &m);
        int n_all;
        double all = worst_from(&m, k_start, m.nominal[m.drop_lo], &n_all);
        double worst = worst_from(&m, k_start, m.nominal[m.drop_hi] + 1e9, &n);
        CHECK(n_all > 40 && all < 3.0 && worst < 1.0,
              "%d tick%s lost at 120 bpm (jitter ±1 ms): worst %.3f ms over the %d steps from the loss on, %.3f ms from 1 s "
              "after the ticks are back",
              lost[li], lost[li] > 1 ? "s" : "", all, n_all, worst);
        free_engine(e);
    }

    /* The tempo halved: gaps of two ticks, more in a row than
     * SP_FOLLOW_HELD, are a tempo change, not lost ticks (the sequencer,
     * at the gaps' pace from the second, then ahead of the slower grid,
     * slows onto it: it never goes back). */
    sp_engine *e = follow_run(&m, 120.0, &k_start);
    m.change_ns = m.next_ns;
    m.period2_ns = 2 * m.period_ns;
    for (int i = 0; i < 1600; i++) follow_block(e, &m);
    double worst = worst_from(&m, k_start, m.change_ns + 2.5e9, &n);
    const sp_event *tempo = NULL;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_TEMPO) tempo = &evs[i];
    CHECK(tempo && fabs(tempo->a / 1000.0 - 60.0) < 0.3 && n > 20 && worst < 1.0,
          "120 → 60 bpm: followed tempo %.2f; %d steps from 2.5 s (2.5 beats) after the change, worst %.3f ms",
          tempo ? tempo->a / 1000.0 : 0, n, worst);
    free_engine(e);

    /* Lost ticks soon after the fit restarts, in clusters, with more
     * jitter; tempo drops to under a third. Ticks are offsets from the
     * scenario's start (the tempo change, if any). Whatever happens, the
     * ticks end numbered as the master's and the steps back on its grid. */
    static const struct {
        const char *what;
        double bpm, bpm2, jit, settle_s; /* bpm2 > 0: the master goes to it at the start */
        int run_at, run;                 /* ticks run_at .. run_at + run − 1 lost */
        int at[4];                       /* and these (0: none) */
    } cases[] = {
        {"two ticks lost two apart (gaps of 2, 2, then 1 tick)", 120, 0, 1, 4, 0, 0, {5, 7}},
        {"four lost, every other tick", 120, 0, 1, 4, 0, 0, {5, 7, 9, 11}},
        {"a 1 s dropout, then a tick lost 4 ticks after it", 120, 0, 1, 4, 5, 48, {57}},
        {"120 → 130 bpm, a tick lost 3 ticks after the change", 120, 130, 1, 4, 0, 0, {3}},
        {"120 → 130 bpm, a tick lost 8 ticks after the change", 120, 130, 1, 4, 0, 0, {8}},
        {"jitter ±2 ms: a tick lost", 120, 0, 2, 4, 0, 0, {5}},
        {"jitter ±2 ms: a 1 s dropout, then a tick lost 4 ticks after it", 120, 0, 2, 4, 5, 48, {57}},
        {"150 → 45 bpm (gaps of 3.3 ticks)", 150, 45, 1, 5, 0, 0, {0}},
        {"150 → 40 bpm (gaps of 3.75 ticks)", 150, 40, 1, 5, 0, 0, {0}},
    };
    for (size_t ci = 0; ci < sizeof(cases) / sizeof(cases[0]); ci++) {
        e = follow_run(&m, cases[ci].bpm, &k_start);
        int64_t base = m.k;
        m.jit_ms = cases[ci].jit;
        if (cases[ci].bpm2 > 0) {
            m.change_ns = m.next_ns;
            m.period2_ns = 60e9 / (cases[ci].bpm2 * 24.0);
        }
        for (int i = 0; i < cases[ci].run; i++) m.lost[base + cases[ci].run_at + i] = true;
        for (int i = 0; i < 4; i++)
            if (cases[ci].at[i] > 0) m.lost[base + cases[ci].at[i]] = true;
        for (int i = 0; i < 1600; i++) follow_block(e, &m);
        worst = worst_from(&m, k_start, m.nominal[base] + cases[ci].settle_s * 1e9, &n);
        double bound = 0.5 + 0.5 * cases[ci].jit; /* as for lock above */
        CHECK(e->midi.ticks == m.k && n > 5 && worst <= bound,
              "%s: ticks numbered as the master's (%lld / %lld), %d steps from %.0f s on, worst %.3f ms (≤ %.1f)",
              cases[ci].what, (long long)e->midi.ticks, (long long)m.k, n, cases[ci].settle_s, worst, bound);
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

int main(void) {
    test_parser();
    test_notes_in();
    test_notes_out();
    test_clock_send();
    test_follow();
    test_follow_loss();
    test_out_pairing();
    test_hits();
    printf(failures ? "FAILED: %d\n" : "passed: 0 failures\n", failures);
    return failures ? 1 : 0;
}
