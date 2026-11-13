/*
 * Host harness for c_src/sampler.c: renders offline into buffers and checks
 * the sequencer's timing to the frame, choke and voice stealing without
 * clicks, pitch, reverse, loops, gates, hits, quantized launches and the
 * resampler.
 *
 *   cc -O2 -Wall -Wextra -o /tmp/sampler_host c_src/test/sampler_host.c -lm && /tmp/sampler_host
 *   cc -g -O1 -fsanitize=address,undefined -o /tmp/sampler_host_asan c_src/test/sampler_host.c -lm && /tmp/sampler_host_asan
 *   /tmp/sampler_host bench     # render cost of 32 voices (build with -Os, as the app is)
 *
 * Exit 1 on any failure; each check prints one line. The bench also runs
 * on the phone: cross-compile with the NDK's clang, `adb push` it to
 * /data/local/tmp and run it under `taskset 1` (a little core).
 */

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

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

/* ── Engine scaffolding ───────────────────────────────────────────────────── */

static sp_sample *sp_sample_new(int64_t frames, int channels, int rate) {
    return sp_sample_wrap(malloc((size_t)(frames > 0 ? frames : 1) * (size_t)channels * sizeof(int16_t)), frames, channels,
                          rate);
}

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
    free(e);
}

typedef double (*wave_fn)(int64_t i, int c);

static sp_sample *make_sample(int64_t frames, int channels, int rate, wave_fn f) {
    sp_sample *s = sp_sample_new(frames, channels, rate);
    for (int64_t i = 0; i < frames; i++)
        for (int c = 0; c < channels; c++) {
            double x = f(i, c) * 32767.0;
            s->data[i * channels + c] = (int16_t)lrint(x > 32767 ? 32767 : x < -32768 ? -32768 : x);
        }
    return s;
}

static void push(sp_engine *e, sp_cmd c) {
    if (!sp_push(e, &c)) {
        printf("  FAIL command queue full\n");
        failures++;
    }
}

static void load(sp_engine *e, int slot, sp_sample *s) {
    push(e, (sp_cmd){.type = SP_CMD_SAMPLE, .u.sample = {slot, s}});
}

static sp_pad pad_of(int slot, int mode) {
    return (sp_pad){.slot = slot, .gain = 1.0f, .mode = (uint8_t)mode, .root = 60};
}

static void set_pad(sp_engine *e, int pad, sp_pad p) { push(e, (sp_cmd){.type = SP_CMD_PAD, .pad = (uint8_t)pad, .u.pad = p}); }

static void trigger(sp_engine *e, int pad, int vel) {
    push(e, (sp_cmd){.type = SP_CMD_TRIGGER, .pad = (uint8_t)pad, .vel = (uint8_t)vel});
}

static void cmd(sp_engine *e, int type, double value) { push(e, (sp_cmd){.type = (uint8_t)type, .u.value = value}); }

typedef struct {
    int32_t pos;
    int pad, vel, note;
} step_spec;

static uint32_t pattern_ids = 0;

static sp_pattern *pattern(int steps, const step_spec *specs, int n) {
    sp_pattern *p = sp_pattern_new(n);
    p->id = ++pattern_ids;
    p->length = steps * SP_STEP;
    for (int i = 0; i < n; i++) {
        int32_t pos = specs[i].pos % p->length;
        if (pos < 0) pos += p->length;
        p->steps[i] = (sp_step){pos, (uint8_t)specs[i].pad, (uint8_t)(specs[i].vel ? specs[i].vel : 127),
                                (int16_t)(specs[i].note ? specs[i].note : -1)};
    }
    sp_pattern_sort(p);
    return p;
}

static void set_pattern(sp_engine *e, sp_pattern *p, bool at_bar) {
    push(e, (sp_cmd){.type = SP_CMD_PATTERN, .u.pattern = {p, at_bar}});
}

/* Collected events, in order. */
static sp_event evs[1 << 16];
static int n_evs;

static void collect(sp_engine *e) {
    sp_event ev;
    while (sp_pop_event(e, &ev))
        if (n_evs < (int)(sizeof(evs) / sizeof(evs[0]))) evs[n_evs++] = ev;
    sp_garbage g;
    while (sp_pop_garbage(e, &g)) sp_free_garbage(&g);
}

/* Render `frames` into `out` (stereo) in blocks of `block` frames, or random
 * sizes 1..997 when `block` is 0. */
static void render(sp_engine *e, float *out, int64_t frames, int block) {
    int64_t done = 0;
    while (done < frames) {
        int n = block > 0 ? block : 1 + (int)(next_rand() % 997);
        if (n > frames - done) n = (int)(frames - done);
        sp_render(e, out + 2 * done, n);
        collect(e);
        done += n;
    }
}

static float *buffer(int64_t frames) { return calloc((size_t)frames * 2, sizeof(float)); }

/* Frames (relative to `out`) where the left channel goes from 0 to non-0. */
static int onsets(const float *out, int64_t frames, int64_t *at, int max, int sign) {
    int n = 0;
    float prev = 0;
    for (int64_t i = 0; i < frames; i++) {
        float x = out[2 * i];
        bool on = sign > 0 ? x > 1e-7f : sign < 0 ? x < -1e-7f : fabsf(x) > 1e-7f;
        bool was = sign > 0 ? prev > 1e-7f : sign < 0 ? prev < -1e-7f : fabsf(prev) > 1e-7f;
        if (on && !was && n < max) at[n++] = i;
        prev = x;
    }
    return n;
}

static float max_delta(const float *out, int64_t from, int64_t to) {
    float m = 0;
    for (int64_t i = from + 1; i < to; i++) {
        float d = fabsf(out[2 * i] - out[2 * (i - 1)]);
        if (d > m) m = d;
        d = fabsf(out[2 * i + 1] - out[2 * (i - 1) + 1]);
        if (d > m) m = d;
    }
    return m;
}

static float max_abs(const float *out, int64_t from, int64_t to) {
    float m = 0;
    for (int64_t i = from; i < to; i++) {
        if (fabsf(out[2 * i]) > m) m = fabsf(out[2 * i]);
        if (fabsf(out[2 * i + 1]) > m) m = fabsf(out[2 * i + 1]);
    }
    return m;
}

/* Frequency of the left channel over [from, to) from its rising zero
 * crossings (interpolated). */
static double frequency(const float *out, int64_t from, int64_t to) {
    double first = -1, last = -1;
    int n = 0;
    for (int64_t i = from + 1; i < to; i++) {
        float a = out[2 * (i - 1)], b = out[2 * i];
        if (a < 0 && b >= 0) {
            double t = (double)(i - 1) + a / (a - b);
            if (first < 0) first = t;
            last = t;
            n++;
        }
    }
    return n > 1 ? (n - 1) * (double)RATE / (last - first) : 0;
}

static int count_events(int type, int pad) {
    int n = 0;
    for (int i = 0; i < n_evs; i++) n += evs[i].type == type && (pad < 0 || evs[i].pad == pad);
    return n;
}

static const sp_event *find_event(int type, int pad) {
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == type && (pad < 0 || evs[i].pad == pad)) return &evs[i];
    return NULL;
}

/* ── Waves ────────────────────────────────────────────────────────────────── */

static double dc_half(int64_t i, int c) { (void)i; (void)c; return 0.5; }
static double dc_neg(int64_t i, int c) { (void)i; (void)c; return -0.5; }
static double zero(int64_t i, int c) { (void)i; (void)c; return 0.0; }
static double ramp(int64_t i, int c) { (void)c; return 0.8 * (double)i / 4800.0; }
static double noise(int64_t i, int c) {
    (void)c;
    unsigned h = (unsigned)i * 2654435761u;
    h ^= h >> 13;
    h *= 0x5bd1e995u;
    return ((double)(h & 0xffff) / 32768.0 - 1.0) * 0.5;
}
static double sine_freq, sine_amp, sine_rate;
static double sine(int64_t i, int c) { (void)c; return sine_amp * sin(2 * M_PI * sine_freq * (double)i / sine_rate); }

static sp_sample *sine_sample(double hz, double amp, int rate, int64_t frames) {
    sine_freq = hz;
    sine_amp = amp;
    sine_rate = rate;
    return make_sample(frames, 1, rate, sine);
}

/* ── Exact step positions ─────────────────────────────────────────────────── */

/* Frames from play to straight position `t` (ticks) at bpm = bn / bd and
 * swing p / 100: ceil of the exact rational. At 48 kHz a tick is
 * 60 · 48000 / (96 · bpm) frames, so 100 · ticks → frames is × 300 / bpm. */
static int64_t expected_frame(int64_t t, int p, int64_t bn, int64_t bd) {
    int64_t pair = t / 48, r = t % 48;
    int64_t x100 = r < 24 ? 4800 * pair + 2 * r * p : 4800 * pair + 48 * p + 2 * (r - 24) * (100 - p);
    int64_t num = x100 * 300 * bd;
    return (num + bn - 1) / bn;
}

/* ── Tests ────────────────────────────────────────────────────────────────── */

static void test_step_timing(void) {
    printf("step timing (onsets and playhead, random blocks)\n");
    const int64_t tempos[][2] = {{40, 1}, {97, 1}, {120, 1}, {267, 2}, {240, 1}};
    const int swings[] = {50, 54, 66, 75};
    for (size_t ti = 0; ti < sizeof(tempos) / sizeof(tempos[0]); ti++) {
        for (size_t si = 0; si < sizeof(swings) / sizeof(swings[0]); si++) {
            int64_t bn = tempos[ti][0], bd = tempos[ti][1];
            int p = swings[si];
            sp_engine *e = new_engine();
            n_evs = 0;
            load(e, 0, make_sample(64, 1, RATE, dc_half));
            set_pad(e, 0, pad_of(0, SP_ONE_SHOT));
            step_spec specs[16];
            for (int i = 0; i < 16; i++) specs[i] = (step_spec){.pos = i * 24, .pad = 0};
            set_pattern(e, pattern(16, specs, 16), false);
            cmd(e, SP_CMD_TEMPO, (double)bn / bd);
            cmd(e, SP_CMD_SWING, p / 100.0);
            int64_t lead = 777; /* play starts mid-stream */
            float *pre = buffer(lead);
            render(e, pre, lead, 0);
            cmd(e, SP_CMD_PLAY, 0);
            int64_t bars = 3, frames = expected_frame(bars * 384, p, bn, bd) + 10;
            float *out = buffer(frames);
            render(e, out, frames, 0);

            int64_t at[64];
            int n = onsets(out, frames, at, 64, 1);
            /* Three bars, plus step 0 of the fourth (inside the +10 frames). */
            int bad = n == 49 ? 0 : 1;
            for (int i = 0; i < n && i < 49; i++)
                if (at[i] != expected_frame(i * 24, p, bn, bd)) bad++;
            int heads = 0, bad_heads = 0;
            for (int i = 0; i < n_evs; i++) {
                if (evs[i].type != SP_EV_PLAYHEAD) continue;
                int64_t want = lead + expected_frame(heads * 24, p, bn, bd);
                if (evs[i].frame != want || evs[i].a != heads % 16) bad_heads++;
                heads++;
            }
            CHECK(bad == 0 && heads == 49 && bad_heads == 0,
                  "%6.1f bpm swing %.2f: %d onsets, %d off; %d playhead events, %d off", (double)bn / bd, p / 100.0, n,
                  bad, heads, bad_heads);
            free(pre);
            free(out);
            free_engine(e);
        }
    }

    /* Off-grid ticks, including negative ones (step 0, tick −12 plays at the
     * end of the pattern). */
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(64, 1, RATE, dc_half));
    set_pad(e, 0, pad_of(0, SP_ONE_SHOT));
    step_spec specs[] = {{.pos = 0 * 24 + 5}, {.pos = 3 * 24 - 7}, {.pos = 9 * 24 + 12}, {.pos = 0 * 24 - 12}, {.pos = 6 * 24 + 1}};
    set_pattern(e, pattern(16, specs, 5), false);
    cmd(e, SP_CMD_TEMPO, 113);
    cmd(e, SP_CMD_SWING, 0.62);
    cmd(e, SP_CMD_PLAY, 0);
    int64_t frames = expected_frame(2 * 384, 62, 113, 1);
    float *out = buffer(frames);
    render(e, out, frames, 0);
    int64_t at[16];
    int n = onsets(out, frames, at, 16, 1);
    int32_t want_pos[] = {5, 65, 144 + 1, 216 + 12, 372, 384 + 5, 384 + 65, 384 + 145, 384 + 228, 384 + 372};
    int bad = n == 10 ? 0 : 1;
    for (int i = 0; i < n && i < 10; i++)
        if (at[i] != expected_frame(want_pos[i], 62, 113, 1)) bad++;
    CHECK(bad == 0, "off-grid and negative ticks at 113 bpm swing 0.62: %d onsets, %d off", n, bad);
    free(out);
    free_engine(e);
}

static void test_block_independence(void) {
    printf("block independence\n");
    float *a = NULL, *b = NULL;
    const int64_t frames = 3 * RATE;
    for (int run = 0; run < 2; run++) {
        sp_engine *e = new_engine();
        n_evs = 0;
        load(e, 0, make_sample(4800, 1, RATE, noise));
        load(e, 1, sine_sample(330, 0.3, 44100, 30000));
        sp_pad p0 = pad_of(0, SP_ONE_SHOT);
        p0.pitch = 3.3f;
        p0.choke = 1;
        set_pad(e, 0, p0);
        sp_pad p1 = pad_of(1, SP_LOOP);
        p1.reverse = true;
        p1.choke = 1;
        set_pad(e, 1, p1);
        step_spec specs[] = {{.pos = 0, .pad = 0}, {.pos = 30, .pad = 1}, {.pos = 100, .pad = 0, .vel = 60},
                             {.pos = 200, .pad = 1}, {.pos = 290, .pad = 0}};
        set_pattern(e, pattern(16, specs, 5), false);
        cmd(e, SP_CMD_TEMPO, 133);
        cmd(e, SP_CMD_SWING, 0.58);
        cmd(e, SP_CMD_PLAY, 0);
        float *out = buffer(frames);
        render(e, out, frames, run == 0 ? 64 : 0);
        if (run == 0) a = out;
        else b = out;
        free_engine(e);
    }
    float diff = 0;
    for (int64_t i = 0; i < 2 * frames; i++)
        if (fabsf(a[i] - b[i]) > diff) diff = fabsf(a[i] - b[i]);
    CHECK(diff == 0.0f && max_abs(a, 0, frames) > 0.1f, "64-frame blocks vs random blocks: max difference %g", diff);
    free(a);
    free(b);
}

static void test_tempo_change(void) {
    printf("tempo change while playing\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(64, 1, RATE, dc_half));
    set_pad(e, 0, pad_of(0, SP_ONE_SHOT));
    step_spec specs[16];
    for (int i = 0; i < 16; i++) specs[i] = (step_spec){.pos = i * 24};
    set_pattern(e, pattern(16, specs, 16), false);
    cmd(e, SP_CMD_TEMPO, 120);
    cmd(e, SP_CMD_PLAY, 0);
    int64_t first = 15000; /* 2.5 steps at 120 bpm (6000 frames each) */
    float *out = buffer(100000);
    render(e, out, first, 0);
    cmd(e, SP_CMD_TEMPO, 90);
    render(e, out + 2 * first, 100000 - first, 0);
    int64_t at[32];
    int n = onsets(out, 100000, at, 32, 1);
    /* 120 bpm up to frame 15000 (position 60 ticks), then 90 bpm: a tick is
     * 1/0.003 frames. Step 3 (72 ticks) at 15000 + 12 / 0.003 = 19000. */
    int64_t want[] = {0, 6000, 12000, 19000, 27000, 35000, 43000, 51000, 59000, 67000, 75000, 83000, 91000, 99000};
    int bad = n == 14 ? 0 : 1;
    for (int i = 0; i < n && i < 14; i++)
        if (at[i] != want[i]) bad++;
    CHECK(bad == 0, "120 → 90 bpm mid-step: %d onsets, %d off, nothing doubled or skipped", n, bad);
    free(out);
    free_engine(e);
}

static void test_pattern_swap(void) {
    printf("pattern swap\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(64, 1, RATE, dc_half));
    load(e, 1, make_sample(64, 1, RATE, dc_neg));
    set_pad(e, 0, pad_of(0, SP_ONE_SHOT));
    set_pad(e, 1, pad_of(1, SP_ONE_SHOT));
    step_spec a[] = {{.pos = 0}, {.pos = 96}, {.pos = 192}, {.pos = 288}};
    sp_pattern *pa = pattern(16, a, 4);
    set_pattern(e, pa, true); /* not playing: applies at once */
    cmd(e, SP_CMD_TEMPO, 120);
    cmd(e, SP_CMD_PLAY, 0);
    int64_t bar = 96000, frames = 3 * bar;
    float *out = buffer(frames);
    render(e, out, 30000, 0);
    step_spec b[] = {{.pos = 0, .pad = 1}, {.pos = 48, .pad = 1}};
    sp_pattern *pb = pattern(16, b, 2);
    set_pattern(e, pb, true);
    render(e, out + 2 * 30000, frames - 30000, 0);

    int64_t pos[16], neg[16];
    int np = onsets(out, frames, pos, 16, 1), nn = onsets(out, frames, neg, 16, -1);
    bool ok_a = np == 4 && pos[0] == 0 && pos[1] == 24000 && pos[2] == 48000 && pos[3] == 72000;
    bool ok_b = nn == 4 && neg[0] == bar && neg[1] == bar + 12000 && neg[2] == 2 * bar && neg[3] == 2 * bar + 12000;
    const sp_event *swap = NULL;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_PATTERN && evs[i].a == (int32_t)pb->id) swap = &evs[i];
    CHECK(ok_a && ok_b, "queued at frame 30000, B starts on bar 2: A onsets %d, B onsets %d (first %lld)", np, nn,
          nn ? (long long)neg[0] : -1LL);
    CHECK(swap && swap->frame == bar, "pattern event at the bar: frame %lld", swap ? (long long)swap->frame : -1LL);
    int heads_after = 0, first_head = -1;
    for (int i = 0; i < n_evs; i++)
        if (evs[i].type == SP_EV_PLAYHEAD && evs[i].frame == bar) {
            heads_after++;
            first_head = evs[i].a;
        }
    CHECK(heads_after == 1 && first_head == 0, "playhead at the bar is step %d", first_head);

    /* An edit applied now keeps the position: B' replaces B mid-bar 3 and
     * its step 12 still sounds in this bar. */
    n_evs = 0;
    step_spec c[] = {{.pos = 12 * 24, .pad = 0}};
    set_pattern(e, pattern(16, c, 1), false);
    float *more = buffer(bar);
    render(e, more, bar, 0); /* frames 3·bar .. 4·bar: position 1152.. → step 12 of cycle at 4·bar − 24000 */
    int64_t at[4];
    int n = onsets(more, bar, at, 4, 1);
    CHECK(n == 1 && at[0] == bar - 24000, "edit now: step 12 sounds this bar at %lld", n ? (long long)at[0] : -1LL);
    free(more);
    free(out);
    free_engine(e);
}

static void test_choke(void) {
    printf("choke\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, sine_sample(220, 0.9, RATE, RATE));
    load(e, 1, make_sample(4800, 1, RATE, zero));
    sp_pad open = pad_of(0, SP_LOOP);
    open.choke = 1;
    sp_pad closed = pad_of(1, SP_ONE_SHOT);
    closed.choke = 1;
    set_pad(e, 0, open);
    set_pad(e, 1, closed);
    trigger(e, 0, 127);
    int64_t cut = 4855; /* the sine near its peak */
    float *out = buffer(cut + 9600);
    render(e, out, cut, 0);
    float before = fabsf(out[2 * (cut - 1)]);
    trigger(e, 1, 127);
    render(e, out + 2 * cut, 9600, 0);
    float natural = (float)(0.9 * 2 * M_PI * 220 / RATE);
    float d = max_delta(out, 100, cut + 9600);
    float tail = max_abs(out, cut + 192 + 1, cut + 9600);
    CHECK(before > 0.8f, "level when choked: %.3f", before);
    CHECK(d < natural + 0.006f, "max step %.4f (the sine alone %.4f; a hard cut would be %.2f)", d, natural, before);
    CHECK(tail == 0.0f && count_events(SP_EV_VOICE_END, 0) == 1, "silent 4 ms after the choke, voice end sent");
    free(out);
    free_engine(e);
}

static void test_steal(void) {
    printf("voice stealing\n");
    for (int scenario = 0; scenario < 2; scenario++) {
        sp_engine *e = new_engine();
        n_evs = 0;
        for (int i = 0; i <= SP_POLY; i++) {
            load(e, i, sine_sample(50 + i, 0.025, RATE, RATE));
            set_pad(e, i, pad_of(i, SP_LOOP));
        }
        /* Scenario 0: all equal, the oldest (pad 0) goes. Scenario 1: pad 7
         * plays quietest and goes. */
        for (int i = 0; i < SP_POLY; i++) trigger(e, i, scenario == 1 && i == 7 ? 90 : 127);
        int64_t at = 9600;
        float *out = buffer(at + 9600);
        render(e, out, at, 0);
        float natural = max_delta(out, 200, at);
        trigger(e, SP_POLY, 127);
        render(e, out + 2 * at, 9600, 0);
        float d = max_delta(out, at - 200, at + 9600);
        int victim = scenario == 0 ? 0 : 7;
        CHECK(count_on(e) == SP_POLY && count_events(SP_EV_VOICE_END, victim) == 1 && count_events(SP_EV_VOICE_END, -1) == 1,
              "33rd voice: %d sounding, pad %d stolen", count_on(e), victim);
        CHECK(d < natural + 0.0015f, "max step across the steal %.5f (before %.5f; a hard cut %.3f)", d, natural,
              scenario == 0 ? 0.025 : 0.025 * (90.0 / 127) * (90.0 / 127));
        free(out);
        free_engine(e);
    }

    /* More starts in one block than there are slots: fading voices are cut
     * (quietest first), nothing crashes, the count stays bounded. */
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(48000, 1, RATE, noise));
    set_pad(e, 0, pad_of(0, SP_ONE_SHOT));
    for (int i = 0; i < 80; i++) trigger(e, 0, 100);
    float *out = buffer(4800);
    render(e, out, 4800, 256);
    CHECK(atomic_load(&e->voices_active) <= SP_VOICES && atomic_load(&e->hard_cuts) > 0 &&
              count_on(e) == SP_POLY,
          "80 starts at once: %d sounding, %d active, %llu hard cuts", count_on(e), atomic_load(&e->voices_active),
          (unsigned long long)atomic_load(&e->hard_cuts));
    free(out);
    free_engine(e);
}

static void test_pitch(void) {
    printf("pitch\n");
    struct {
        float semis;
        int mode, note;
        int sample_rate;
        double want;
    } cases[] = {
        {0, SP_ONE_SHOT, 0, RATE, 1000.0},       {12, SP_ONE_SHOT, 0, RATE, 2000.0},
        {7, SP_ONE_SHOT, 0, RATE, 1498.307},     {-12, SP_ONE_SHOT, 0, RATE, 500.0},
        {-5.5f, SP_ONE_SHOT, 0, RATE, 727.958},  {0, SP_KEYS, 63, RATE, 1189.207},
        {2, SP_KEYS, 55, RATE, 840.896},         {0, SP_ONE_SHOT, 0, 44100, 1000.0},
        {12, SP_ONE_SHOT, 0, 22050, 2000.0},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        sp_engine *e = new_engine();
        n_evs = 0;
        load(e, 0, sine_sample(1000, 0.5, cases[i].sample_rate, cases[i].sample_rate * 2));
        sp_pad p = pad_of(0, cases[i].mode);
        p.pitch = cases[i].semis;
        set_pad(e, 0, p);
        if (cases[i].mode == SP_KEYS)
            push(e, (sp_cmd){.type = SP_CMD_NOTE_ON, .pad = 0, .note = (uint8_t)cases[i].note, .vel = 127});
        else
            trigger(e, 0, 127);
        float *out = buffer(RATE / 2);
        render(e, out, RATE / 2, 0);
        double f = frequency(out, 1000, RATE / 2);
        double cents = 1200 * log2(f / cases[i].want);
        CHECK(fabs(cents) < 0.5, "%+5.1f st%s%s (sample at %d Hz): %.2f Hz, want %.2f (%+.3f ¢)", cases[i].semis,
              cases[i].mode == SP_KEYS ? " keys note " : "", cases[i].mode == SP_KEYS ? (cases[i].note == 63 ? "63" : "55") : "",
              cases[i].sample_rate, f, cases[i].want, cents);
        free(out);
        free_engine(e);
    }
}

static void test_reverse(void) {
    printf("reverse\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    sp_sample *s = make_sample(4800, 1, RATE, ramp);
    load(e, 0, s);
    sp_pad p = pad_of(0, SP_ONE_SHOT);
    p.start = 1000;
    p.end = 3000;
    p.reverse = true;
    set_pad(e, 0, p);
    trigger(e, 0, 127);
    float *out = buffer(4000);
    render(e, out, 4000, 0);
    float worst = 0;
    for (int k = 24; k < 1900; k++) {
        float want = s->data[2999 - k] / 32768.0f;
        if (fabsf(out[2 * k] - want) > worst) worst = fabsf(out[2 * k] - want);
    }
    CHECK(worst < 1e-5f && max_abs(out, 2000, 4000) == 0.0f,
          "region 1000..3000 played backwards: max error %.2g, silent after", worst);
    free(out);
    free_engine(e);
}

static void test_loop_and_release(void) {
    printf("loop, gate, one-shot, toggle\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(4800, 2, RATE, noise));
    sp_pad p = pad_of(0, SP_LOOP);
    p.start = 100;
    p.end = 580;
    set_pad(e, 0, p);
    trigger(e, 0, 127);
    float *out = buffer(20000);
    render(e, out, 10000, 0);
    float worst = 0;
    for (int64_t i = 50; i < 9000; i++)
        if (fabsf(out[2 * i] - out[2 * (i + 480)]) > worst) worst = fabsf(out[2 * i] - out[2 * (i + 480)]);
    CHECK(worst < 1e-6f && max_abs(out, 9000, 10000) > 0.1f, "loop repeats every 480 frames (max diff %.2g)", worst);
    push(e, (sp_cmd){.type = SP_CMD_RELEASE, .pad = 0});
    render(e, out + 2 * 10000, 10000, 0);
    CHECK(max_abs(out, 10000 + 240 + 1, 20000) == 0.0f && count_events(SP_EV_VOICE_END, 0) == 1,
          "release: silent after 5 ms, voice end sent");
    free_engine(e);

    /* Gate stops on release; one-shot doesn't. */
    for (int mode = SP_ONE_SHOT; mode <= SP_GATE; mode++) {
        e = new_engine();
        n_evs = 0;
        load(e, 0, make_sample(48000, 1, RATE, dc_half));
        set_pad(e, 0, pad_of(0, mode));
        trigger(e, 0, 127);
        render(e, out, 4800, 0);
        push(e, (sp_cmd){.type = SP_CMD_RELEASE, .pad = 0});
        render(e, out, 4800, 0);
        float level = max_abs(out, 4000, 4800);
        CHECK(mode == SP_GATE ? level == 0.0f : level > 0.49f, "%s after release: level %.3f",
              mode == SP_GATE ? "gate" : "one-shot", level);
        free_engine(e);
    }

    /* Toggle: first trigger loops, the second stops it. */
    e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(4800, 1, RATE, dc_half));
    set_pad(e, 0, pad_of(0, SP_TOGGLE));
    trigger(e, 0, 127);
    render(e, out, 19200, 0);
    float on = max_abs(out, 18000, 19200);
    push(e, (sp_cmd){.type = SP_CMD_RELEASE, .pad = 0}); /* ignored */
    trigger(e, 0, 127);
    render(e, out, 4800, 0);
    CHECK(on > 0.49f && max_abs(out, 1000, 4800) == 0.0f && count_events(SP_EV_VOICE_END, 0) == 1,
          "toggle: loops past the sample's end (%.2f), off on the next trigger", on);
    free_engine(e);

    /* Keys: note-off releases only its note. */
    e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(48000, 1, RATE, dc_half));
    set_pad(e, 0, pad_of(0, SP_KEYS));
    push(e, (sp_cmd){.type = SP_CMD_NOTE_ON, .pad = 0, .note = 60, .vel = 127});
    push(e, (sp_cmd){.type = SP_CMD_NOTE_ON, .pad = 0, .note = 67, .vel = 127});
    render(e, out, 2000, 0);
    push(e, (sp_cmd){.type = SP_CMD_NOTE_OFF, .pad = 0, .note = 60});
    render(e, out, 4800, 0);
    CHECK(count_on(e) == 1 && e->voices[1].note == 67, "keys: note-off 60 leaves 67 sounding");
    free_engine(e);
    free(out);
}

static void test_fades_and_gain(void) {
    printf("velocity, gain, fades\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(48000, 1, RATE, dc_half));
    sp_pad p = pad_of(0, SP_ONE_SHOT);
    p.gain = sp_db_to_gain(-6);
    p.fade_in_ms = 10;
    p.fade_out_ms = 20;
    set_pad(e, 0, p);
    trigger(e, 0, 64);
    float *out = buffer(48000);
    render(e, out, 48000, 0);
    float want = 0.5f * (64.0f / 127) * (64.0f / 127) * sp_db_to_gain(-6);
    float mid = out[2 * 24000];
    float at_fade = out[2 * 239]; /* frame 239 of a 480-frame fade in: 240/480 */
    float at_end = out[2 * (48000 - 480)]; /* 480 of the 960-frame fade out left */
    CHECK(fabsf(mid - want) < 1e-4f, "v64, −6 dB: level %.5f, want %.5f", mid, want);
    CHECK(fabsf(at_fade - want * 0.5f) < 1e-4f && fabsf(at_end - want * 0.5f) < 1e-4f,
          "10 ms fade in and 20 ms fade out are linear (midpoints %.5f, %.5f)", at_fade, at_end);
    free(out);
    free_engine(e);
}

static void test_hits(void) {
    printf("hits (stamped where they were heard)\n");
    struct {
        double swing;
        int64_t heard; /* frames after play */
        int step, tick;
    } cases[] = {
        {0.5, 3 * 6000 + 2400, 3, 10},      /* 9.6 ticks after step 3 */
        {0.5, 5 * 6000 - 1750, 5, -7},      /* 7 ticks before step 5 */
        {0.5, 15 * 6000 + 5900, 0, 0},      /* just before the loop point: step 0 of the next pass */
        {0.66, 6000 + 0.16 * 48 / 0.004, 1, 0}, /* on the swung step 1 */
        {0.75, 6000 + 12 / 0.004 + 1000, 1, 8}, /* 4 swung ticks after step 1: the pair's second half runs at half speed */
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        sp_engine *e = new_engine();
        n_evs = 0;
        load(e, 0, make_sample(64, 1, RATE, dc_half));
        set_pad(e, 0, pad_of(0, SP_ONE_SHOT));
        cmd(e, SP_CMD_SWING, cases[i].swing);
        int64_t play_at = 3000;
        float *out = buffer(120000);
        render(e, out, play_at, 0);
        cmd(e, SP_CMD_PLAY, 0);
        /* Frame f is heard at f / RATE seconds. */
        sp_set_clock(e, 0, 0);
        render(e, out, 100000, 0);
        int64_t heard = play_at + cases[i].heard;
        push(e, (sp_cmd){.type = SP_CMD_TRIGGER, .pad = 0, .vel = 99, .t_ns = (int64_t)((double)heard * 1e9 / RATE)});
        render(e, out, 256, 0);
        const sp_event *h = find_event(SP_EV_HIT, 0);
        CHECK(h && h->a == cases[i].step && h->b == cases[i].tick && h->vel == 99,
              "swing %.2f, heard %lld frames in: step %d tick %d (want %d, %d)", cases[i].swing,
              (long long)cases[i].heard, h ? h->a : -1, h ? h->b : 99, cases[i].step, cases[i].tick);
        free(out);
        free_engine(e);
    }
}

static void test_quantize_and_gate_steps(void) {
    printf("quantized launch, sequenced gate\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(96000, 1, RATE, dc_half));
    set_pad(e, 0, pad_of(0, SP_TOGGLE));
    cmd(e, SP_CMD_PLAY, 0);
    float *out = buffer(60000);
    render(e, out, 13000, 0);
    push(e, (sp_cmd){.type = SP_CMD_TRIGGER, .pad = 0, .vel = 127, .quantize = 96});
    render(e, out, 30000, 0);
    int64_t at[2];
    int n = onsets(out, 30000, at, 2, 1);
    CHECK(n == 1 && at[0] == 24000 - 13000, "launch quantized to the next beat: frame %lld (want 24000)",
          n ? (long long)at[0] + 13000 : -1LL);
    free_engine(e);

    /* Sequenced gate pads sound until the next step starts: straight, with
     * swing (step 0 is 36 ticks long at 0.75), across a tempo change, and
     * stopping the sequencer ends them. */
    struct {
        const char *label;
        int mode;
        double swing;
        int64_t change_at; /* frame of a tempo change to 60 bpm, or of a stop; 0 none */
        bool stop;
        int64_t ends;
    } gates[] = {
        {"gate, straight", SP_GATE, 0.5, 0, false, 6000 + 240},
        {"gate, swing 0.75", SP_GATE, 0.75, 0, false, 9000 + 240},
        {"loop, 120 → 60 bpm after 12 ticks", SP_LOOP, 0.5, 3000, false, 3000 + 6000 + 240},
        {"loop, stopped after 3000 frames", SP_LOOP, 0.5, 3000, true, 3000 + 240},
    };
    for (size_t i = 0; i < sizeof(gates) / sizeof(gates[0]); i++) {
        e = new_engine();
        n_evs = 0;
        load(e, 0, make_sample(96000, 1, RATE, dc_half));
        set_pad(e, 0, pad_of(0, gates[i].mode));
        step_spec s[] = {{.pos = 0}};
        set_pattern(e, pattern(16, s, 1), false);
        cmd(e, SP_CMD_SWING, gates[i].swing);
        cmd(e, SP_CMD_PLAY, 0);
        if (gates[i].change_at) {
            render(e, out, gates[i].change_at, 0);
            if (gates[i].stop) cmd(e, SP_CMD_STOP, 0);
            else cmd(e, SP_CMD_TEMPO, 60);
        }
        render(e, out, 30000, 0);
        const sp_event *end = find_event(SP_EV_VOICE_END, 0);
        CHECK(end && end->frame == gates[i].ends, "sequenced %s: ends at %lld (want %lld)", gates[i].label,
              end ? (long long)end->frame : -1LL, (long long)gates[i].ends);
        free_engine(e);
    }

    /* A gate that starts and ends inside one big block ends on its frame. */
    e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(96000, 1, RATE, dc_half));
    set_pad(e, 0, pad_of(0, SP_LOOP));
    step_spec one[] = {{.pos = 0}};
    set_pattern(e, pattern(16, one, 1), false);
    cmd(e, SP_CMD_PLAY, 0);
    render(e, out, 7000, 7000);
    const sp_event *end = find_event(SP_EV_VOICE_END, 0);
    CHECK(end && end->frame == 6000 + 240, "a gate within one 7000-frame block ends at %lld (want 6240)",
          end ? (long long)end->frame : -1LL);
    free_engine(e);

    /* At full polyphony a step's gate frees its voice before the next step
     * starts on the same frame: no voice is stolen for it. */
    e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(96000, 1, RATE, dc_half));
    for (int p = 0; p < SP_POLY; p++) set_pad(e, p, pad_of(0, p == 0 ? SP_GATE : SP_LOOP));
    for (int p = 1; p < SP_POLY; p++) trigger(e, p, 30);
    step_spec two[] = {{.pos = 0}, {.pos = 24}};
    set_pattern(e, pattern(16, two, 2), false);
    cmd(e, SP_CMD_PLAY, 0);
    render(e, out, 9000, 0);
    CHECK(atomic_load(&e->steals) == 0 && count_on(e) == SP_POLY,
          "full polyphony, a gate ending where the next step starts: %llu steals, %d sounding",
          (unsigned long long)atomic_load(&e->steals), count_on(e));
    free_engine(e);
    free(out);
}

static void test_unload_and_reset(void) {
    printf("unload, reset, queue overflow\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    sp_sample *s = make_sample(48000, 1, RATE, dc_half);
    load(e, 3, s);
    set_pad(e, 0, pad_of(3, SP_ONE_SHOT));
    trigger(e, 0, 127);
    float *out = buffer(9600);
    render(e, out, 4800, 0);
    load(e, 3, NULL);
    sp_render(e, out, 64); /* applies the unload; the voice fades */
    bool still = s->refs == 1;
    sp_garbage g;
    bool early = sp_pop_garbage(e, &g);
    render(e, out, 4800, 0); /* collect() frees the garbage */
    CHECK(still && !early && e->pads[0].slot == -1 && e->retired == NULL && max_abs(out, 300, 4800) == 0.0f,
          "unloading a playing sample fades its voice, clears its pads, frees it once silent");
    free_engine(e);

    e = new_engine();
    n_evs = 0;
    for (int i = 0; i < 2000; i++) {
        sp_cmd c = {.type = SP_CMD_TRIGGER, .pad = 0, .vel = 100};
        sp_push(e, &c);
    }
    sp_render(e, out, 64);
    CHECK(atomic_load(&e->cmds_dropped) == 2000 - SP_CMDS, "queue full: %llu of 2000 dropped, render fine",
          (unsigned long long)atomic_load(&e->cmds_dropped));

    /* Offline drain (no stream): live calls are dropped, state applies. */
    trigger(e, 0, 127);
    cmd(e, SP_CMD_TEMPO, 77);
    sp_drain(e, false);
    CHECK(e->seq.bpm == 77 && count_on(e) == 0, "offline drain applies state, drops live triggers");
    free(out);
    free_engine(e);
}

static void test_clip(void) {
    printf("output limit\n");
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(9600, 1, RATE, dc_half));
    for (int i = 0; i < 40; i++) {
        set_pad(e, i, pad_of(0, SP_ONE_SHOT));
        trigger(e, i, 127);
    }
    float *out = buffer(9600);
    render(e, out, 9600, 0);
    float m = max_abs(out, 0, 9600);
    CHECK(m <= 1.0f && m > 0.95f, "32 loud voices stay within ±1 (peak %.4f)", m);
    free(out);
    free_engine(e);
}

static void test_resampler(void) {
    printf("resampler (load time)\n");
    sp_sample *s = sine_sample(1000, 0.5, 44100, 44100);
    int64_t n = 0;
    int16_t *r = sp_resample(s->data, s->frames, 1, 44100, RATE, &n);
    double err = 0, sig = 0;
    for (int64_t j = 1000; j < n - 1000; j++) {
        double want = 0.5 * sin(2 * M_PI * 1000 * (double)j / RATE) * 32767;
        err += (r[j] - want) * (r[j] - want);
        sig += want * want;
    }
    double snr = 10 * log10(sig / err);
    CHECK(n == RATE && snr > 70, "1 kHz at 44.1 kHz → 48 kHz: %lld frames, SNR %.1f dB", (long long)n, snr);
    free(r);
    sp_sample_free(s);

    sp_sample *hi = sine_sample(30000, 0.5, 96000, 96000);
    r = sp_resample(hi->data, hi->frames, 1, 96000, RATE, &n);
    double rms = 0;
    for (int64_t j = 1000; j < n - 1000; j++) rms += (double)r[j] * r[j];
    rms = sqrt(rms / (double)(n - 2000)) / 32767;
    double atten = 20 * log10(rms / (0.5 / sqrt(2)));
    CHECK(atten < -60, "30 kHz at 96 kHz → 48 kHz is filtered, not aliased: %.1f dB", atten);
    free(r);
    sp_sample_free(hi);

    /* Peaks: 0.5, full scale, silence, then a partial chunk loud only on
     * the right channel. */
    int16_t pcm[1000 * 2] = {0};
    pcm[2 * 10] = 16384;
    pcm[2 * 300 + 1] = -32768;
    pcm[2 * 999 + 1] = 8192;
    uint8_t peaks[4];
    sp_peaks(pcm, 1000, 2, peaks);
    CHECK(sp_peak_count(1000) == 4 && peaks[0] == 128 && peaks[1] == 255 && peaks[2] == 0 && peaks[3] == 64,
          "peaks: one byte per %d frames, max over channels (%d %d %d %d)", SP_PEAK_FRAMES, peaks[0], peaks[1],
          peaks[2], peaks[3]);

    /* f32le from a binary that starts at an odd address, 3 channels → 2. */
    float f[] = {0.5f, -0.25f, 0.9f, 1.5f, -2.0f, 0.1f};
    uint8_t raw[sizeof(f) + 1];
    memcpy(raw + 1, f, sizeof(f));
    int16_t *s16 = sp_from_f32(raw + 1, 2, 3, 2);
    CHECK(s16[0] == 16384 && s16[1] == -8192 && s16[2] == 32767 && s16[3] == -32768,
          "f32 → 16-bit keeps 2 of 3 channels, clips (%d %d %d %d)", s16[0], s16[1], s16[2], s16[3]);
    free(s16);
}

/* `bench`: the cost of rendering 32 voices (stereo loops over 8 distinct
 * 4 s samples, pitched so the interpolation runs), in ns per voice-frame,
 * at the phone's burst size: blocks back to back, then one every 5 ms like
 * the callback (the core idles in between and wakes slower; that is the
 * number the phone's callback sees). */
static int bench(void) {
    sp_engine *e = new_engine();
    for (int s = 0; s < 8; s++) load(e, s, make_sample(RATE * 4, 2, RATE, noise));
    for (int i = 0; i < SP_POLY; i++) {
        sp_pad p = pad_of(i % 8, SP_LOOP);
        p.pitch = (float)(i % 7) - 3.3f;
        set_pad(e, i, p);
        trigger(e, i, 100);
    }
    float out[2 * 240];
    sp_render(e, out, 240);
    collect(e);
    for (int paced = 0; paced < 2; paced++) {
        const int blocks = paced ? 400 : 2000;
        double total = 0;
        for (int i = 0; i < blocks; i++) {
            struct timespec a, b;
            if (paced) nanosleep(&(struct timespec){0, 5000000}, NULL);
            clock_gettime(CLOCK_MONOTONIC, &a);
            sp_render(e, out, 240);
            clock_gettime(CLOCK_MONOTONIC, &b);
            total += (double)(b.tv_sec - a.tv_sec) * 1e9 + (double)(b.tv_nsec - a.tv_nsec);
        }
        printf("32 voices, 240-frame blocks%s: %.1f µs per block (%.2f%% of its 5 ms), %.1f ns per voice-frame\n",
               paced ? " every 5 ms" : " back to back", total / blocks / 1000, 100 * total / blocks / 5e6,
               total / blocks / 240 / SP_POLY);
        collect(e);
    }
    free_engine(e);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "bench") == 0) return bench();
    test_step_timing();
    test_block_independence();
    test_tempo_change();
    test_pattern_swap();
    test_choke();
    test_steal();
    test_pitch();
    test_reverse();
    test_loop_and_release();
    test_fades_and_gain();
    test_hits();
    test_quantize_and_gate_steps();
    test_unload_and_reset();
    test_clip();
    test_resampler();
    printf("%s: %d failure%s\n", failures ? "FAILED" : "passed", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
