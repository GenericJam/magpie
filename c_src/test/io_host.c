/*
 * Host harness for c_src/magpie_io.c: Magpie's mob_audio_io processors
 * ("magpie_out", "magpie_mic") driven as the plugin drives them, with a
 * fake plugin (mai_register keeps the processors, mai_now_ns is a clock the
 * test sets). It checks the stream events (the renderer's role, the rate,
 * a reopen, a second output, the mic opening and going), the engine clock
 * from mai_time.present_ns (and its refresh), that sequenced events land
 * on their presentation time, a live hit stamped where it was heard, the
 * count-in started on the frame captured when its downbeat is heard
 * through an output and an input latency, the mic's capture time without
 * a presentation time, and the import chunks.
 *
 *   cc -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-function -o /tmp/io_host c_src/test/io_host.c -lm -lpthread && /tmp/io_host
 *   cc -std=c11 -g -O1 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -o /tmp/io_host_asan c_src/test/io_host.c -lm -lpthread && /tmp/io_host_asan
 *
 * Needs deps/mob_audio_io (the header). Exit 1 on any failure; each check
 * prints one line.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>

#include "../magpie_io.c"
#include "../load_queue.c"

#define RATE 48000
#define BLOCK 240               /* 5 ms */
#define BLOCK_NS 5000000LL
#define OUT_LATENCY_NS 30000000LL /* render → heard */
#define IN_LATENCY_NS 10000000LL  /* captured → capture callback */
#define T0_NS 1000000000LL        /* host time of the first callback */

static int failures = 0;

#define CHECK(cond, ...)                                                                                               \
    do {                                                                                                               \
        bool ok_ = (cond);                                                                                             \
        printf("%s ", ok_ ? "  ok  " : "  FAIL");                                                                      \
        printf(__VA_ARGS__);                                                                                           \
        printf("\n");                                                                                                  \
        if (!ok_) failures++;                                                                                          \
    } while (0)

/* ── The fake plugin ─────────────────────────────────────────────────────── */

static int64_t fake_now;
int64_t mai_now_ns(void) { return fake_now; }
int32_t mai_abi_version(void) { return MAI_ABI_VERSION; }

static struct {
    char name[MAI_NAME_MAX];
    mai_processor p;
} procs[4];
static int n_procs;

int32_t mai_register(const char *name, const mai_processor *p, void *ctx) {
    (void)ctx;
    if (n_procs == 4) return MAI_ERR_FULL;
    snprintf(procs[n_procs].name, MAI_NAME_MAX, "%s", name);
    procs[n_procs++].p = *p;
    return MAI_OK;
}

static const mai_processor *proc(const char *name) {
    for (int i = 0; i < n_procs; i++)
        if (strcmp(procs[i].name, name) == 0) return &procs[i].p;
    return NULL;
}

/* ── Scaffolding ─────────────────────────────────────────────────────────── */

static void push(sp_cmd c) {
    if (!mio_push(&c)) {
        printf("  FAIL command queue full\n");
        failures++;
    }
}

static void event(const char *name, int32_t stream, int32_t ev, int rate, int channels) {
    mai_time t = {0, fake_now, 0, rate, channels};
    proc(name)->stream_event(NULL, stream, ev, &t);
}

static float out_buf[2 * BLOCK];

/* One output callback at host time `host` (its block heard at `present`,
 * 0: not known yet). */
static void render_at(int64_t host, int64_t present) {
    fake_now = host;
    mai_time t = {0, host, present, RATE, 2};
    memset(out_buf, 0, sizeof(out_buf));
    proc(MIO_OUT)->render(NULL, out_buf, BLOCK, &t);
}

static sp_event evs[4096];
static int n_evs;

static void collect(void) {
    sp_event ev;
    while (sp_pop_event(&SP, &ev))
        if (n_evs < (int)(sizeof(evs) / sizeof(evs[0]))) evs[n_evs++] = ev;
    sp_garbage g;
    while (sp_pop_garbage(&SP, &g)) sp_free_garbage(&g);
}

/* The engine as a fresh load leaves it, the output started at RATE. */
static void fresh(void) {
    if (atomic_load(&OUT.streams) > 0) event(MIO_OUT, 1, MAI_EVENT_STOPPED, RATE, 2);
    collect();
    push((sp_cmd){.type = SP_CMD_RESET});
    sp_drain(&SP, false);
    collect();
    n_evs = 0;
    event(MIO_OUT, 1, MAI_EVENT_STARTED, RATE, 2);
    atomic_store(&SP.clock_seq, 0); /* no clock yet */
}

/* ── Tests ───────────────────────────────────────────────────────────────── */

static void test_register(void) {
    printf("registration\n");
    CHECK(mio_register() == MAI_OK && proc(MIO_OUT) && proc(MIO_MIC), "both processors registered");
    const mai_processor *o = proc(MIO_OUT), *m = proc(MIO_MIC);
    CHECK(o->render && !o->capture && o->stream_event && !m->render && m->capture && m->stream_event,
          "magpie_out renders, magpie_mic captures, both hear their stream's events");
}

static void test_output_events(void) {
    printf("output stream events\n");
    /* Before any stream: control calls drain themselves at the default rate. */
    CHECK(OUT.drains && !atomic_load(&OUT.running) && SP.rate == MIO_DEFAULT_RATE && mio_rate() == MIO_DEFAULT_RATE,
          "no stream: the control path renders at %d Hz", MIO_DEFAULT_RATE);
    push((sp_cmd){.type = SP_CMD_TEMPO, .u.value = 90});
    event(MIO_OUT, 11, MAI_EVENT_STARTED, 44100, 2);
    CHECK(!OUT.drains && atomic_load(&OUT.running) && SP.rate == 44100 && atomic_load(&OUT.rate) == 44100 &&
              atomic_load(&OUT.stream) == 11 && atomic_load(&OUT.starts) == 1,
          "STARTED: the stream renders at its rate (44100), the queue applied first");
    CHECK(SP.seq.bpm == 90, "a command queued before STARTED took effect (tempo %.0f)", SP.seq.bpm);

    event(MIO_OUT, 11, MAI_EVENT_STOPPED, 44100, 2);
    CHECK(OUT.drains && !atomic_load(&OUT.running), "STOPPED: control calls drain again, live calls are refused");
    push((sp_cmd){.type = SP_CMD_TEMPO, .u.value = 100});
    CHECK(sp_pop_cmd(&SP, &(sp_cmd){0}), "(a command waits for the next drain)");

    /* A reopen on a new route at 48 kHz. */
    event(MIO_OUT, 11, MAI_EVENT_STARTED, RATE, 2);
    CHECK(SP.rate == RATE && atomic_load(&OUT.starts) == 2 && atomic_load(&OUT.running), "a reopen at %d Hz", RATE);

    /* A second output stream: neither renders while both run. */
    int64_t skipped = atomic_load(&OUT.skipped);
    event(MIO_OUT, 12, MAI_EVENT_STARTED, 96000, 2);
    render_at(T0_NS, 0);
    CHECK(SP.rate == RATE && atomic_load(&OUT.stream) == 11 && atomic_load(&OUT.skipped) == skipped + 1,
          "a second stream changes nothing and both play silence");
    int64_t frame = SP.frame;
    event(MIO_OUT, 12, MAI_EVENT_STOPPED, 96000, 2);
    render_at(T0_NS + BLOCK_NS, 0);
    CHECK(atomic_load(&OUT.running) && SP.frame == frame + BLOCK, "once it stops, the first renders again");

    /* Not stereo (never asked for): silence, counted. */
    mai_time mono = {0, T0_NS, 0, RATE, 1};
    proc(MIO_OUT)->render(NULL, out_buf, BLOCK, &mono);
    CHECK(SP.frame == frame + BLOCK && atomic_load(&OUT.skipped) == skipped + 2, "a mono buffer is left silent");
    event(MIO_OUT, 11, MAI_EVENT_STOPPED, RATE, 2);
    CHECK(atomic_load(&OUT.streams) == 0, "every STARTED had its STOPPED");
}

static void test_clock(void) {
    printf("the engine clock from present_ns\n");
    fresh();
    int64_t cf, cns;
    render_at(T0_NS, 0);
    CHECK(!sp_get_clock(&SP, &cf, &cns), "no presentation time yet: no clock");
    int64_t f0 = SP.frame;
    render_at(T0_NS + BLOCK_NS, T0_NS + BLOCK_NS + OUT_LATENCY_NS);
    CHECK(sp_get_clock(&SP, &cf, &cns) && cf == f0 && cns == T0_NS + BLOCK_NS + OUT_LATENCY_NS,
          "the block's first engine frame (%lld) at its presentation time", (long long)cf);
    CHECK(atomic_load(&SP.latency_frames) == OUT_LATENCY_NS * RATE / 1000000000LL,
          "latency stand-in %lld frames (30 ms)", (long long)atomic_load(&SP.latency_frames));
    /* Refreshed every 20 ms, not every block. */
    for (int k = 2; k < 5; k++) render_at(T0_NS + k * BLOCK_NS, T0_NS + k * BLOCK_NS + OUT_LATENCY_NS + 777);
    sp_get_clock(&SP, &cf, &cns);
    CHECK(cf == f0, "not refreshed within 20 ms");
    int64_t f5 = SP.frame;
    render_at(T0_NS + 5 * BLOCK_NS + BLOCK_NS, T0_NS + 6 * BLOCK_NS + OUT_LATENCY_NS + 777);
    sp_get_clock(&SP, &cf, &cns);
    CHECK(cf == f5 && cns == T0_NS + 6 * BLOCK_NS + OUT_LATENCY_NS + 777, "refreshed 20 ms on (frame %lld)",
          (long long)cf);
    /* A reopen refreshes at its first presentation time. */
    event(MIO_OUT, 1, MAI_EVENT_STOPPED, RATE, 2);
    event(MIO_OUT, 1, MAI_EVENT_STARTED, RATE, 2);
    int64_t f7 = SP.frame;
    render_at(T0_NS + 7 * BLOCK_NS, T0_NS + 9 * BLOCK_NS);
    sp_get_clock(&SP, &cf, &cns);
    CHECK(cf == f7 && cns == T0_NS + 9 * BLOCK_NS, "after a reopen, at once");
    CHECK(mio_heard_ns(f7 + 480) == T0_NS + 9 * BLOCK_NS + 10000000LL, "frame_time: 480 frames on is 10 ms later");
}

/* The renderer's frames vs the presentation schedule: engine frame F is
 * heard at T0 + F / RATE + OUT_LATENCY (block-aligned). */
static int64_t heard_at(int64_t f, int64_t f_base) {
    return T0_NS + OUT_LATENCY_NS + (int64_t)((double)(f - f_base) * 1e9 / RATE);
}

static void test_sequenced_events(void) {
    printf("sequenced events on their presentation time\n");
    fresh();
    int16_t *data = calloc(64, sizeof(int16_t));
    for (int i = 0; i < 64; i++) data[i] = 16000;
    push((sp_cmd){.type = SP_CMD_SAMPLE, .u.sample = {0, sp_sample_wrap(data, 64, 1, RATE)}});
    push((sp_cmd){.type = SP_CMD_PAD, .pad = 0, .u.pad = {.slot = 0, .gain = 1.0f, .mode = SP_ONE_SHOT, .root = 60}});
    sp_pattern *p = sp_pattern_new(16);
    p->id = 1;
    p->length = 16 * SP_STEP;
    for (int i = 0; i < 16; i++) p->steps[i] = (sp_step){i * SP_STEP, 0, 100, -1};
    push((sp_cmd){.type = SP_CMD_PATTERN, .u.pattern = {p, false}});
    push((sp_cmd){.type = SP_CMD_TEMPO, .u.value = 120});
    push((sp_cmd){.type = SP_CMD_PLAY});
    int64_t base = SP.frame;
    for (int k = 0; k < 200; k++) {
        render_at(T0_NS + k * BLOCK_NS, T0_NS + k * BLOCK_NS + OUT_LATENCY_NS);
        collect();
    }
    int heads = 0, off = 0;
    for (int i = 0; i < n_evs; i++) {
        if (evs[i].type != SP_EV_PLAYHEAD) continue;
        heads++;
        /* 120 bpm: a 16th is 6000 frames, 125 ms. */
        int64_t want = heard_at(base, base) + (int64_t)evs[i].a * 125000000LL;
        if (evs[i].frame != base + evs[i].a * 6000 || mio_heard_ns(evs[i].frame) != want) off++;
    }
    CHECK(heads == 8 && off == 0, "%d steps, each on its frame and heard at its step time (%d off)", heads, off);

    /* A live trigger, called when engine frame base + 3·6000 + 2400 was
     * being heard: step 3, 9.6 ticks late → tick 10. */
    n_evs = 0;
    int64_t heard = base + 3 * 6000 + 2400;
    push((sp_cmd){.type = SP_CMD_TRIGGER, .pad = 0, .vel = 99, .t_ns = heard_at(heard, base)});
    render_at(T0_NS + 200 * BLOCK_NS, T0_NS + 200 * BLOCK_NS + OUT_LATENCY_NS);
    collect();
    const sp_event *h = NULL;
    for (int i = 0; i < n_evs && !h; i++)
        if (evs[i].type == SP_EV_HIT) h = &evs[i];
    CHECK(h && h->a == 3 && h->b == 10 && h->vel == 99, "a live hit is stamped where it was heard: step %d tick %d",
          h ? h->a : -1, h ? h->b : 99);
    push((sp_cmd){.type = SP_CMD_STOP});
}

/* The mic: opening (as nif_input_open leaves it), STARTED, capture, gone. */
static void open_mic(int64_t id) {
    pthread_mutex_lock(&IN.lock);
    atomic_store(&IN.gen, id);
    atomic_store(&IN.source, SRC_MIC);
    atomic_store(&IN.status, IN_OPENING);
    atomic_store(&IN.callbacks, 0);
    atomic_store(&IN.clock_misses, 0);
    pthread_mutex_unlock(&IN.lock);
}

static void close_mic(void) {
    pthread_mutex_lock(&IN.lock);
    atomic_store(&IN.status, IN_CLOSED);
    rc_gate_shut(&IN.gate);
    if (IN.armed) {
        rc_finish(&REC);
        rc_free_buffers(&REC);
        IN.armed = false;
    }
    atomic_store(&IN.mic_stream, 0);
    atomic_store(&IN.source, SRC_NONE);
    atomic_fetch_add(&IN.gen, 1);
    pthread_mutex_unlock(&IN.lock);
}

static float in_buf[BLOCK];

static void capture_at(int64_t host, int64_t present, int64_t first_input_frame) {
    fake_now = host;
    for (int i = 0; i < BLOCK; i++) in_buf[i] = (float)((first_input_frame + i) % 1000) / 1000.0f;
    mai_time t = {0, host, present, RATE, 1};
    proc(MIO_MIC)->capture(NULL, in_buf, BLOCK, &t);
}

static void test_mic_events(void) {
    printf("mic stream events and capture\n");
    /* Not opening: a STARTED feeds nothing. */
    event(MIO_MIC, 21, MAI_EVENT_STARTED, RATE, 1);
    CHECK(atomic_load(&IN.status) == IN_CLOSED && atomic_load(&IN.mic_stream) == 0, "no input opening: ignored");

    open_mic(5);
    capture_at(T0_NS, T0_NS - IN_LATENCY_NS, 0);
    CHECK(atomic_load(&IN.callbacks) == 0, "OPENING: the gate is shut, nothing recorded");
    event(MIO_MIC, 21, MAI_EVENT_STARTED, 44100, 1);
    CHECK(atomic_load(&IN.status) == IN_OPEN && REC.rate == 44100 && REC.channels == 1 &&
              atomic_load(&IN.mic_stream) == 21 && atomic_load(&IN.news) == IN_NEWS_STARTED,
          "STARTED: the input is open at the stream's rate (44100), mono; the owner is told");
    atomic_store(&IN.news, IN_NEWS_NONE);

    /* Without a presentation time: "just now", a clock miss. */
    capture_at(T0_NS + BLOCK_NS, 0, 0);
    int64_t want = T0_NS + BLOCK_NS - (int64_t)(BLOCK * 1e9 / 44100) + (int64_t)(BLOCK * 1e9 / 44100);
    CHECK(atomic_load(&IN.callbacks) == 1 && atomic_load(&IN.clock_misses) == 1 &&
              llabs(atomic_load(&IN.newest_ns) - want) <= 1,
          "no capture time: its last frame counts as captured at the callback (a clock miss)");
    capture_at(T0_NS + 2 * BLOCK_NS, T0_NS + 2 * BLOCK_NS - IN_LATENCY_NS, BLOCK);
    CHECK(atomic_load(&IN.clock_misses) == 1 &&
              atomic_load(&IN.newest_ns) == T0_NS + 2 * BLOCK_NS - IN_LATENCY_NS + (int64_t)(BLOCK * 1e9 / 44100),
          "with one: stamped with it");

    /* Another stream's STOPPED is no news; the open mic's is. */
    event(MIO_MIC, 99, MAI_EVENT_STOPPED, 44100, 1);
    CHECK(atomic_load(&IN.status) == IN_OPEN, "another stream's STOPPED: ignored");
    event(MIO_MIC, 21, MAI_EVENT_STOPPED, 44100, 1);
    CHECK(atomic_load(&IN.status) == IN_CLOSED && atomic_load(&IN.news) == IN_NEWS_LOST &&
              atomic_load(&IN.gate.open) == 0 && atomic_load(&IN.mic_stream) == 0,
          "the mic's STOPPED while open: closed, the owner is told (disconnected)");
    atomic_store(&IN.news, IN_NEWS_NONE);
    event(MIO_MIC, 21, MAI_EVENT_STARTED, 44100, 1);
    capture_at(T0_NS + 3 * BLOCK_NS, T0_NS, 0);
    CHECK(atomic_load(&IN.status) == IN_CLOSED && atomic_load(&IN.callbacks) == 2 &&
              atomic_load(&IN.news) == IN_NEWS_NONE,
          "the plugin's reopen after that feeds nothing");
    close_mic();

    /* Closed by the owner before its stream: the STOPPED that follows is no news. */
    open_mic(7);
    event(MIO_MIC, 22, MAI_EVENT_STARTED, RATE, 1);
    atomic_store(&IN.news, IN_NEWS_NONE);
    close_mic();
    event(MIO_MIC, 22, MAI_EVENT_STOPPED, RATE, 1);
    CHECK(atomic_load(&IN.news) == IN_NEWS_NONE, "closed first, then its stream: no news");
}

/* The count-in through both streams: output heard OUT_LATENCY after its
 * callback, input captured IN_LATENCY before its own; the input hears the
 * engine frame being presented when it is captured (each input sample is
 * that frame's number, mod 1000). The take must start on the downbeat. */
static void test_count_in_through_streams(void) {
    printf("count-in through both streams (the take starts on the downbeat as heard)\n");
    fresh();
    open_mic(9);
    event(MIO_MIC, 31, MAI_EVENT_STARTED, RATE, 1);
    atomic_store(&IN.news, IN_NEWS_NONE);
    push((sp_cmd){.type = SP_CMD_TEMPO, .u.value = 111});

    int64_t base = SP.frame, until = -1;
    bool armed = false, told = false;
    for (int k = 0; k < 1200; k++) {
        int64_t host = T0_NS + k * BLOCK_NS;
        if (!armed && k == 50) {
            pthread_mutex_lock(&IN.lock);
            armed = rc_arm(&REC, RC_AT_TIME, 10 * RATE, 0, 0, RATE / 2);
            IN.armed = armed;
            pthread_mutex_unlock(&IN.lock);
            push((sp_cmd){.type = SP_CMD_COUNT_IN, .u.count_in = {atomic_load(&REC.gen), 4}});
        }
        render_at(host, host + OUT_LATENCY_NS);
        /* Input frame p is captured at T0 − IN_LATENCY + p / RATE; it
         * hears the engine frame presented then. */
        int64_t p = (int64_t)k * BLOCK;
        int64_t heard_frame = base + p - (OUT_LATENCY_NS + IN_LATENCY_NS) * RATE / 1000000000LL;
        for (int i = 0; i < BLOCK; i++) {
            int64_t f = heard_frame + i;
            in_buf[i] = f < 0 ? 0.0f : (float)(f % 1000) / 1000.0f;
        }
        fake_now = host;
        mai_time t = {0, host, host - IN_LATENCY_NS, RATE, 1};
        proc(MIO_MIC)->capture(NULL, in_buf, BLOCK, &t);
        /* The event thread. */
        sp_event ev;
        while (sp_pop_event(&SP, &ev))
            if (!told && ev.type == SP_EV_COUNT_IN) {
                until = ev.until;
                rc_start_at(&REC, (uint32_t)ev.a, mio_heard_ns(ev.until));
                told = true;
            }
        collect();
    }
    int64_t frames = atomic_load(&REC.frames), bad = 0;
    for (int64_t i = 0; i < frames && i < 4800; i++)
        if (lrintf(REC.buf[i] * 1000.0f) % 1000 != (until + i) % 1000) bad++;
    CHECK(told && frames > 4800 && bad == 0,
          "recording from the downbeat (engine frame %lld): its first frame is the one heard then (%lld of 4800 off)",
          (long long)until, (long long)bad);
    close_mic();
}

static void test_import_chunk(void) {
    printf("import chunks\n");
    enum { FRAMES = 4096 + 1000, CH = 3 };
    float *in = malloc(sizeof(float) * FRAMES * CH);
    for (int f = 0; f < FRAMES; f++)
        for (int c = 0; c < CH; c++) in[f * CH + c] = (float)sin(f * 0.001 * (c + 1)) * (c == 2 ? 9.0f : 0.7f);
    in[300 * CH] = 1.5f;   /* clipped */
    in[301 * CH + 1] = -2.0f;
    in[302 * CH] = NAN;
    float *out = malloc(sizeof(float) * FRAMES * 2);
    uint8_t whole[64], a[64], b[64];
    mio_import_chunk((const uint8_t *)in, FRAMES, CH, 2, out, whole);
    CHECK(out[300 * 2] == 1.0f && out[301 * 2 + 1] == -1.0f && out[302 * 2] == 0.0f && out[600 * 2] == in[600 * CH],
          "the first two channels, clipped to ±1 (NaN silenced)");
    /* Peaks as sp_peaks gives them for the same audio in 16 bit. */
    int16_t *pcm = sp_from_f32((const uint8_t *)out, FRAMES, 2, 2);
    uint8_t want[64];
    sp_peaks(pcm, FRAMES, 2, want);
    int differ = 0;
    for (int i = 0; i < sp_peak_count(FRAMES); i++) differ += abs((int)want[i] - (int)whole[i]) > 1;
    CHECK(sp_peak_count(FRAMES) == 20 && differ == 0, "peaks match the sampler's (within one step)");
    /* A 4096-frame chunk then the rest: the same peaks. */
    float *o2 = malloc(sizeof(float) * FRAMES * 2);
    mio_import_chunk((const uint8_t *)in, 4096, CH, 2, o2, a);
    mio_import_chunk((const uint8_t *)(in + 4096 * CH), FRAMES - 4096, CH, 2, o2 + 4096 * 2, b);
    CHECK(memcmp(a, whole, 16) == 0 && memcmp(b, whole + 16, 4) == 0 &&
              memcmp(o2, out, sizeof(float) * FRAMES * 2) == 0,
          "chunks of whole peak blocks concatenate into the file's");
    free(pcm);
    free(in);
    free(out);
    free(o2);
}

/* ── The loader's queue (load_queue.c) ───────────────────────────────────── */

typedef struct {
    lq_job q;
    const char *name;
    int value;
} test_job;

static lq_queue LQ;
static const char *taken[8];
static _Atomic int n_taken;

static void *taker(void *arg) {
    int n = *(int *)arg;
    for (int i = 0; i < n; i++) {
        test_job *j = (test_job *)lq_take(&LQ, 5000);
        taken[atomic_load(&n_taken)] = j->name;
        atomic_fetch_add(&n_taken, 1);
    }
    return NULL;
}

static void fill_value(lq_job *q, void *arg) { ((test_job *)q)->value = *(int *)arg; }

static void sleep_ms(int ms) {
    struct timespec ts = {0, ms * 1000000L};
    nanosleep(&ts, NULL);
}

static void test_load_queue(void) {
    printf("the loader's queue (load order kept across decodes)\n");
    lq_init(&LQ);
    /* A file load (pending, ticket 1), then a PCM load of the same id: the
     * PCM load waits for the file's turn. */
    test_job a = {.q = {.request = 1, .pending = true}, .name = "file"};
    test_job b = {.name = "pcm"};
    lq_push(&LQ, &a.q);
    lq_push(&LQ, &b.q);
    pthread_t t;
    int two = 2, three = 3;
    atomic_store(&n_taken, 0);
    pthread_create(&t, NULL, taker, &two);
    sleep_ms(50);
    CHECK(atomic_load(&n_taken) == 0, "the PCM load waits behind the pending file load");
    CHECK(lq_fill(&LQ, 1, fill_value, &three), "the file's decode hands its result over");
    pthread_join(t, NULL);
    CHECK(n_taken == 2 && strcmp(taken[0], "file") == 0 && strcmp(taken[1], "pcm") == 0 && a.value == 3 &&
              !a.q.failure,
          "they finish in the order they were made: %s, then %s", n_taken > 0 ? taken[0] : "-",
          n_taken > 1 ? taken[1] : "-");
    CHECK(!lq_fill(&LQ, 1, fill_value, &three) && !lq_fill(&LQ, 99, fill_value, &three),
          "a finished or unknown ticket fills nothing");

    /* A decode that finishes before its turn: no wait. */
    test_job c = {.q = {.request = 2, .pending = true}, .name = "early"};
    lq_push(&LQ, &c.q);
    CHECK(lq_fill(&LQ, 2, fill_value, &two), "filled while still queued");
    CHECK(lq_take(&LQ, 0) == &c.q && c.value == 2 && !c.q.failure, "taken at once");

    /* A decode nobody finishes: given up as decode_error, and too late after. */
    test_job d = {.q = {.request = 3, .pending = true}, .name = "lost"};
    lq_push(&LQ, &d.q);
    lq_job *got = lq_take(&LQ, 30);
    CHECK(got == &d.q && !d.q.pending && d.q.failure && strcmp(d.q.failure, "decode_error") == 0,
          "a pending load nobody finishes fails as decode_error after the timeout");
    CHECK(!lq_fill(&LQ, 3, fill_value, &two), "its late result fills nothing");
}

int main(void) {
    mio_init();
    test_register();
    test_output_events();
    test_clock();
    test_sequenced_events();
    test_mic_events();
    test_count_in_through_streams();
    test_import_chunk();
    test_load_queue();
    collect();
    printf("%s: %d failure%s\n", failures ? "FAILED" : "passed", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
