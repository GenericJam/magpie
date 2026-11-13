/*
 * c_src/recorder.c — Magpie's recorder: takes input audio (the mic's AAudio
 * callback, or the other-apps capture thread) into a buffer of a fixed
 * maximum length, meters it, and starts the recording now, at the first
 * sound over a threshold (keeping a pre-roll), or at a given capture time
 * (the count-in's downbeat).
 *
 * Plain C, no Android and no erl_nif: c_src/magpie_audio.c includes it for
 * the phone, c_src/test/sampler_host.c for the host harness.
 *
 * Roles:
 *
 *   producer   rc_write, from the input's own thread (one at a time),
 *              between rc_enter and rc_leave of the input's gate. It never
 *              locks, allocates or frees; it may wait for nothing.
 *   control    rc_arm / rc_finish / rc_flush_peak, under the caller's lock.
 *              rc_arm allocates while the recorder is idle; rc_finish takes
 *              the state back to idle and waits out a producer that is
 *              inside rc_write, after which the buffers are the control
 *              side's to keep or free. rc_gate_open / rc_gate_shut let an
 *              input write and stop it, also under the caller's lock.
 *   readers    rc_take_level and the published counters (frames, peak
 *              bytes, where the recording started) from any thread; the
 *              peak bytes below `peak_bytes` are final.
 *   any        rc_start_at: an arm's start time (the count-in's downbeat),
 *              tagged with the arm's generation so a late one for an
 *              earlier arm never starts a later one.
 *
 * Time: `pos` counts input frames since the input opened. A frame's capture
 * time is `t0 + i / rate` for frame i of a block whose first frame was
 * captured at `t0` (CLOCK_MONOTONIC ns), so a count-in can start the
 * recording on the frame captured when its downbeat was heard.
 *
 * While waiting (for a sound, or for the downbeat), every frame also goes
 * into a ring of the last `ring_frames`: the pre-roll before a sound, and
 * the audio before a downbeat whose time arrived late.
 */

#include <math.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define RC_PEAK_FRAMES 256 /* frames per peak byte, as the sampler's peaks */
#define RC_FLOOR_DB -120.0

enum {
    RC_IDLE,       /* metering only */
    RC_WAIT_SOUND, /* armed: starts at the first frame at or over the threshold */
    RC_WAIT_TIME,  /* armed: starts at the frame captured at start_ns, once known */
    RC_RECORDING,
    RC_FULL, /* the maximum length is recorded; takes no more */
};

enum { RC_NOW, RC_ON_SOUND, RC_AT_TIME };

typedef struct {
    /* Set before a producer runs (the input's format). */
    int channels, rate;

    /* Set by rc_arm while idle, published by the state's store. */
    float *buf; /* max_frames × channels, interleaved */
    uint8_t *peaks;
    int64_t max_frames;
    float *ring; /* ring_frames × channels */
    int64_t ring_frames;
    float threshold; /* linear */
    int64_t pre_roll;

    _Atomic int state;
    _Atomic uint32_t gen;       /* bumps on every arm */
    _Atomic int64_t start_ns;   /* RC_WAIT_TIME: capture time to start at, for arm `start_gen` */
    _Atomic uint32_t start_gen; /* the arm start_ns belongs to; another arm's is no start time */
    _Atomic bool busy;          /* the producer is inside rc_write */

    /* Producer's own. */
    uint32_t seen_gen;
    int64_t pos;       /* input frames since the input opened */
    int64_t ring_fill; /* frames in the ring since this arm (≤ ring_frames) */
    int64_t done;      /* frames recorded */
    int64_t peak_done; /* peak bytes written */
    float peak_acc;
    int peak_n;

    /* Published (release) by the producer. */
    _Atomic int64_t frames;
    _Atomic int64_t peak_bytes;
    _Atomic int64_t started_at; /* input frame (pos) the recording starts at; −1 not yet */
    _Atomic int64_t trigger_at; /* the sound / the downbeat / the arm, as an input frame */

    _Atomic uint32_t level; /* largest |x| since rc_take_level, as float bits */
} rc_recorder;

static int64_t rc_peak_count(int64_t frames) { return (frames + RC_PEAK_FRAMES - 1) / RC_PEAK_FRAMES; }

static uint8_t rc_peak_byte(float peak) {
    float p = peak > 1.0f ? 1.0f : peak;
    return (uint8_t)lrintf(p * 255.0f);
}

/* The input's gate: which input may write (its id, 0 none) and how many
 * producers are inside. A producer whose input was closed (a stream that
 * wouldn't stop, a capture thread that outlived its join) is shut out
 * before it touches the recorder, so the next input's rc_init never runs
 * under it. Never reset while an input could still try it. */
typedef struct {
    _Atomic int64_t open;
    _Atomic int inside;
} rc_gate;

/* Producer: true when `id` is the open input; then rc_write, and rc_leave. */
static bool rc_enter(rc_gate *g, int64_t id) {
    atomic_fetch_add(&g->inside, 1);
    if (id != 0 && atomic_load(&g->open) == id) return true;
    atomic_fetch_sub(&g->inside, 1);
    return false;
}

static void rc_leave(rc_gate *g) { atomic_fetch_sub(&g->inside, 1); }

/* Control: input `id` (after rc_init for it) may write. */
static void rc_gate_open(rc_gate *g, int64_t id) { atomic_store(&g->open, id); }

/* Control: no input may write; returns once the producers inside have
 * left (each within one rc_write). */
static void rc_gate_shut(rc_gate *g) {
    atomic_store(&g->open, 0);
    while (atomic_load(&g->inside) > 0) sched_yield();
}

/* Before the input starts (its gate shut, so no producer runs). `r` was
 * zeroed once before its first use (static, or calloc). The arm generation
 * goes on counting, so an event about an earlier arm never matches a
 * later one; the start time isn't touched (rc_start_at may run meanwhile,
 * and an earlier arm's start is no later arm's). */
static void rc_init(rc_recorder *r, int rate, int channels) {
    r->channels = channels;
    r->rate = rate;
    r->buf = NULL;
    r->peaks = NULL;
    r->max_frames = 0;
    r->ring = NULL;
    r->ring_frames = 0;
    r->threshold = 0;
    r->pre_roll = 0;
    atomic_store(&r->state, RC_IDLE);
    atomic_store(&r->busy, false);
    r->seen_gen = atomic_load(&r->gen);
    r->pos = 0;
    r->ring_fill = 0;
    r->done = 0;
    r->peak_done = 0;
    r->peak_acc = 0;
    r->peak_n = 0;
    atomic_store(&r->frames, 0);
    atomic_store(&r->peak_bytes, 0);
    atomic_store(&r->started_at, -1);
    atomic_store(&r->trigger_at, -1);
    atomic_store(&r->level, 0);
}

static void rc_free_buffers(rc_recorder *r) {
    free(r->buf);
    free(r->peaks);
    free(r->ring);
    r->buf = NULL;
    r->peaks = NULL;
    r->ring = NULL;
}

/* Control, while idle: arm in `mode` for up to `max_frames`. `threshold`
 * (linear) and `pre_roll` (frames) for RC_ON_SOUND; `ring_frames` of
 * audio kept while waiting. False when out of memory (nothing changes). */
static bool rc_arm(rc_recorder *r, int mode, int64_t max_frames, float threshold, int64_t pre_roll,
                   int64_t ring_frames) {
    if (atomic_load(&r->state) != RC_IDLE || max_frames <= 0) return false;
    size_t ch = (size_t)r->channels;
    bool waits = mode != RC_NOW;
    float *buf = malloc((size_t)max_frames * ch * sizeof(float));
    uint8_t *peaks = malloc((size_t)rc_peak_count(max_frames));
    float *ring = waits && ring_frames > 0 ? malloc((size_t)ring_frames * ch * sizeof(float)) : NULL;
    if (!buf || !peaks || (waits && ring_frames > 0 && !ring)) {
        free(buf);
        free(peaks);
        free(ring);
        return false;
    }
    rc_free_buffers(r);
    r->buf = buf;
    r->peaks = peaks;
    r->ring = ring;
    r->ring_frames = ring ? ring_frames : 0;
    r->max_frames = max_frames;
    r->threshold = threshold;
    r->pre_roll = pre_roll < r->ring_frames ? pre_roll : r->ring_frames;
    atomic_store(&r->frames, 0);
    atomic_store(&r->peak_bytes, 0);
    atomic_store(&r->started_at, -1);
    atomic_store(&r->trigger_at, -1);
    atomic_fetch_add(&r->gen, 1);
    atomic_store(&r->state, mode == RC_NOW ? RC_RECORDING : mode == RC_ON_SOUND ? RC_WAIT_SOUND : RC_WAIT_TIME);
    return true;
}

/* Control: back to idle (metering only), after any producer inside
 * rc_write has left it; returns the state it was in. The buffers stay
 * (rc_free_buffers, or keep `buf`). */
static int rc_finish(rc_recorder *r) {
    int was = atomic_exchange(&r->state, RC_IDLE);
    while (atomic_load(&r->busy)) sched_yield();
    return was;
}

/* Any thread: arm `gen` (RC_WAIT_TIME) starts at the frame captured at
 * CLOCK_MONOTONIC `ns`. One caller at a time, in arm order (the event
 * thread, as the renderer reports the count-ins); a start for an arm that
 * is over is ignored by every later one. */
static void rc_start_at(rc_recorder *r, uint32_t gen, int64_t ns) {
    atomic_store_explicit(&r->start_ns, ns, memory_order_relaxed);
    atomic_store_explicit(&r->start_gen, gen, memory_order_release);
}

/* Control, after rc_finish: the last, partial peak byte. The number of
 * peak bytes. */
static int64_t rc_flush_peak(rc_recorder *r) {
    int64_t n = atomic_load(&r->peak_bytes);
    if (r->seen_gen == atomic_load(&r->gen) && r->peak_n > 0 && r->peaks && n < rc_peak_count(r->max_frames)) {
        r->peaks[n++] = rc_peak_byte(r->peak_acc);
        r->peak_n = 0;
        atomic_store(&r->peak_bytes, n);
    }
    return n;
}

/* The largest |x| since the last call (any thread). */
static float rc_take_level(rc_recorder *r) {
    uint32_t bits = atomic_exchange(&r->level, 0);
    float x;
    memcpy(&x, &bits, sizeof(x));
    return x;
}

static double rc_db(float x) { return x > 1e-6f ? 20.0 * log10((double)x) : RC_FLOOR_DB; }

/* ── Producer ─────────────────────────────────────────────────────────────── */

/* Positive floats order as their bits. */
static void rc_meter(rc_recorder *r, float peak) {
    uint32_t bits, cur = atomic_load_explicit(&r->level, memory_order_relaxed);
    memcpy(&bits, &peak, sizeof(bits));
    while (bits > cur && !atomic_compare_exchange_weak_explicit(&r->level, &cur, bits, memory_order_relaxed,
                                                                memory_order_relaxed)) {
    }
}

static float frame_peak(const float *f, int ch) {
    float m = 0;
    for (int c = 0; c < ch; c++) {
        float a = fabsf(f[c]);
        if (a > m) m = a;
    }
    return m;
}

/* Record `n` frames (fewer if the buffer fills). */
static void append(rc_recorder *r, const float *src, int64_t n) {
    const int ch = r->channels;
    int64_t room = r->max_frames - r->done;
    if (n > room) n = room;
    if (n <= 0) return;
    memcpy(r->buf + r->done * ch, src, (size_t)n * (size_t)ch * sizeof(float));
    for (int64_t i = 0; i < n; i++) {
        float m = frame_peak(src + i * ch, ch);
        if (m > r->peak_acc) r->peak_acc = m;
        if (++r->peak_n == RC_PEAK_FRAMES) {
            r->peaks[r->peak_done++] = rc_peak_byte(r->peak_acc);
            r->peak_acc = 0;
            r->peak_n = 0;
        }
    }
    r->done += n;
    atomic_store_explicit(&r->frames, r->done, memory_order_release);
    atomic_store_explicit(&r->peak_bytes, r->peak_done, memory_order_release);
    if (r->done == r->max_frames) {
        int expect = RC_RECORDING;
        atomic_compare_exchange_strong(&r->state, &expect, RC_FULL);
    }
}

static void ring_put(rc_recorder *r, const float *in, int n) {
    const int ch = r->channels;
    if (r->ring_frames <= 0) return;
    int64_t from = 0;
    if (n > r->ring_frames) from = n - r->ring_frames; /* only the newest fit */
    for (int64_t i = from; i < n;) {
        int64_t slot = (r->pos + i) % r->ring_frames;
        int64_t run = r->ring_frames - slot;
        if (run > n - i) run = n - i;
        memcpy(r->ring + slot * ch, in + i * ch, (size_t)run * (size_t)ch * sizeof(float));
        i += run;
    }
    r->ring_fill += n;
    if (r->ring_fill > r->ring_frames) r->ring_fill = r->ring_frames;
}

/* Start recording at input frame `start` (from wait state `from`), with
 * `trigger` the frame that set it off; this block is `in` (n frames from
 * r->pos). Frames before the block come from the ring, as far as it
 * reaches. */
static void start_at(rc_recorder *r, int from, int64_t start, int64_t trigger, const float *in, int n) {
    int64_t earliest = r->pos - r->ring_fill;
    if (start < earliest) start = earliest;
    int expect = from;
    if (!atomic_compare_exchange_strong(&r->state, &expect, RC_RECORDING)) return; /* finished meanwhile */
    atomic_store_explicit(&r->trigger_at, trigger, memory_order_relaxed);
    atomic_store_explicit(&r->started_at, start, memory_order_release);
    const int ch = r->channels;
    for (int64_t f = start; f < r->pos;) {
        int64_t slot = f % r->ring_frames;
        int64_t run = r->ring_frames - slot;
        if (run > r->pos - f) run = r->pos - f;
        append(r, r->ring + slot * ch, run);
        f += run;
    }
    int64_t off = start > r->pos ? start - r->pos : 0;
    if (off < n) append(r, in + off * ch, n - off);
}

/* The producer: `n` frames of input (interleaved, `channels` per frame),
 * the first captured at CLOCK_MONOTONIC `t0_ns`. */
static void rc_write(rc_recorder *r, const float *in, int n, int64_t t0_ns) {
    atomic_store(&r->busy, true);
    int state = atomic_load(&r->state);
    const int ch = r->channels;

    float peak = 0;
    for (int i = 0; i < n * ch; i++) {
        float a = fabsf(in[i]);
        if (a > peak) peak = a;
    }
    rc_meter(r, peak);

    if (state != RC_IDLE) {
        uint32_t gen = atomic_load(&r->gen);
        if (gen != r->seen_gen) {
            /* A new arm: this recording's producer state starts over. */
            r->seen_gen = gen;
            r->ring_fill = 0;
            r->done = 0;
            r->peak_done = 0;
            r->peak_acc = 0;
            r->peak_n = 0;
            if (state == RC_RECORDING) {
                atomic_store_explicit(&r->trigger_at, r->pos, memory_order_relaxed);
                atomic_store_explicit(&r->started_at, r->pos, memory_order_release);
            }
        }
    }

    switch (state) {
    case RC_WAIT_SOUND: {
        int hit = -1;
        if (peak >= r->threshold)
            for (int i = 0; i < n && hit < 0; i++)
                if (frame_peak(in + i * ch, ch) >= r->threshold) hit = i;
        if (hit < 0) ring_put(r, in, n);
        else start_at(r, RC_WAIT_SOUND, r->pos + hit - r->pre_roll, r->pos + hit, in, n);
        break;
    }
    case RC_WAIT_TIME: {
        bool started = false;
        if (atomic_load_explicit(&r->start_gen, memory_order_acquire) == r->seen_gen) {
            int64_t at = atomic_load_explicit(&r->start_ns, memory_order_relaxed);
            /* 1e-3 frame (≈ 20 ns at 48 kHz): ns rounding stays on its frame. */
            double off = (double)(at - t0_ns) * r->rate / 1e9;
            int64_t start = r->pos + (int64_t)ceil(off - 1e-3);
            if (start < r->pos + n) {
                start_at(r, RC_WAIT_TIME, start, start, in, n);
                started = true;
            }
        }
        if (!started) ring_put(r, in, n);
        break;
    }
    case RC_RECORDING:
        append(r, in, n);
        break;
    default:
        break;
    }
    r->pos += n;
    atomic_store(&r->busy, false);
}
