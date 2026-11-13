/*
 * Host harness for c_src/sampler.c and c_src/recorder.c: renders offline
 * into buffers and checks the sequencer's timing to the frame, choke and
 * voice stealing without clicks, pitch, reverse, loops, gates, hits,
 * quantized launches, the resampler, the count-in and the recorder (also
 * on real threads against the NIF's handshake).
 *
 *   cc -O2 -Wall -Wextra -o /tmp/sampler_host c_src/test/sampler_host.c -lm && /tmp/sampler_host
 *   cc -g -O1 -fsanitize=address,undefined -o /tmp/sampler_host_asan c_src/test/sampler_host.c -lm && /tmp/sampler_host_asan
 *   cc -g -O1 -fsanitize=thread -o /tmp/sampler_host_tsan c_src/test/sampler_host.c -lm && /tmp/sampler_host_tsan
 *   /tmp/sampler_host bench     # render cost of 32 voices (build with -Os, as the app is)
 *
 * Exit 1 on any failure; each check prints one line. The threaded recorder
 * test runs STRESS_MS (1500) with STRESS_SEED (1). The bench also runs
 * on the phone: cross-compile with the NDK's clang, `adb push` it to
 * /data/local/tmp and run it under `taskset 1` (a little core).
 */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "../sampler.c"
#include "../recorder.c"

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

/* ── The count-in ─────────────────────────────────────────────────────────── */

/* Frames (relative to `out`) where sound starts after at least 1000
 * silent frames (a click's sine crosses zero inside it). */
static int sound_starts(const float *out, int64_t frames, int64_t *at, int max) {
    int n = 0;
    int64_t quiet = 1000;
    for (int64_t i = 0; i < frames; i++) {
        if (fabsf(out[2 * i]) <= 1e-7f) {
            quiet++;
            continue;
        }
        if (quiet >= 1000 && n < max) at[n++] = i;
        quiet = 0;
    }
    return n;
}

static void test_count_in(void) {
    printf("count-in (clicks on the beat, the downbeat reported)\n");
    const double tempos[] = {120.0, 133.0, 97.5};
    for (size_t ti = 0; ti < sizeof(tempos) / sizeof(tempos[0]); ti++) {
        double bpm = tempos[ti], interval = 60.0 * RATE / bpm;
        sp_engine *e = new_engine();
        n_evs = 0;
        cmd(e, SP_CMD_TEMPO, bpm);
        int64_t lead = 1001;
        float *pre = buffer(lead);
        render(e, pre, lead, 0);
        push(e, (sp_cmd){.type = SP_CMD_COUNT_IN, .u.count_in = {9, 4}});
        int64_t frames = (int64_t)(5 * interval);
        float *out = buffer(frames);
        render(e, out, frames, 0);
        const sp_event *ev = find_event(SP_EV_COUNT_IN, -1);
        int64_t until = lead + (int64_t)ceil(4 * interval - SP_FRAME_TOL);
        int64_t at[8];
        int n = sound_starts(out, frames, at, 8), bad = n == 4 ? 0 : 1;
        /* A click starts from 0 (sin 0, attack 0): heard from its 2nd frame. */
        for (int k = 0; k < n && k < 4; k++)
            if (at[k] != (int64_t)ceil(k * interval - SP_FRAME_TOL) + 1) bad++;
        float accent = max_abs(out, 0, (int64_t)(interval / 2)), plain = max_abs(out, (int64_t)interval, (int64_t)(1.5 * interval));
        CHECK(ev && ev->a == 9 && ev->b == 4 && ev->frame == lead && ev->until == until && bad == 0 && accent > plain &&
                  max_abs(out, until - lead, frames) == 0,
              "stopped at %.1f bpm: first %lld until %lld (want %lld, %lld), %d clicks, %d off, accent %.2f > %.2f",
              bpm, ev ? (long long)ev->frame : -1, ev ? (long long)ev->until : -1, (long long)lead, (long long)until, n,
              bad, accent, plain);
        free(pre);
        free(out);
        free_engine(e);
    }

    /* Playing: from the sequencer's next bar, whatever the swing. */
    const int64_t play_tempos[][2] = {{120, 1}, {133, 1}, {267, 2}};
    for (size_t ti = 0; ti < sizeof(play_tempos) / sizeof(play_tempos[0]); ti++) {
        int64_t bn = play_tempos[ti][0], bd = play_tempos[ti][1];
        sp_engine *e = new_engine();
        n_evs = 0;
        cmd(e, SP_CMD_TEMPO, (double)bn / bd);
        cmd(e, SP_CMD_SWING, 0.62);
        cmd(e, SP_CMD_PLAY, 0);
        int64_t into = 30011;
        float *pre = buffer(into);
        render(e, pre, into, 0);
        push(e, (sp_cmd){.type = SP_CMD_COUNT_IN, .u.count_in = {3, 4}});
        int64_t frames = expected_frame(3 * 384, 62, bn, bd) - into;
        float *out = buffer(frames);
        render(e, out, frames, 0);
        const sp_event *ev = find_event(SP_EV_COUNT_IN, -1);
        int64_t bar = expected_frame(384, 62, bn, bd), until = expected_frame(768, 62, bn, bd);
        int64_t at[8];
        int n = sound_starts(out, frames, at, 8), bad = n == 4 ? 0 : 1;
        for (int k = 0; k < n && k < 4; k++)
            if (into + at[k] != expected_frame(384 + 96 * k, 62, bn, bd) + 1) bad++;
        CHECK(ev && ev->frame == bar && ev->until == until && bad == 0,
              "playing at %.1f bpm swing 0.62: first %lld until %lld (want the bars %lld, %lld), %d clicks, %d off",
              (double)bn / bd, ev ? (long long)ev->frame : -1, ev ? (long long)ev->until : -1, (long long)bar,
              (long long)until, n, bad);
        free(pre);
        free(out);
        free_engine(e);
    }

    /* Cancelled after two clicks: no more. */
    sp_engine *e = new_engine();
    push(e, (sp_cmd){.type = SP_CMD_COUNT_IN, .u.count_in = {1, 4}});
    float *out = buffer(4 * RATE);
    render(e, out, 30000, 0);
    push(e, (sp_cmd){.type = SP_CMD_COUNT_IN, .u.count_in = {1, 0}});
    render(e, out + 2 * 30000, 4 * RATE - 30000, 0);
    int64_t at[8];
    int n = sound_starts(out, 4 * RATE, at, 8);
    CHECK(n == 2 && at[1] == 24001, "cancelled after 2 clicks: %d clicks", n);
    free(out);
    free_engine(e);
}

/* ── The recorder ─────────────────────────────────────────────────────────── */

#define REC_T0 1000000000LL

static int64_t burst_at;

/* Input: a quiet floor (±0.01), a ±0.5 square from `burst_at`; channel 1
 * a little off channel 0 so a swap shows. */
static double rec_signal(int64_t i, int c) {
    double x = i >= burst_at ? ((i / 7) % 2 ? 0.5 : -0.5) : noise(i, 0) * 0.02;
    return x + c * 0.001;
}

/* When input frame `i` was captured. */
static int64_t capture_ns(double i) { return REC_T0 + (int64_t)llround(i * 1e9 / RATE); }

/* Feed `frames` of rec_signal in random blocks; once the input passes
 * frame `when` (≥ 0), set the start time to that of frame `target`. */
static void feed(rc_recorder *r, int64_t frames, int64_t when, double target) {
    float block[2 * 1024];
    bool told = false;
    for (int64_t done = 0; done < frames;) {
        int n = 1 + (int)(next_rand() % 997);
        if (n > frames - done) n = (int)(frames - done);
        for (int i = 0; i < n; i++)
            for (int c = 0; c < r->channels; c++) block[i * r->channels + c] = (float)rec_signal(r->pos + i, c);
        rc_write(r, block, n, capture_ns((double)r->pos));
        done += n;
        if (when >= 0 && r->pos >= when && !told) {
            rc_start_at(r, atomic_load(&r->gen), capture_ns(target));
            told = true;
        }
    }
}

/* Frames recorded that differ from the input at started_at + k. */
static int64_t rec_mismatches(rc_recorder *r) {
    int64_t start = atomic_load(&r->started_at), frames = atomic_load(&r->frames), bad = 0;
    for (int64_t k = 0; k < frames; k++)
        for (int c = 0; c < r->channels; c++)
            if (r->buf[k * r->channels + c] != (float)rec_signal(start + k, c)) bad++;
    return bad;
}

/* Peak bytes that differ from the recording's own peaks. */
static int64_t peak_mismatches(rc_recorder *r, int64_t count) {
    int64_t frames = atomic_load(&r->frames), bad = count == rc_peak_count(frames) ? 0 : 1;
    for (int64_t p = 0; p < count; p++) {
        float m = 0;
        for (int64_t k = p * RC_PEAK_FRAMES; k < frames && k < (p + 1) * RC_PEAK_FRAMES; k++)
            for (int c = 0; c < r->channels; c++)
                if (fabsf(r->buf[k * r->channels + c]) > m) m = fabsf(r->buf[k * r->channels + c]);
        if (r->peaks[p] != rc_peak_byte(m)) bad++;
    }
    return bad;
}

static void test_recorder(void) {
    printf("recorder (meter, threshold and pre-roll, start time, max length, peaks)\n");
    rc_recorder *r = calloc(1, sizeof(*r));
    rc_init(r, RATE, 2);
    burst_at = INT64_MAX;

    feed(r, 5000, -1, 0);
    float level = rc_take_level(r);
    CHECK(level > 0.0095f && level <= 0.0111f && fabs(rc_db(level) + 39.6) < 0.5 && rc_take_level(r) == 0 &&
              rc_db(0) == RC_FLOOR_DB && atomic_load(&r->frames) == 0,
          "idle: meters (%.4f = %.1f dBFS, then silence once taken), records nothing", level, rc_db(level));

    /* On sound: the first frame at or over the threshold, 480 frames before. */
    CHECK(rc_arm(r, RC_ON_SOUND, 60 * RATE, 0.1f, 480, RATE / 2), "armed on sound");
    burst_at = r->pos + 10037;
    feed(r, 30000, -1, 0);
    int64_t started = atomic_load(&r->started_at), trigger = atomic_load(&r->trigger_at);
    CHECK(trigger == burst_at && started == burst_at - 480 && atomic_load(&r->frames) == r->pos - started &&
              rec_mismatches(r) == 0,
          "on sound: triggered at %lld (want %lld), from %lld (480 before), %lld frames as captured",
          (long long)trigger, (long long)burst_at, (long long)started, (long long)atomic_load(&r->frames));
    int was = rc_finish(r);
    int64_t peaks = rc_flush_peak(r);
    CHECK(was == RC_RECORDING && atomic_load(&r->state) == RC_IDLE && peak_mismatches(r, peaks) == 0,
          "finished: %lld peak bytes (the last partial) match the recording", (long long)peaks);
    int64_t frames = atomic_load(&r->frames);
    feed(r, 3000, -1, 0);
    CHECK(atomic_load(&r->frames) == frames, "after finishing, input records nothing");

    /* A sound sooner after arming than the pre-roll: from the arm. */
    burst_at = INT64_MAX;
    CHECK(rc_arm(r, RC_ON_SOUND, 60 * RATE, 0.1f, 4800, RATE / 2), "armed on sound again");
    int64_t armed = r->pos;
    burst_at = armed + 1000;
    feed(r, 5000, -1, 0);
    CHECK(atomic_load(&r->started_at) == armed && atomic_load(&r->trigger_at) == burst_at && rec_mismatches(r) == 0,
          "sound 1000 frames after arming with 4800 of pre-roll: from the arm (%lld, want %lld)",
          (long long)atomic_load(&r->started_at), (long long)armed);
    rc_finish(r);

    /* Below the threshold: waits, the meter still moves. */
    burst_at = INT64_MAX;
    rc_arm(r, RC_ON_SOUND, 60 * RATE, 0.1f, 480, RATE / 2);
    feed(r, 40000, -1, 0);
    CHECK(atomic_load(&r->state) == RC_WAIT_SOUND && atomic_load(&r->frames) == 0 && rc_take_level(r) > 0,
          "quiet: still waiting after 40000 frames (the ring wrapped), metering");
    rc_finish(r);

    /* At a time: the frame captured then, ahead of time, late (from the
     * ring), and later than the ring reaches. */
    struct {
        int64_t when, frames;
        double target;
        const char *what;
    } cases[] = {
        {10000, 40000, 30000.4, "known ahead"},
        {30000, 40000, 25000.0, "5000 frames late, from the ring"},
        {30000, 40000, 30000.0, "on the frame just captured"},
        {50000, 60000, 20000.0, "30000 frames late, past the ring"},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        rc_arm(r, RC_AT_TIME, 60 * RATE, 0, 0, RATE / 2);
        int64_t base = r->pos;
        feed(r, cases[i].frames, base + cases[i].when, (double)base + cases[i].target);
        int64_t want = base + (int64_t)ceil(cases[i].target - 1e-9), got = atomic_load(&r->started_at);
        int64_t trig = atomic_load(&r->trigger_at);
        bool past = cases[i].when - cases[i].target > RATE / 2;
        bool ok = past ? trig == want && got > want && got - want < (int64_t)(cases[i].when - cases[i].target)
                       : got == want && trig == want;
        CHECK(ok && rec_mismatches(r) == 0, "start time %s: from %lld (target %lld, trigger %lld)", cases[i].what,
              (long long)(got - base), (long long)(want - base), (long long)(trig - base));
        rc_finish(r);
    }

    /* Now, up to the maximum: then full, nothing more. */
    rc_arm(r, RC_NOW, 10000, 0, 0, 0);
    int64_t now = r->pos;
    burst_at = now + 3000;
    feed(r, 25000, -1, 0);
    CHECK(atomic_load(&r->state) == RC_FULL && atomic_load(&r->frames) == 10000 && atomic_load(&r->started_at) == now &&
              rec_mismatches(r) == 0 && atomic_load(&r->peak_bytes) == 39,
          "now, 10000 frames at most: full at %lld frames from the arm, %lld peak bytes",
          (long long)atomic_load(&r->frames), (long long)atomic_load(&r->peak_bytes));
    CHECK(rc_finish(r) == RC_FULL && rc_flush_peak(r) == 40 && peak_mismatches(r, 40) == 0,
          "finishing a full recording flushes its last 16 frames' peak");

    rc_free_buffers(r);
    free(r);
}

/* The whole chain: the count-in plays while the sequencer runs, the input
 * hears the output after 1500 frames of latency, the event thread hands
 * the downbeat's heard time to the recorder one block late. The recording
 * starts exactly with what sounded on the downbeat. */
static void test_count_in_loopback(void) {
    printf("count-in through a loopback (output latency, the downbeat on the recording's first frame)\n");
    const int64_t latency = 1500;
    sp_engine *e = new_engine();
    n_evs = 0;
    load(e, 0, make_sample(2400, 1, RATE, noise));
    set_pad(e, 0, pad_of(0, SP_ONE_SHOT));
    step_spec specs[] = {{.pos = 0, .pad = 0}};
    set_pattern(e, pattern(16, specs, 1), false);
    cmd(e, SP_CMD_TEMPO, 111);
    cmd(e, SP_CMD_PLAY, 0);

    rc_recorder *r = calloc(1, sizeof(*r));
    rc_init(r, RATE, 2);
    const int64_t frames = 6 * RATE;
    float *out = buffer(frames);
    bool armed = false, told = false;
    int64_t until = -1;
    for (int64_t done = 0; done < frames;) {
        int n = 1 + (int)(next_rand() % 997);
        if (n > frames - done) n = (int)(frames - done);
        if (!armed && done >= 20000) {
            rc_arm(r, RC_AT_TIME, 60 * RATE, 0, 0, RATE / 2);
            push(e, (sp_cmd){.type = SP_CMD_COUNT_IN, .u.count_in = {atomic_load(&r->gen), 4}});
            armed = true;
        }
        sp_render(e, out + 2 * done, n);
        /* Input frame j is engine frame j, heard (and captured) `latency` later. */
        rc_write(r, out + 2 * done, n, capture_ns((double)(done + latency)));
        done += n;
        sp_event ev;
        while (sp_pop_event(e, &ev))
            if (!told && ev.type == SP_EV_COUNT_IN) {
                until = ev.until;
                rc_start_at(r, (uint32_t)ev.a, capture_ns((double)(until + latency)));
                told = true;
            }
        collect(e);
    }
    int64_t start = atomic_load(&r->started_at), n = atomic_load(&r->frames), bad = 0;
    for (int64_t k = 0; k < n && until + k < frames; k++)
        for (int c = 0; c < 2; c++)
            if (r->buf[2 * k + c] != out[2 * (until + k) + c]) bad++;
    int64_t bar2 = expected_frame(2 * 384, 50, 111, 1);
    int64_t at[4];
    int hits = onsets(r->buf, n < 4800 ? n : 4800, at, 4, 0);
    CHECK(start == until && until == bar2 && bad == 0 && hits >= 1 && at[0] <= 1,
          "111 bpm: recording from engine frame %lld (the downbeat %lld, bar 2 at %lld), %lld frames as heard, the "
          "pad's onset at %lld",
          (long long)start, (long long)until, (long long)bar2, (long long)n, hits ? (long long)at[0] : -1);
    rc_finish(r);
    rc_free_buffers(r);
    free(r);
    free(out);
    free_engine(e);
}

typedef struct {
    rc_gate *g;
    _Atomic bool in, left;
} gate_probe;

/* A producer inside the gate for 50 ms. */
static void *gate_holder(void *arg) {
    gate_probe *p = arg;
    if (!rc_enter(p->g, 7)) return NULL;
    atomic_store(&p->in, true);
    nanosleep(&(struct timespec){0, 50000000}, NULL);
    atomic_store(&p->left, true);
    rc_leave(p->g);
    return NULL;
}

/* Arm generations: a start time for an arm that is over never starts a
 * later one, across a new input too. The input's gate admits only the open
 * input and, shut, waits out a producer inside. */
static void test_recorder_generations(void) {
    printf("recorder generations and the input's gate\n");
    rc_recorder *r = calloc(1, sizeof(*r));
    rc_init(r, RATE, 2);
    burst_at = INT64_MAX;
    feed(r, 2000, -1, 0);

    rc_arm(r, RC_AT_TIME, RATE, 0, 0, RATE / 2);
    uint32_t first = atomic_load(&r->gen);
    rc_finish(r);
    rc_free_buffers(r);
    rc_arm(r, RC_AT_TIME, RATE, 0, 0, RATE / 2);
    uint32_t second = atomic_load(&r->gen);
    int64_t base = r->pos;
    /* The first arm's downbeat, arriving late: inside what the second feeds. */
    rc_start_at(r, first, capture_ns((double)base + 500));
    feed(r, 6000, -1, 0);
    bool waited = atomic_load(&r->state) == RC_WAIT_TIME && atomic_load(&r->frames) == 0;
    rc_start_at(r, second, capture_ns((double)base + 7000));
    feed(r, 4000, -1, 0);
    CHECK(second == first + 1 && waited && atomic_load(&r->trigger_at) == base + 7000 &&
              atomic_load(&r->started_at) == base + 7000 && rec_mismatches(r) == 0,
          "arm %u's start time doesn't start arm %u (still counting 6000 frames on); its own starts it on frame %lld "
          "(want %lld)",
          first, second, (long long)(atomic_load(&r->started_at) - base), 7000LL);
    rc_finish(r);
    rc_free_buffers(r);

    rc_init(r, RATE, 1);
    rc_arm(r, RC_AT_TIME, RATE, 0, 0, RATE / 2);
    feed(r, 9000, -1, 0);
    CHECK(atomic_load(&r->gen) == second + 1 && atomic_load(&r->state) == RC_WAIT_TIME && atomic_load(&r->frames) == 0,
          "a new input: the generation goes on (%u), the last arm's start time starts nothing", atomic_load(&r->gen));
    rc_finish(r);
    rc_free_buffers(r);
    free(r);

    rc_gate g = {0};
    bool before = rc_enter(&g, 7);
    rc_gate_open(&g, 7);
    bool other = rc_enter(&g, 6), none = rc_enter(&g, 0), mine = rc_enter(&g, 7);
    if (mine) rc_leave(&g);
    CHECK(!before && !other && !none && mine && atomic_load(&g.inside) == 0,
          "gate: shut admits nobody, open only its input");

    gate_probe p = {.g = &g};
    pthread_t t;
    pthread_create(&t, NULL, gate_holder, &p);
    for (int i = 0; i < 2000 && !atomic_load(&p.in); i++) nanosleep(&(struct timespec){0, 1000000}, NULL);
    rc_gate_shut(&g);
    bool held = atomic_load(&p.in) && atomic_load(&p.left);
    bool after = rc_enter(&g, 7);
    pthread_join(t, NULL);
    CHECK(held && !after && atomic_load(&g.inside) == 0,
          "gate: shutting waits out the producer inside (50 ms), then keeps its input out");
}

/* ── The recorder under threads ──────────────────────────────────────────── */

/* The NIF's roles on real threads: a producer (the mic callback or the
 * capture thread) writing behind the input's gate, a straggler from closed
 * inputs, the event thread (count-in starts from a queue in arm order, and
 * under the lock the published counters and peak bytes), and control
 * (arm, stop, cancel, close and reopen with another channel count) under
 * the lock with random gaps. Every input frame's value is a function of
 * its position, so each take is checked frame by frame: a contiguous run
 * of the input from where it started, its peaks, its trigger. Build with
 * -fsanitize=thread for the races themselves (STRESS_MS, STRESS_SEED). */

#define STRESS_TAKES (1 << 16)

/* Input frame p, channel c: exact in float, loud in one 4096-frame stretch
 * of four (thresholds trip there), the channels apart. */
static float stress_sample(int64_t p, int c) {
    uint32_t h = (uint32_t)p * 2654435761u + (uint32_t)c * 40503u;
    float x = (float)((h >> 8) & 0xffff) / 65536.0f * (c ? -1.0f : 1.0f);
    return ((p >> 12) & 3) == 0 ? x : x * 0.0625f;
}

static uint8_t stress_peak(int ch, int64_t start, int64_t k, int64_t frames) {
    float m = 0;
    for (int64_t f = k * RC_PEAK_FRAMES; f < (k + 1) * RC_PEAK_FRAMES && f < frames; f++)
        for (int c = 0; c < ch; c++)
            if (fabsf(stress_sample(start + f, c)) > m) m = fabsf(stress_sample(start + f, c));
    return rc_peak_byte(m);
}

typedef struct {
    rc_recorder r;
    rc_gate gate;
    pthread_mutex_t lock; /* the NIF's IN.lock */
    unsigned seed;
    _Atomic bool quit;
    _Atomic int64_t input;    /* the open (or last) input's id */
    _Atomic int64_t produced; /* frames the producer has written to it */
    _Atomic uint32_t counting; /* the take waiting for its count-in, 0 none */
    _Atomic uint32_t queue[STRESS_TAKES];
    _Atomic int q_tail, q_head;
    _Atomic int64_t issued[STRESS_TAKES]; /* the frame a take's start time was given for */
    /* Control's, under lock (the reader reads them under it too). */
    bool armed;
    int mode;
    int64_t max_frames, pre_roll;
    float threshold;
    uint32_t take;
    /* The reader's, under lock. */
    uint32_t read_take;
    int64_t read_peaks;
    long reads;
    /* Tallies. */
    _Atomic long bad, refused, stragglers, stale_starts;
    long takes[3], full, empty, cancels, reopens;
} stress_t;

static void stress_fail(stress_t *s, const char *what, long long a, long long b) {
    if (atomic_fetch_add(&s->bad, 1) < 8) printf("  FAIL stress: %s (%lld, %lld)\n", what, a, b);
}

static void *stress_producer(void *arg) {
    stress_t *s = arg;
    unsigned seed = s->seed * 3 + 1;
    float block[2 * 1024];
    int64_t mine = 0, count = 0;
    while (!atomic_load(&s->quit)) {
        int64_t id = atomic_load(&s->input);
        if (id != mine) {
            mine = id;
            count = 0;
        }
        int n = 1 + (int)(rand_r(&seed) % 1024);
        if (rc_enter(&s->gate, mine)) {
            const int ch = s->r.channels;
            for (int i = 0; i < n; i++)
                for (int c = 0; c < ch; c++) block[i * ch + c] = stress_sample(count + i, c);
            rc_write(&s->r, block, n, capture_ns((double)count));
            count += n;
            atomic_store(&s->produced, count);
            rc_leave(&s->gate);
        } else {
            atomic_fetch_add(&s->refused, 1);
        }
        if (rand_r(&seed) % 8 == 0) sched_yield();
    }
    return NULL;
}

/* A producer of an input that was closed: never admitted. */
static void *stress_straggler(void *arg) {
    stress_t *s = arg;
    unsigned seed = s->seed * 5 + 2;
    while (!atomic_load(&s->quit)) {
        int64_t stale = atomic_load(&s->input) - 1 - (int64_t)(rand_r(&seed) % 3);
        if (rc_enter(&s->gate, stale)) {
            stress_fail(s, "a closed input's producer got in", stale, atomic_load(&s->input));
            rc_leave(&s->gate);
        }
        atomic_fetch_add(&s->stragglers, 1);
        if (rand_r(&seed) % 4 == 0) sched_yield();
    }
    return NULL;
}

/* The event thread's count-in starts, in arm order, often late: around
 * the producer's position (up to an eighth of a second before it). */
static void *stress_events(void *arg) {
    stress_t *s = arg;
    unsigned seed = s->seed * 7 + 3;
    while (!atomic_load(&s->quit)) {
        int head = atomic_load(&s->q_head);
        if (head == atomic_load(&s->q_tail)) {
            usleep(100);
            continue;
        }
        uint32_t take = atomic_load(&s->queue[head & (STRESS_TAKES - 1)]);
        atomic_store(&s->q_head, head + 1);
        if (rand_r(&seed) % 2) usleep(rand_r(&seed) % 2000);
        int64_t at = atomic_load(&s->produced) + (int64_t)(rand_r(&seed) % (RATE / 2)) - RATE / 8;
        if (at < 0) at = 0;
        atomic_store(&s->issued[take & (STRESS_TAKES - 1)], at);
        if (take != atomic_load(&s->counting)) atomic_fetch_add(&s->stale_starts, 1);
        rc_start_at(&s->r, take, capture_ns((double)at));
    }
    return NULL;
}

/* deliver_input: under the lock, what an armed recorder has published.
 * Peak bytes below peak_bytes are final and follow started_at. */
static void *stress_reader(void *arg) {
    stress_t *s = arg;
    while (!atomic_load(&s->quit)) {
        if (pthread_mutex_trylock(&s->lock) == 0) {
            if (s->armed) {
                if (s->read_take != s->take) {
                    s->read_take = s->take;
                    s->read_peaks = 0;
                }
                int64_t pb = atomic_load(&s->r.peak_bytes);
                int64_t start = atomic_load(&s->r.started_at);
                int64_t frames = atomic_load(&s->r.frames);
                if (pb > 0 && start < 0) stress_fail(s, "peak bytes before the start", pb, start);
                if (pb * RC_PEAK_FRAMES > frames || frames > s->max_frames)
                    stress_fail(s, "published counts out of order", pb, frames);
                for (int64_t k = s->read_peaks; start >= 0 && k < pb; k++)
                    if (s->r.peaks[k] != stress_peak(s->r.channels, start, k, frames))
                        stress_fail(s, "a published peak byte", k, s->r.peaks[k]);
                s->read_peaks = pb;
            }
            rc_take_level(&s->r);
            s->reads++;
            pthread_mutex_unlock(&s->lock);
        }
        usleep(50);
    }
    return NULL;
}

/* record_stop: the take, checked against the input. Control, lock held. */
static void stress_stop(stress_t *s) {
    rc_recorder *r = &s->r;
    int was = rc_finish(r);
    atomic_store(&s->counting, 0);
    int64_t frames = atomic_load(&r->frames);
    if (frames > 0) {
        int64_t peaks = rc_flush_peak(r), start = atomic_load(&r->started_at), trig = atomic_load(&r->trigger_at);
        const int ch = r->channels;
        if (start < 0 || frames > s->max_frames || (was == RC_FULL && frames != s->max_frames))
            stress_fail(s, "start or length", start, frames);
        if (peaks != rc_peak_count(frames)) stress_fail(s, "peak count", peaks, frames);
        int64_t wrong = 0;
        for (int64_t k = 0; k < frames; k++)
            for (int c = 0; c < ch; c++)
                if (r->buf[k * ch + c] != stress_sample(start + k, c)) wrong++;
        if (wrong) stress_fail(s, "frames not the input's from the start", wrong, start);
        for (int64_t p = 0; p < peaks; p++)
            if (r->peaks[p] != stress_peak(ch, start, p, frames)) stress_fail(s, "a peak byte", p, r->peaks[p]);
        if (s->mode == RC_AT_TIME) {
            int64_t want = atomic_load(&s->issued[s->take & (STRESS_TAKES - 1)]);
            if (trig != want || start < trig) stress_fail(s, "count-in start: another take's time", trig, want);
        } else if (s->mode == RC_ON_SOUND) {
            float loud = 0;
            for (int c = 0; c < ch; c++)
                if (fabsf(stress_sample(trig, c)) > loud) loud = fabsf(stress_sample(trig, c));
            if (loud < s->threshold || start > trig || start < trig - s->pre_roll)
                stress_fail(s, "on sound: trigger or pre-roll", trig, start);
        } else if (trig != start) {
            stress_fail(s, "now: trigger", trig, start);
        }
        s->takes[s->mode]++;
        if (was == RC_FULL) s->full++;
    } else {
        s->empty++;
    }
    rc_free_buffers(r);
    s->armed = false;
}

static void stress_arm(stress_t *s, unsigned *seed) {
    int mode = (int)(rand_r(seed) % 3);
    if (mode == RC_AT_TIME && atomic_load(&s->q_tail) - atomic_load(&s->q_head) >= STRESS_TAKES) return;
    int64_t max = 64 + (int64_t)(rand_r(seed) % (2 * RATE)), pre = (int64_t)(rand_r(seed) % (RATE / 10));
    float threshold = 0.1f + (float)(rand_r(seed) % 85) / 100.0f;
    if (!rc_arm(&s->r, mode, max, threshold, pre, mode == RC_NOW ? 0 : pre > RATE / 2 ? pre : RATE / 2)) {
        stress_fail(s, "arm refused", mode, max);
        return;
    }
    s->armed = true;
    s->mode = mode;
    s->max_frames = max;
    s->pre_roll = pre;
    s->threshold = threshold;
    s->take = atomic_load(&s->r.gen);
    atomic_store(&s->issued[s->take & (STRESS_TAKES - 1)], -1);
    if (mode == RC_AT_TIME) {
        atomic_store(&s->counting, s->take);
        int tail = atomic_load(&s->q_tail);
        atomic_store(&s->queue[tail & (STRESS_TAKES - 1)], s->take);
        atomic_store(&s->q_tail, tail + 1);
    }
}

static void test_recorder_stress(void) {
    const char *ms_env = getenv("STRESS_MS"), *seed_env = getenv("STRESS_SEED");
    int64_t ms = ms_env ? atoll(ms_env) : 1500;
    stress_t *s = calloc(1, sizeof(*s));
    s->seed = seed_env ? (unsigned)strtoul(seed_env, NULL, 10) : 1;
    printf("recorder under threads (%lld ms, seed %u: producer, straggler, events, reader, control)\n", (long long)ms,
           s->seed);
    pthread_mutex_init(&s->lock, NULL);
    int64_t ids = 1;
    rc_init(&s->r, RATE, 2);
    atomic_store(&s->input, ids);
    rc_gate_open(&s->gate, ids);

    pthread_t threads[4];
    void *(*mains[4])(void *) = {stress_producer, stress_straggler, stress_events, stress_reader};
    for (int i = 0; i < 4; i++) pthread_create(&threads[i], NULL, mains[i], s);

    unsigned seed = s->seed;
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((now.tv_sec - t0.tv_sec) * 1000 + (now.tv_nsec - t0.tv_nsec) / 1000000 >= ms) break;
        pthread_mutex_lock(&s->lock);
        unsigned a = rand_r(&seed) % 100;
        if (!s->armed && a < 40) {
            stress_arm(s, &seed);
        } else if (s->armed && a < 60) {
            stress_stop(s);
        } else if (s->armed && a < 70) {
            rc_finish(&s->r);
            atomic_store(&s->counting, 0);
            rc_free_buffers(&s->r);
            s->armed = false;
            s->cancels++;
        } else if (a >= 95) {
            /* close_input_locked, then the next input_open */
            rc_gate_shut(&s->gate);
            if (s->armed) {
                rc_finish(&s->r);
                atomic_store(&s->counting, 0);
                rc_free_buffers(&s->r);
                s->armed = false;
            }
            rc_init(&s->r, RATE, 1 + (int)(rand_r(&seed) % 2));
            atomic_store(&s->input, ++ids);
            rc_gate_open(&s->gate, ids);
            s->reopens++;
        }
        pthread_mutex_unlock(&s->lock);
        usleep(rand_r(&seed) % 300);
    }
    atomic_store(&s->quit, true);
    for (int i = 0; i < 4; i++) pthread_join(threads[i], NULL);
    if (s->armed) stress_stop(s);

    long checked = s->takes[0] + s->takes[1] + s->takes[2];
    CHECK(atomic_load(&s->bad) == 0,
          "%ld takes checked frame by frame (now %ld, on sound %ld, count-in %ld; %ld full), %ld stopped before "
          "starting, %ld cancelled, %ld inputs reopened, %ld reads under the lock",
          checked, s->takes[RC_NOW], s->takes[RC_ON_SOUND], s->takes[RC_AT_TIME], s->full, s->empty, s->cancels,
          s->reopens, s->reads);
    CHECK(s->takes[RC_NOW] > 0 && s->takes[RC_ON_SOUND] > 0 && s->takes[RC_AT_TIME] > 0 && s->full > 0 &&
              s->reopens > 0 && atomic_load(&s->stale_starts) > 0 && atomic_load(&s->refused) > 0,
          "every path ran: %ld count-in starts for takes already over, %ld writes refused at the gate after a "
          "close, %ld straggler tries",
          atomic_load(&s->stale_starts), atomic_load(&s->refused), atomic_load(&s->stragglers));
    rc_free_buffers(&s->r);
    pthread_mutex_destroy(&s->lock);
    free(s);
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
    test_count_in();
    test_recorder();
    test_count_in_loopback();
    test_recorder_generations();
    test_recorder_stress();
    printf("%s: %d failure%s\n", failures ? "FAILED" : "passed", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
