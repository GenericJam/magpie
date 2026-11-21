/*
 * c_src/magpie_io.c — Magpie's two mob_audio_io processors and the state
 * they share with the NIF (c_src/magpie_audio.c):
 *
 *   "magpie_out"   render: the sampler (sp_render) on the output stream.
 *                  Its stream events hand the renderer's role between the
 *                  stream and the control path (STARTED: the stream renders
 *                  at its rate; STOPPED: control calls drain the queue
 *                  themselves), and every MIO_CLOCK_PERIOD_NS it maps the
 *                  engine frame it is about to render onto the block's
 *                  presentation time (mai_time.present_ns): the engine
 *                  clock (sp_set_clock) that frame_time, the count-in, live
 *                  record and MIDI out go by.
 *   "magpie_mic"   capture: the microphone into the recorder (recorder.c),
 *                  each block stamped with when it was captured (present_ns,
 *                  "just now" until the plugin knows). Its STARTED makes
 *                  the input that is opening OPEN; a STOPPED of the open
 *                  mic (the device went, a call took the session) closes
 *                  it, and the NIF's event thread tells the owner
 *                  (`disconnected`).
 *
 * mob_audio_io (deps/mob_audio_io) owns the streams: AAudio on Android,
 * RemoteIO on iOS; Magpie.Audio.Native.Io opens and closes them. Plain C,
 * no erl_nif and no platform API: c_src/magpie_audio.c includes it for the
 * phones, c_src/test/io_host.c for the host harness (which supplies
 * mai_now_ns).
 *
 * Threads: render and capture run on the plugin's audio threads and take
 * no lock; the stream events run on a normal thread (the opener's NIF call,
 * the plugin's event thread), never beside a callback of their stream, and
 * take OUT.ctl / IN.lock. Lock order (the NIF's too): IN.lock → OUT.ctl →
 * OUT.push.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "../deps/mob_audio_io/priv/include/mob_audio_io.h"

#include "sampler.c"
#include "recorder.c"

#define MIO_OUT "magpie_out"
#define MIO_MIC "magpie_mic"
#define MIO_DEFAULT_RATE 48000
#define MIO_CLOCK_PERIOD_NS 20000000LL /* how often the render refreshes the engine clock */

enum { SRC_NONE, SRC_MIC, SRC_APPS };
enum { IN_CLOSED, IN_OPENING, IN_OPEN };
/* What the NIF's event thread owes the owner about the input (IN.news). */
enum { IN_NEWS_NONE, IN_NEWS_STARTED, IN_NEWS_LOST };

static sp_engine SP;
static rc_recorder REC;

/* The output and the renderer's role. */
static struct {
    /* The renderer's role (`drains`); in the NIF also the owner and the
     * sample table (magpie_audio.c). */
    pthread_mutex_t ctl;
    /* Serialises producers into SP's command queue. */
    pthread_mutex_t push;
    bool drains; /* under ctl: no stream renders, control calls drain the queue */

    _Atomic bool running; /* a stream renders: live calls go in */
    _Atomic int rate;     /* the stream's rate; 0 before the first */
    /* Output streams started and not stopped. Only one renders (sp_render
     * isn't reentrant): with two, both play silence. */
    _Atomic int streams;
    _Atomic int32_t stream; /* the last one started */
    _Atomic int64_t starts; /* STARTED events: the first open and every reopen */

    /* The render's own: the next clock refresh (host ns; 0: at once). */
    int64_t clock_next;

    /* Callback timing (relaxed atomics, written by the render). */
    _Atomic int64_t cb_count, cb_ns_sum, cb_ns_max, cb_gap_max, cb_last_start, cb_frames;
    _Atomic int64_t engine_frame; /* SP.frame after the last render */
    _Atomic int64_t skipped;      /* renders left silent: two streams, or not stereo */
} OUT;

/* The input (the mic, or other apps through plugins/magpie_capture) into
 * the recorder. One input at a time; `lock` covers its lifecycle and the
 * recorder's buffers. */
static struct {
    pthread_mutex_t lock;
    _Atomic int source, status;
    /* The input's id: bumps on every open (the new input's id, which the
     * owner's messages and Kotlin's calls carry) and every close. */
    _Atomic int64_t gen;
    /* Open for the input's id while it is IN_OPEN: its producer (the mic's
     * capture, Kotlin's read thread) writes to REC only through it. */
    rc_gate gate;
    /* The mic stream feeding REC (its STARTED made the input OPEN); 0 none. */
    _Atomic int32_t mic_stream;
    /* IN_NEWS_*: the event thread tells the owner, then clears it. */
    _Atomic int news;

    _Atomic int64_t callbacks, clock_misses, newest_ns;

    /* The recording, under lock (the NIF's). */
    bool armed, count_in, start_sent, full_sent;
    int64_t peaks_sent, next_meter;
} IN;

/* Once, before anything else (the NIF's load). */
static void mio_init(void) {
    pthread_mutex_init(&OUT.ctl, NULL);
    pthread_mutex_init(&OUT.push, NULL);
    pthread_mutex_init(&IN.lock, NULL);
    sp_init(&SP, MIO_DEFAULT_RATE);
    OUT.drains = true;
}

static bool mio_push(const sp_cmd *c) {
    pthread_mutex_lock(&OUT.push);
    bool ok = sp_push(&SP, c);
    pthread_mutex_unlock(&OUT.push);
    return ok;
}

/* The engine's rate: the stream's, or the default before one ran. */
static int mio_rate(void) {
    int rate = atomic_load(&OUT.rate);
    return rate > 0 ? rate : MIO_DEFAULT_RATE;
}

/* When engine frame `frame` is heard (mai_now_ns): from the engine clock,
 * or, before the first presentation time, from the frames queued ahead of
 * what is heard now. */
static int64_t mio_heard_ns(int64_t frame) {
    int rate = mio_rate();
    int64_t cf, cns;
    if (sp_get_clock(&SP, &cf, &cns) && atomic_load(&OUT.rate) > 0)
        return cns + (int64_t)((double)(frame - cf) * 1e9 / rate);
    int64_t ahead = frame - atomic_load(&OUT.engine_frame) + atomic_load(&SP.latency_frames);
    return mai_now_ns() + (int64_t)((double)ahead * 1e9 / rate);
}

/* ── "magpie_out" ─────────────────────────────────────────────────────────── */

static void mio_render(void *ctx, float *out, int32_t frames, const mai_time *t) {
    (void)ctx;
    int64_t t0 = t->host_ns;
    int64_t last = atomic_load_explicit(&OUT.cb_last_start, memory_order_relaxed);
    if (last > 0 && t0 - last > atomic_load_explicit(&OUT.cb_gap_max, memory_order_relaxed))
        atomic_store_explicit(&OUT.cb_gap_max, t0 - last, memory_order_relaxed);
    atomic_store_explicit(&OUT.cb_last_start, t0, memory_order_relaxed);
    if (atomic_load_explicit(&OUT.streams, memory_order_relaxed) != 1 || t->channels != 2) {
        atomic_fetch_add_explicit(&OUT.skipped, 1, memory_order_relaxed);
        return;
    }

    /* SP.frame is this block's first frame: heard at present_ns. */
    if (t->present_ns > 0 && t0 >= OUT.clock_next) {
        sp_set_clock(&SP, SP.frame, t->present_ns);
        int64_t ahead = t->present_ns - t0;
        if (ahead > 0 && t->rate > 0)
            atomic_store_explicit(&SP.latency_frames, ahead * t->rate / 1000000000LL, memory_order_relaxed);
        OUT.clock_next = t0 + MIO_CLOCK_PERIOD_NS;
    }

    sp_render(&SP, out, frames);

    int64_t dt = mai_now_ns() - t0;
    atomic_fetch_add_explicit(&OUT.cb_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&OUT.cb_ns_sum, dt, memory_order_relaxed);
    atomic_fetch_add_explicit(&OUT.cb_frames, frames, memory_order_relaxed);
    if (dt > atomic_load_explicit(&OUT.cb_ns_max, memory_order_relaxed))
        atomic_store_explicit(&OUT.cb_ns_max, dt, memory_order_relaxed);
    atomic_store_explicit(&OUT.engine_frame, SP.frame, memory_order_relaxed);
}

/* STARTED (open, reopen after a lost device or a route change): the stream
 * renders from its first callback, at its rate; what control calls queued
 * meanwhile is applied first. STOPPED (closed, lost, interrupted): control
 * calls drain the queue again. A second output stream changes nothing here
 * (and silences both while it runs). */
static void mio_out_event(void *ctx, int32_t stream, int32_t event, const mai_time *t) {
    (void)ctx;
    if (event == MAI_EVENT_STARTED) {
        int rate = t->rate > 0 ? t->rate : MIO_DEFAULT_RATE;
        pthread_mutex_lock(&OUT.ctl);
        if (atomic_fetch_add(&OUT.streams, 1) == 0) {
            sp_cmd c = {.type = SP_CMD_RATE, .u.rate = rate};
            mio_push(&c);
            sp_drain(&SP, false);
            OUT.drains = false;
            atomic_store(&OUT.rate, rate);
            OUT.clock_next = 0;
            atomic_store(&OUT.stream, stream);
            atomic_fetch_add(&OUT.starts, 1);
            atomic_store(&OUT.running, true);
        }
        pthread_mutex_unlock(&OUT.ctl);
    } else if (event == MAI_EVENT_STOPPED) {
        pthread_mutex_lock(&OUT.ctl);
        if (atomic_load(&OUT.streams) > 0 && atomic_fetch_sub(&OUT.streams, 1) == 1) {
            atomic_store(&OUT.running, false);
            OUT.drains = true;
            sp_drain(&SP, false);
        }
        pthread_mutex_unlock(&OUT.ctl);
    }
}

/* ── "magpie_mic" ─────────────────────────────────────────────────────────── */

/* Frame k of the stream is the k-th the capture is handed; a block's first
 * frame was captured at present_ns (before the plugin knows: "just now",
 * counted as a clock miss). Only the open mic's input writes (the gate). */
static void mio_capture(void *ctx, const float *in, int32_t frames, const mai_time *t) {
    (void)ctx;
    if (frames <= 0 || !rc_enter(&IN.gate, atomic_load_explicit(&IN.gen, memory_order_relaxed))) return;
    const int rate = REC.rate;
    int64_t t0 = t->present_ns;
    if (t0 <= 0) {
        t0 = t->host_ns - (int64_t)((double)frames * 1e9 / rate);
        atomic_fetch_add_explicit(&IN.clock_misses, 1, memory_order_relaxed);
    }
    rc_write(&REC, in, frames, t0);
    rc_leave(&IN.gate);
    atomic_fetch_add_explicit(&IN.callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&IN.newest_ns, t0 + (int64_t)((double)frames * 1e9 / rate), memory_order_relaxed);
}

/* STARTED: the mic input that is opening is open, in the stream's format
 * (a later STARTED, a reopen after the input closed, feeds nothing).
 * STOPPED of the stream feeding the open input: it is gone. */
static void mio_mic_event(void *ctx, int32_t stream, int32_t event, const mai_time *t) {
    (void)ctx;
    pthread_mutex_lock(&IN.lock);
    if (event == MAI_EVENT_STARTED) {
        if (atomic_load(&IN.source) == SRC_MIC && atomic_load(&IN.status) == IN_OPENING && t->rate > 0 &&
            t->channels >= 1 && t->channels <= 2) {
            rc_init(&REC, t->rate, t->channels);
            atomic_store(&IN.mic_stream, stream);
            atomic_store(&IN.status, IN_OPEN);
            rc_gate_open(&IN.gate, atomic_load(&IN.gen));
            atomic_store(&IN.news, IN_NEWS_STARTED);
        }
    } else if (event == MAI_EVENT_STOPPED && stream == atomic_load(&IN.mic_stream)) {
        atomic_store(&IN.mic_stream, 0);
        if (atomic_load(&IN.source) == SRC_MIC && atomic_load(&IN.status) == IN_OPEN) {
            atomic_store(&IN.status, IN_CLOSED);
            rc_gate_shut(&IN.gate);
            atomic_store(&IN.news, IN_NEWS_LOST);
        }
    }
    pthread_mutex_unlock(&IN.lock);
}

/* Register both; MAI_OK or the first error (the plugin's ABI must match
 * the header's). */
static int32_t mio_register(void) {
    if (mai_abi_version() != MAI_ABI_VERSION) return MAI_ERR_INVALID;
    static const mai_processor out = {mio_render, NULL, mio_out_event};
    static const mai_processor mic = {NULL, mio_capture, mio_mic_event};
    int32_t rc = mai_register(MIO_OUT, &out, NULL);
    return rc == MAI_OK ? mai_register(MIO_MIC, &mic, NULL) : rc;
}

/* ── Import ───────────────────────────────────────────────────────────────── */

/* A decoded chunk for the library and the loader: `frames` frames of
 * `channels` interleaved native-endian floats (any alignment) into `out`
 * as the first `keep` channels, clipped to ±1, and their peaks
 * (sp_peak_count(frames) bytes, sp_peaks's scale) into `peaks`. Chunks
 * whose frames are multiples of SP_PEAK_FRAMES concatenate into the whole
 * file's peaks. */
static void mio_import_chunk(const uint8_t *in, int64_t frames, int channels, int keep, float *out, uint8_t *peaks) {
    int64_t n = sp_peak_count(frames);
    for (int64_t p = 0; p < n; p++) {
        float peak = 0;
        int64_t end = (p + 1) * SP_PEAK_FRAMES < frames ? (p + 1) * SP_PEAK_FRAMES : frames;
        for (int64_t f = p * SP_PEAK_FRAMES; f < end; f++)
            for (int c = 0; c < keep; c++) {
                float x;
                memcpy(&x, in + 4 * (f * channels + c), sizeof(x));
                x = x > 1.0f ? 1.0f : x < -1.0f ? -1.0f : x == x ? x : 0.0f;
                out[f * keep + c] = x;
                float a = fabsf(x);
                if (a > peak) peak = a;
            }
        int p16 = (int)lrintf(peak * 32768.0f);
        peaks[p] = (uint8_t)((p16 * 255 + 16384) / 32768);
    }
}
