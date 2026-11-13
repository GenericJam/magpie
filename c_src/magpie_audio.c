/*
 * c_src/magpie_audio.c — Magpie's audio engine on Android: the sampler core
 * (sampler.c) behind an AAudio output stream, NDK MediaCodec decoding, and
 * the NIF (Magpie.Audio.Nif).
 *
 *   output callback  AAudio, low-latency performance mode, shared, stereo
 *                    float at the device's own rate. Runs sp_render: drains
 *                    the command queue, runs the sequencer, mixes the voices.
 *   event thread     Every 2 ms: turns the renderer's events into messages
 *                    for the owner (coalesced: one playhead and at most a
 *                    start and an end per pad per pass), frees retired
 *                    samples and patterns, refreshes the clock mapping
 *                    (getTimestamp) every 20 ms, grows the buffer by a burst
 *                    after an underrun, and reopens the stream after a
 *                    disconnect (headphones, Bluetooth).
 *   loader thread    load_sample/2 jobs in order: AMediaExtractor +
 *                    AMediaCodec decode a file to 16-bit (wav, mp3, aac,
 *                    flac, ogg, …), resample to the engine's rate, peaks,
 *                    then hand the sample to the renderer.
 *
 * Messages to the owner (open/1's caller):
 *
 *   {magpie_audio, playhead, Step, Frame}
 *   {magpie_audio, voice, Pad, start | end}
 *   {magpie_audio, hit, Pad, #'Elixir.Magpie.Kit.Step'{step, vel, tick, note}}
 *   {magpie_audio, pattern, Id, Frame}
 *   {magpie_audio, loaded, SampleId, {ok, Info} | {error, Reason}}
 *
 * Frames are engine frames (rendered since the engine started); clock/0
 * maps them onto erlang:monotonic_time/1.
 *
 * Control calls (samples, pads, patterns, tempo, play, reset, close) are
 * the owner's alone ({error, not_owner} for anyone else); live calls
 * (trigger, release, note_on, note_off) are open to every process and
 * only queue a command: they never wait on the stream.
 *
 * Locks, always taken in this order: lock → ctl → jobs_lock / push →
 * stats_lock. `lock` covers the stream's lifecycle (open, close, reopen)
 * and the NIFs that ask the stream (info); NIFs taking it run on dirty IO
 * schedulers. `ctl` covers the owner, the sample table and, while no stream
 * renders, the renderer's role (sp_drain). `push` serialises producers into
 * the command queue; the audio callback never takes a lock.
 *
 * AAudio and libmediandk are opened with dlopen: the app links against
 * android-24 headers, where AAudio (API 26) doesn't exist, while the app's
 * minSdk is 28, so both libraries are always present at run time.
 */

#include <dlfcn.h>
#include <erl_nif.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <android/log.h>

#include "sampler.c"

#define LOG_TAG "magpie_audio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#define MAX_SECONDS 300            /* longest sample load_sample/2 accepts */
#define EVENT_PERIOD_US 2000
#define CLOCK_PERIOD_NS 20000000LL /* refresh the timestamp mapping */
#define REOPEN_PERIOD_NS 500000000LL
#define LATENCIES 256
#define DEFAULT_RATE 48000

/* ── AAudio, declared by hand (see header comment) ───────────────────────── */

typedef struct AAudioStreamBuilderStruct AAudioStreamBuilder;
typedef struct AAudioStreamStruct AAudioStream;
typedef int32_t aaudio_result_t;
typedef int32_t (*aa_data_cb)(AAudioStream *, void *, void *, int32_t);
typedef void (*aa_error_cb)(AAudioStream *, void *, aaudio_result_t);

enum {
    AA_OK = 0,
    AA_UNSPECIFIED = 0,
    AA_DIRECTION_OUTPUT = 0,
    AA_FORMAT_PCM_FLOAT = 2,
    AA_SHARING_EXCLUSIVE = 0,
    AA_SHARING_SHARED = 1,
    AA_PERF_LOW_LATENCY = 12,
    AA_USAGE_MEDIA = 1,
    AA_CONTENT_MUSIC = 2,
    AA_CALLBACK_CONTINUE = 0,
    AA_STATE_OPEN = 2,
    AA_STATE_STARTING = 3,
    AA_STATE_STARTED = 4,
    AA_STATE_PAUSED = 6,
    AA_STATE_FLUSHED = 8,
    AA_STATE_STOPPED = 10,
    AA_STATE_DISCONNECTED = 13,
};

static struct {
    aaudio_result_t (*createStreamBuilder)(AAudioStreamBuilder **);
    void (*setDirection)(AAudioStreamBuilder *, int32_t);
    void (*setChannelCount)(AAudioStreamBuilder *, int32_t);
    void (*setFormat)(AAudioStreamBuilder *, int32_t);
    void (*setSharingMode)(AAudioStreamBuilder *, int32_t);
    void (*setPerformanceMode)(AAudioStreamBuilder *, int32_t);
    void (*setUsage)(AAudioStreamBuilder *, int32_t);
    void (*setContentType)(AAudioStreamBuilder *, int32_t);
    void (*setDataCallback)(AAudioStreamBuilder *, aa_data_cb, void *);
    void (*setErrorCallback)(AAudioStreamBuilder *, aa_error_cb, void *);
    aaudio_result_t (*openStream)(AAudioStreamBuilder *, AAudioStream **);
    aaudio_result_t (*builderDelete)(AAudioStreamBuilder *);
    aaudio_result_t (*close)(AAudioStream *);
    aaudio_result_t (*requestStart)(AAudioStream *);
    aaudio_result_t (*requestStop)(AAudioStream *);
    int32_t (*getDeviceId)(AAudioStream *);
    int32_t (*getSampleRate)(AAudioStream *);
    int32_t (*getFramesPerBurst)(AAudioStream *);
    int32_t (*getBufferSizeInFrames)(AAudioStream *);
    aaudio_result_t (*setBufferSizeInFrames)(AAudioStream *, int32_t);
    int32_t (*getBufferCapacityInFrames)(AAudioStream *);
    int32_t (*getXRunCount)(AAudioStream *);
    int32_t (*getPerformanceMode)(AAudioStream *);
    int32_t (*getSharingMode)(AAudioStream *);
    int64_t (*getFramesWritten)(AAudioStream *);
    aaudio_result_t (*getTimestamp)(AAudioStream *, clockid_t, int64_t *, int64_t *);
    int32_t (*getState)(AAudioStream *);
    aaudio_result_t (*waitForStateChange)(AAudioStream *, int32_t, int32_t *, int64_t);
} aa;

/* ── libmediandk, declared by hand ───────────────────────────────────────── */

typedef struct AMediaExtractor AMediaExtractor;
typedef struct AMediaFormat AMediaFormat;
typedef struct AMediaCodec AMediaCodec;
typedef struct {
    int32_t offset;
    int32_t size;
    int64_t presentationTimeUs;
    uint32_t flags;
} codec_buffer_info;

#define CODEC_EOS 4
#define CODEC_TRY_AGAIN -1
#define CODEC_FORMAT_CHANGED -2
#define CODEC_BUFFERS_CHANGED -3
#define PCM_16BIT 2
#define PCM_FLOAT 4

static struct {
    AMediaExtractor *(*exNew)(void);
    int (*exDelete)(AMediaExtractor *);
    int (*exSetDataSourceFd)(AMediaExtractor *, int, off64_t, off64_t);
    size_t (*exGetTrackCount)(AMediaExtractor *);
    AMediaFormat *(*exGetTrackFormat)(AMediaExtractor *, size_t);
    int (*exSelectTrack)(AMediaExtractor *, size_t);
    ssize_t (*exReadSampleData)(AMediaExtractor *, uint8_t *, size_t);
    int64_t (*exGetSampleTime)(AMediaExtractor *);
    bool (*exAdvance)(AMediaExtractor *);
    bool (*fmtGetString)(AMediaFormat *, const char *, const char **);
    bool (*fmtGetInt32)(AMediaFormat *, const char *, int32_t *);
    bool (*fmtGetInt64)(AMediaFormat *, const char *, int64_t *);
    int (*fmtDelete)(AMediaFormat *);
    AMediaCodec *(*codecCreateDecoderByType)(const char *);
    int (*codecConfigure)(AMediaCodec *, const AMediaFormat *, void *, void *, uint32_t);
    int (*codecStart)(AMediaCodec *);
    int (*codecStop)(AMediaCodec *);
    int (*codecDelete)(AMediaCodec *);
    ssize_t (*codecDequeueInputBuffer)(AMediaCodec *, int64_t);
    uint8_t *(*codecGetInputBuffer)(AMediaCodec *, size_t, size_t *);
    int (*codecQueueInputBuffer)(AMediaCodec *, size_t, off_t, size_t, uint64_t, uint32_t);
    ssize_t (*codecDequeueOutputBuffer)(AMediaCodec *, codec_buffer_info *, int64_t);
    uint8_t *(*codecGetOutputBuffer)(AMediaCodec *, size_t, size_t *);
    int (*codecReleaseOutputBuffer)(AMediaCodec *, size_t, bool);
    AMediaFormat *(*codecGetOutputFormat)(AMediaCodec *);
} md;

static const char *libs_error = NULL;
static bool libs_ok = false;

#define BIND(table, handle, field, name)              \
    do {                                              \
        *(void **)&table.field = dlsym(handle, name); \
        if (!table.field) {                           \
            libs_error = name;                        \
            return false;                             \
        }                                             \
    } while (0)

static bool bind_libraries(void) {
    void *a = dlopen("libaaudio.so", RTLD_NOW);
    void *m = dlopen("libmediandk.so", RTLD_NOW);
    if (!a) {
        libs_error = "libaaudio.so";
        return false;
    }
    if (!m) {
        libs_error = "libmediandk.so";
        return false;
    }
    BIND(aa, a, createStreamBuilder, "AAudio_createStreamBuilder");
    BIND(aa, a, setDirection, "AAudioStreamBuilder_setDirection");
    BIND(aa, a, setChannelCount, "AAudioStreamBuilder_setChannelCount");
    BIND(aa, a, setFormat, "AAudioStreamBuilder_setFormat");
    BIND(aa, a, setSharingMode, "AAudioStreamBuilder_setSharingMode");
    BIND(aa, a, setPerformanceMode, "AAudioStreamBuilder_setPerformanceMode");
    BIND(aa, a, setUsage, "AAudioStreamBuilder_setUsage");
    BIND(aa, a, setContentType, "AAudioStreamBuilder_setContentType");
    BIND(aa, a, setDataCallback, "AAudioStreamBuilder_setDataCallback");
    BIND(aa, a, setErrorCallback, "AAudioStreamBuilder_setErrorCallback");
    BIND(aa, a, openStream, "AAudioStreamBuilder_openStream");
    BIND(aa, a, builderDelete, "AAudioStreamBuilder_delete");
    BIND(aa, a, close, "AAudioStream_close");
    BIND(aa, a, requestStart, "AAudioStream_requestStart");
    BIND(aa, a, requestStop, "AAudioStream_requestStop");
    BIND(aa, a, getDeviceId, "AAudioStream_getDeviceId");
    BIND(aa, a, getSampleRate, "AAudioStream_getSampleRate");
    BIND(aa, a, getFramesPerBurst, "AAudioStream_getFramesPerBurst");
    BIND(aa, a, getBufferSizeInFrames, "AAudioStream_getBufferSizeInFrames");
    BIND(aa, a, setBufferSizeInFrames, "AAudioStream_setBufferSizeInFrames");
    BIND(aa, a, getBufferCapacityInFrames, "AAudioStream_getBufferCapacityInFrames");
    BIND(aa, a, getXRunCount, "AAudioStream_getXRunCount");
    BIND(aa, a, getPerformanceMode, "AAudioStream_getPerformanceMode");
    BIND(aa, a, getSharingMode, "AAudioStream_getSharingMode");
    BIND(aa, a, getFramesWritten, "AAudioStream_getFramesWritten");
    BIND(aa, a, getTimestamp, "AAudioStream_getTimestamp");
    BIND(aa, a, getState, "AAudioStream_getState");
    BIND(aa, a, waitForStateChange, "AAudioStream_waitForStateChange");

    BIND(md, m, exNew, "AMediaExtractor_new");
    BIND(md, m, exDelete, "AMediaExtractor_delete");
    BIND(md, m, exSetDataSourceFd, "AMediaExtractor_setDataSourceFd");
    BIND(md, m, exGetTrackCount, "AMediaExtractor_getTrackCount");
    BIND(md, m, exGetTrackFormat, "AMediaExtractor_getTrackFormat");
    BIND(md, m, exSelectTrack, "AMediaExtractor_selectTrack");
    BIND(md, m, exReadSampleData, "AMediaExtractor_readSampleData");
    BIND(md, m, exGetSampleTime, "AMediaExtractor_getSampleTime");
    BIND(md, m, exAdvance, "AMediaExtractor_advance");
    BIND(md, m, fmtGetString, "AMediaFormat_getString");
    BIND(md, m, fmtGetInt32, "AMediaFormat_getInt32");
    BIND(md, m, fmtGetInt64, "AMediaFormat_getInt64");
    BIND(md, m, fmtDelete, "AMediaFormat_delete");
    BIND(md, m, codecCreateDecoderByType, "AMediaCodec_createDecoderByType");
    BIND(md, m, codecConfigure, "AMediaCodec_configure");
    BIND(md, m, codecStart, "AMediaCodec_start");
    BIND(md, m, codecStop, "AMediaCodec_stop");
    BIND(md, m, codecDelete, "AMediaCodec_delete");
    BIND(md, m, codecDequeueInputBuffer, "AMediaCodec_dequeueInputBuffer");
    BIND(md, m, codecGetInputBuffer, "AMediaCodec_getInputBuffer");
    BIND(md, m, codecQueueInputBuffer, "AMediaCodec_queueInputBuffer");
    BIND(md, m, codecDequeueOutputBuffer, "AMediaCodec_dequeueOutputBuffer");
    BIND(md, m, codecGetOutputBuffer, "AMediaCodec_getOutputBuffer");
    BIND(md, m, codecReleaseOutputBuffer, "AMediaCodec_releaseOutputBuffer");
    BIND(md, m, codecGetOutputFormat, "AMediaCodec_getOutputFormat");
    return true;
}

/* ── State ───────────────────────────────────────────────────────────────── */

static sp_engine SP;

/* A sample id (any term) and what its slot holds. */
typedef struct {
    bool used;   /* the slot belongs to `id` (loading or loaded) */
    bool loaded; /* a sample is installed */
    ErlNifEnv *env;
    ERL_NIF_TERM id;
    uint64_t request; /* the latest load or unload of this id; older loads are stale */
    size_t bytes;
} id_entry;

/* A load: a file to decode (`path`) or f32le PCM (`pcm`, held in `env`). */
typedef struct load_job {
    struct load_job *next;
    char *path;
    ERL_NIF_TERM pcm;
    int source_rate, channels;
    int slot;
    uint64_t request;
    int rate;
    ErlNifEnv *env;
    ERL_NIF_TERM id;
} load_job;

static struct {
    pthread_mutex_t lock, ctl, push, jobs_lock, stats_lock;
    pthread_cond_t jobs_cv;

    /* Under `lock`; the event thread changes them only while it runs, and
     * close/1 joins it first. */
    AAudioStream *out;
    int burst, capacity;
    _Atomic int32_t buffer_frames;
    _Atomic int rate;
    _Atomic bool running;  /* a stream renders: live calls go in */
    _Atomic bool out_dead; /* the stream reported an error: the event thread reopens */
    _Atomic int64_t reopens;

    /* Under `ctl`. */
    bool drains;        /* no stream renders: control calls drain the queue */
    bool events_alive;  /* the event thread runs (it alone frees garbage then) */
    ErlNifPid owner;
    bool has_owner;
    id_entry ids[SP_SLOTS];
    uint64_t requests;
    uint32_t patterns;

    pthread_t events;
    _Atomic bool events_run;

    /* Under jobs_lock. */
    load_job *jobs_head, *jobs_tail;
    bool loader_started;

    /* Callback timing (relaxed atomics, written by the callback). */
    _Atomic int64_t cb_count, cb_ns_sum, cb_ns_max, cb_gap_max, cb_last_start, cb_frames;
    _Atomic int64_t frame_offset; /* engine frame − stream frame */
    _Atomic int64_t engine_frame;

    /* Trigger latency, newest LATENCIES (under stats_lock). */
    float latency_ms[LATENCIES];
    int64_t latency_n;
    int32_t xruns_base;

    _Atomic int64_t sample_bytes;
} E;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) { return enif_make_atom(env, name); }

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static ERL_NIF_TERM ok_atom(ErlNifEnv *env) { return atom(env, "ok"); }

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static ERL_NIF_TERM make_map(ErlNifEnv *env, ERL_NIF_TERM *keys, ERL_NIF_TERM *vals, size_t n) {
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, n, &map);
    return map;
}

static void free_garbage(const sp_garbage *g) {
    if (g->kind == SP_GB_SAMPLE) atomic_fetch_sub(&E.sample_bytes, (int64_t)((sp_sample *)g->ptr)->bytes);
    sp_free_garbage(g);
}

/* ── Commands ────────────────────────────────────────────────────────────── */

static bool push_cmd(const sp_cmd *c) {
    pthread_mutex_lock(&E.push);
    bool ok = sp_push(&SP, c);
    pthread_mutex_unlock(&E.push);
    return ok;
}

/* A control command. Caller holds ctl. With no stream rendering, the
 * control path plays the renderer and applies it now; with no event
 * thread, it also frees what was retired. */
static bool ctl_push(const sp_cmd *c) {
    bool ok = push_cmd(c);
    if (E.drains) sp_drain(&SP, false);
    if (!E.events_alive) {
        sp_garbage g;
        while (sp_pop_garbage(&SP, &g)) free_garbage(&g);
    }
    return ok;
}

/* ── The output stream ───────────────────────────────────────────────────── */

static int32_t output_cb(AAudioStream *s, void *user, void *data, int32_t frames) {
    (void)user;
    int64_t t0 = now_ns();
    int64_t last = atomic_load_explicit(&E.cb_last_start, memory_order_relaxed);
    if (last > 0 && t0 - last > atomic_load_explicit(&E.cb_gap_max, memory_order_relaxed))
        atomic_store_explicit(&E.cb_gap_max, t0 - last, memory_order_relaxed);
    atomic_store_explicit(&E.cb_last_start, t0, memory_order_relaxed);
    atomic_store_explicit(&E.frame_offset, SP.frame - aa.getFramesWritten(s), memory_order_relaxed);

    sp_render(&SP, data, frames);

    int64_t dt = now_ns() - t0;
    atomic_fetch_add_explicit(&E.cb_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&E.cb_ns_sum, dt, memory_order_relaxed);
    atomic_fetch_add_explicit(&E.cb_frames, frames, memory_order_relaxed);
    if (dt > atomic_load_explicit(&E.cb_ns_max, memory_order_relaxed))
        atomic_store_explicit(&E.cb_ns_max, dt, memory_order_relaxed);
    atomic_store_explicit(&E.engine_frame, SP.frame, memory_order_relaxed);
    return AA_CALLBACK_CONTINUE;
}

/* Disconnected (headphones unplugged, Bluetooth gone) or failed: the
 * stream has stopped. AAudio forbids closing it here; the event thread
 * reopens it. */
static void output_error_cb(AAudioStream *s, void *user, aaudio_result_t err) {
    (void)s;
    (void)user;
    LOGE("output stream error %d", err);
    atomic_store(&E.running, false);
    atomic_store(&E.out_dead, true);
}

static bool stream_quiet(int32_t state) {
    return state == AA_STATE_OPEN || state == AA_STATE_PAUSED || state == AA_STATE_FLUSHED ||
           state == AA_STATE_STOPPED || state == AA_STATE_DISCONNECTED;
}

/* Stop the stream and wait until no callback can run; false if it was
 * still running after a second. */
static bool stop_stream(AAudioStream *s) {
    int64_t deadline = now_ns() + 1000000000LL;
    int32_t state = aa.getState(s);
    while (!stream_quiet(state) && now_ns() < deadline) {
        if (state == AA_STATE_STARTING || state == AA_STATE_STARTED) aa.requestStop(s);
        int32_t next = state;
        aa.waitForStateChange(s, state, &next, 100000000LL);
        state = aa.getState(s);
    }
    if (!stream_quiet(state)) {
        LOGE("stream still running (state %d): left open", state);
        return false;
    }
    return true;
}

/* Stop and close the stream; the control path renders from here (drains).
 * Caller holds `lock`. A stream that won't stop stays open and is never
 * closed under a running callback: false. */
static bool close_output_locked(void) {
    atomic_store(&E.running, false);
    if (!E.out) return true;
    if (!stop_stream(E.out)) return false;
    aa.close(E.out);
    E.out = NULL;
    pthread_mutex_lock(&E.ctl);
    E.drains = true;
    sp_drain(&SP, false);
    pthread_mutex_unlock(&E.ctl);
    return true;
}

/* Open and start the output stream at the device's rate; the renderer
 * takes over from the control path. Caller holds `lock`. */
static aaudio_result_t open_output_locked(void) {
    AAudioStreamBuilder *b;
    aaudio_result_t r = aa.createStreamBuilder(&b);
    if (r != AA_OK) return r;
    aa.setDirection(b, AA_DIRECTION_OUTPUT);
    aa.setChannelCount(b, 2);
    aa.setFormat(b, AA_FORMAT_PCM_FLOAT);
    aa.setSharingMode(b, AA_SHARING_SHARED);
    aa.setPerformanceMode(b, AA_PERF_LOW_LATENCY);
    aa.setUsage(b, AA_USAGE_MEDIA);
    aa.setContentType(b, AA_CONTENT_MUSIC);
    aa.setDataCallback(b, output_cb, NULL);
    aa.setErrorCallback(b, output_error_cb, NULL);
    AAudioStream *s = NULL;
    r = aa.openStream(b, &s);
    aa.builderDelete(b);
    if (r != AA_OK) return r;

    int rate = aa.getSampleRate(s);
    E.burst = aa.getFramesPerBurst(s);
    E.capacity = aa.getBufferCapacityInFrames(s);
    /* Double buffering; the event thread adds a burst after an underrun. */
    if (E.burst > 0) aa.setBufferSizeInFrames(s, 2 * E.burst);
    int32_t buffer = aa.getBufferSizeInFrames(s);
    atomic_store(&E.buffer_frames, buffer);
    atomic_store(&E.rate, rate);
    atomic_store(&SP.latency_frames, buffer);
    E.xruns_base = 0;

    pthread_mutex_lock(&E.ctl);
    sp_cmd c = {.type = SP_CMD_RATE, .u.rate = rate};
    push_cmd(&c);
    sp_drain(&SP, false);
    E.drains = false;
    pthread_mutex_unlock(&E.ctl);

    E.out = s;
    atomic_store(&E.out_dead, false);
    r = aa.requestStart(s);
    if (r != AA_OK) {
        LOGE("output start failed: %d", r);
        close_output_locked();
        return r;
    }
    atomic_store(&E.running, true);
    LOGI("output open: device %d, %d Hz, burst %d, buffer %d of %d, %s, %s", aa.getDeviceId(s), rate, E.burst,
         buffer, E.capacity, aa.getPerformanceMode(s) == AA_PERF_LOW_LATENCY ? "low latency" : "not low latency",
         aa.getSharingMode(s) == AA_SHARING_EXCLUSIVE ? "exclusive" : "shared");
    return AA_OK;
}

/* ── The event thread ────────────────────────────────────────────────────── */

static ERL_NIF_TERM tag(ErlNifEnv *env) { return atom(env, "magpie_audio"); }

/* Send `msg` (built in `env`) and clear `env` for the next one: a
 * successful enif_send invalidates the environment, a failed one (the
 * owner is gone) leaves it as it was. */
static void send_owner(const ErlNifPid *owner, ErlNifEnv *env, ERL_NIF_TERM msg) {
    enif_send(NULL, owner, env, msg);
    enif_clear_env(env);
}

static ERL_NIF_TERM step_struct(ErlNifEnv *env, const sp_event *ev) {
    ERL_NIF_TERM keys[5] = {atom(env, "__struct__"), atom(env, "step"), atom(env, "vel"), atom(env, "tick"),
                            atom(env, "note")};
    ERL_NIF_TERM vals[5] = {atom(env, "Elixir.Magpie.Kit.Step"), enif_make_int(env, ev->a), enif_make_int(env, ev->vel),
                            enif_make_int(env, ev->b), ev->note >= 0 ? enif_make_int(env, ev->note) : atom(env, "nil")};
    return make_map(env, keys, vals, 5);
}

static void record_latency(const sp_event *ev) {
    int64_t cf, cns;
    int rate = atomic_load(&E.rate);
    if (!sp_get_clock(&SP, &cf, &cns) || rate <= 0) return;
    double heard_ns = (double)cns + (double)(ev->frame - cf) * 1e9 / rate;
    float ms = (float)((heard_ns - (double)ev->t_ns) / 1e6);
    pthread_mutex_lock(&E.stats_lock);
    E.latency_ms[E.latency_n++ % LATENCIES] = ms;
    pthread_mutex_unlock(&E.stats_lock);
}

/* Per pass, per pad: whether a voice started, and the last change. */
static bool pad_started[SP_PADS];
static int pad_last[SP_PADS]; /* 0 none, SP_EV_VOICE_START, SP_EV_VOICE_END */

static void deliver_events(ErlNifEnv *env) {
    pthread_mutex_lock(&E.ctl);
    bool has_owner = E.has_owner;
    ErlNifPid owner = E.owner;
    pthread_mutex_unlock(&E.ctl);

    sp_event ev, head = {.type = 0xff};
    bool any_voice = false;
    while (sp_pop_event(&SP, &ev)) {
        switch (ev.type) {
        case SP_EV_PLAYHEAD:
            head = ev;
            break;
        case SP_EV_VOICE_START:
        case SP_EV_VOICE_END:
            if (ev.type == SP_EV_VOICE_START) pad_started[ev.pad] = true;
            pad_last[ev.pad] = ev.type;
            any_voice = true;
            break;
        case SP_EV_HIT:
            if (has_owner)
                send_owner(&owner, env,
                           enif_make_tuple4(env, tag(env), atom(env, "hit"), enif_make_int(env, ev.pad),
                                            step_struct(env, &ev)));
            break;
        case SP_EV_PATTERN:
            if (has_owner)
                send_owner(&owner, env,
                           enif_make_tuple4(env, tag(env), atom(env, "pattern"), enif_make_uint(env, (unsigned)ev.a),
                                            enif_make_int64(env, ev.frame)));
            break;
        case SP_EV_TRIGGERED:
            record_latency(&ev);
            break;
        }
    }
    if (any_voice) {
        for (int p = 0; p < SP_PADS; p++) {
            if (!pad_last[p]) continue;
            bool ended = pad_last[p] == SP_EV_VOICE_END;
            if (has_owner && pad_started[p])
                send_owner(&owner, env,
                           enif_make_tuple4(env, tag(env), atom(env, "voice"), enif_make_int(env, p), atom(env, "start")));
            if (has_owner && ended)
                send_owner(&owner, env,
                           enif_make_tuple4(env, tag(env), atom(env, "voice"), enif_make_int(env, p), atom(env, "end")));
            pad_started[p] = false;
            pad_last[p] = 0;
        }
    }
    if (head.type == SP_EV_PLAYHEAD && has_owner)
        send_owner(&owner, env,
                   enif_make_tuple4(env, tag(env), atom(env, "playhead"), enif_make_int(env, head.a),
                                    enif_make_int64(env, head.frame)));
}

static void refresh_clock(void) {
    int64_t pos, time;
    if (E.out && aa.getTimestamp(E.out, CLOCK_MONOTONIC, &pos, &time) == AA_OK)
        sp_set_clock(&SP, pos + atomic_load(&E.frame_offset), time);
}

/* After an underrun, a burst more of buffer (up to the capacity). */
static void tune_buffer(void) {
    if (!E.out || E.burst <= 0) return;
    int32_t xruns = aa.getXRunCount(E.out);
    if (xruns <= E.xruns_base) return;
    E.xruns_base = xruns;
    int32_t size = aa.getBufferSizeInFrames(E.out);
    if (size + E.burst <= E.capacity) {
        aa.setBufferSizeInFrames(E.out, size + E.burst);
        size = aa.getBufferSizeInFrames(E.out);
        atomic_store(&E.buffer_frames, size);
        atomic_store(&SP.latency_frames, size);
        LOGI("underrun: buffer now %d frames", size);
    }
}

/* The stream died: close it and open a new one, on whatever output the
 * system now routes to. Event thread, `lock` held. */
static void reopen_locked(void) {
    if (E.out && !close_output_locked()) return;
    aaudio_result_t r = open_output_locked();
    if (r == AA_OK) {
        atomic_fetch_add(&E.reopens, 1);
        LOGI("output reopened");
    } else {
        LOGE("output reopen failed: %d", r);
    }
}

static void *events_main(void *arg) {
    (void)arg;
    /* Android's audio priority, so playhead and voice events keep up with
     * the UI. Best effort. */
    if (setpriority(PRIO_PROCESS, (id_t)gettid(), -16) != 0) LOGE("events: could not raise the thread's priority");
    ErlNifEnv *env = enif_alloc_env();
    int64_t next_clock = 0, next_reopen = 0;
    while (atomic_load(&E.events_run)) {
        int64_t now = now_ns();
        if (atomic_load(&E.out_dead) && now >= next_reopen && pthread_mutex_trylock(&E.lock) == 0) {
            if (atomic_load(&E.events_run)) reopen_locked();
            pthread_mutex_unlock(&E.lock);
            next_reopen = now + REOPEN_PERIOD_NS;
        }
        if (now >= next_clock && atomic_load(&E.running)) {
            refresh_clock();
            tune_buffer();
            next_clock = now + CLOCK_PERIOD_NS;
        }
        deliver_events(env);
        sp_garbage g;
        while (sp_pop_garbage(&SP, &g)) free_garbage(&g);
        usleep(EVENT_PERIOD_US);
    }
    enif_free_env(env);
    return NULL;
}

/* ── Decoding (the loader thread) ────────────────────────────────────────── */

typedef struct {
    int16_t *pcm; /* interleaved, `channels` per frame */
    int64_t frames, capacity;
    int channels, rate;
} decoded;

static bool grow(decoded *d, int64_t need) {
    if (need <= d->capacity) return true;
    int64_t cap = d->capacity ? d->capacity : need;
    while (cap < need) cap *= 2;
    int16_t *p = realloc(d->pcm, (size_t)cap * (size_t)d->channels * sizeof(int16_t));
    if (!p) return false;
    d->pcm = p;
    d->capacity = cap;
    return true;
}

/* Decode the first audio track of `path` to 16-bit, keeping up to two
 * channels. NULL or a reason. */
static const char *decode_file(const char *path, decoded *d) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return "not_found";
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return "not_found";
    }
    AMediaExtractor *ex = md.exNew();
    if (!ex) {
        close(fd);
        return "alloc";
    }
    if (md.exSetDataSourceFd(ex, fd, 0, st.st_size) != 0) {
        md.exDelete(ex);
        close(fd);
        return "unsupported";
    }

    AMediaCodec *codec = NULL;
    int32_t rate = 0, channels = 0;
    int64_t duration_us = 0;
    bool audio = false;
    for (size_t i = 0; i < md.exGetTrackCount(ex) && !codec; i++) {
        AMediaFormat *f = md.exGetTrackFormat(ex, i);
        const char *mime = NULL;
        if (md.fmtGetString(f, "mime", &mime) && strncmp(mime, "audio/", 6) == 0) {
            audio = true;
            md.fmtGetInt32(f, "sample-rate", &rate);
            md.fmtGetInt32(f, "channel-count", &channels);
            md.fmtGetInt64(f, "durationUs", &duration_us);
            md.exSelectTrack(ex, i);
            codec = md.codecCreateDecoderByType(mime);
            if (codec && md.codecConfigure(codec, f, NULL, NULL, 0) != 0) {
                md.codecDelete(codec);
                codec = NULL;
            }
        }
        md.fmtDelete(f);
    }
    const char *failure = NULL;
    if (!audio) failure = "no_audio";
    else if (!codec || rate <= 0 || channels <= 0) failure = "unsupported";
    else if (duration_us > (int64_t)MAX_SECONDS * 1000000) failure = "too_long";
    if (failure) {
        if (codec) md.codecDelete(codec);
        md.exDelete(ex);
        close(fd);
        return failure;
    }

    int out_channels = channels, out_rate = rate, encoding = PCM_16BIT;
    d->channels = channels > 2 ? 2 : channels;
    d->rate = rate;
    if (!grow(d, duration_us > 0 ? duration_us * rate / 1000000 + rate / 4 : (int64_t)rate * 10)) failure = "alloc";
    else if (md.codecStart(codec) != 0) failure = "decode_error";
    bool input_done = false;

    while (!failure) {
        if (!input_done) {
            ssize_t in = md.codecDequeueInputBuffer(codec, 5000);
            if (in >= 0) {
                size_t size = 0;
                uint8_t *buf = md.codecGetInputBuffer(codec, (size_t)in, &size);
                ssize_t n = buf ? md.exReadSampleData(ex, buf, size) : -1;
                int queued;
                if (n < 0) {
                    queued = md.codecQueueInputBuffer(codec, (size_t)in, 0, 0, 0, CODEC_EOS);
                    input_done = true;
                } else {
                    queued = md.codecQueueInputBuffer(codec, (size_t)in, 0, (size_t)n, (uint64_t)md.exGetSampleTime(ex), 0);
                    md.exAdvance(ex);
                }
                if (!buf || queued != 0) failure = "decode_error";
            } else if (in != CODEC_TRY_AGAIN) {
                failure = "decode_error";
            }
            if (failure) break;
        }

        codec_buffer_info info;
        ssize_t out = md.codecDequeueOutputBuffer(codec, &info, 5000);
        if (out == CODEC_FORMAT_CHANGED) {
            AMediaFormat *f = md.codecGetOutputFormat(codec);
            md.fmtGetInt32(f, "channel-count", &out_channels);
            md.fmtGetInt32(f, "sample-rate", &out_rate);
            if (!md.fmtGetInt32(f, "pcm-encoding", &encoding)) encoding = PCM_16BIT;
            md.fmtDelete(f);
            if (d->frames == 0) d->rate = out_rate; /* e.g. HE-AAC decodes at twice the container's rate */
            if (encoding != PCM_16BIT && encoding != PCM_FLOAT) failure = "unsupported";
            if (out_channels <= 0) failure = "decode_error";
            continue;
        }
        if (out == CODEC_TRY_AGAIN || out == CODEC_BUFFERS_CHANGED) continue;
        if (out < 0) {
            failure = "decode_error";
            break;
        }
        size_t size = 0;
        uint8_t *buf = md.codecGetOutputBuffer(codec, (size_t)out, &size);
        if (!buf) {
            md.codecReleaseOutputBuffer(codec, (size_t)out, false);
            failure = "decode_error";
            break;
        }
        int bytes = encoding == PCM_FLOAT ? 4 : 2;
        int64_t frames = info.size / (int64_t)(bytes * out_channels);
        /* At the rate the decoder delivers (HE-AAC: twice the container's). */
        int64_t limit = (int64_t)MAX_SECONDS * d->rate + d->rate;
        if (d->frames + frames > limit) failure = "too_long";
        else if (!grow(d, d->frames + frames)) failure = "alloc";
        if (!failure) {
            const uint8_t *src = buf + info.offset;
            int16_t *dst = d->pcm + d->frames * d->channels;
            for (int64_t f = 0; f < frames; f++) {
                for (int c = 0; c < d->channels; c++) {
                    int k = c < out_channels ? c : 0; /* a mono stream after a stereo start feeds both */
                    if (encoding == PCM_FLOAT) {
                        float x = ((const float *)src)[f * out_channels + k] * 32767.0f;
                        dst[f * d->channels + c] = (int16_t)(x > 32767 ? 32767 : x < -32768 ? -32768 : x);
                    } else {
                        dst[f * d->channels + c] = ((const int16_t *)src)[f * out_channels + k];
                    }
                }
            }
            d->frames += frames;
        }
        bool eos = (info.flags & CODEC_EOS) != 0;
        md.codecReleaseOutputBuffer(codec, (size_t)out, false);
        if (eos) break;
    }

    md.codecStop(codec);
    md.codecDelete(codec);
    md.exDelete(ex);
    close(fd);
    if (!failure && d->frames == 0) failure = "no_audio";
    return failure;
}

static ERL_NIF_TERM peaks_term(ErlNifEnv *env, const int16_t *data, int64_t frames, int channels) {
    ERL_NIF_TERM peaks;
    sp_peaks(data, frames, channels, enif_make_new_binary(env, (size_t)sp_peak_count(frames), &peaks));
    return peaks;
}

static ERL_NIF_TERM loaded_info(ErlNifEnv *env, const sp_sample *s, int source_rate, double load_ms) {
    ERL_NIF_TERM keys[8] = {atom(env, "frames"),      atom(env, "channels"), atom(env, "rate"),
                            atom(env, "peaks"),       atom(env, "peak_frames"), atom(env, "bytes"),
                            atom(env, "source_rate"), atom(env, "load_ms")};
    ERL_NIF_TERM vals[8] = {enif_make_int64(env, s->frames),       enif_make_int(env, s->channels),
                            enif_make_int(env, s->rate),           peaks_term(env, s->data, s->frames, s->channels),
                            enif_make_int(env, SP_PEAK_FRAMES),    enif_make_uint64(env, s->bytes),
                            enif_make_int(env, source_rate),       enif_make_double(env, load_ms)};
    return make_map(env, keys, vals, 8);
}

static void send_loaded(ErlNifEnv *env, ERL_NIF_TERM id, ERL_NIF_TERM result) {
    pthread_mutex_lock(&E.ctl);
    if (E.has_owner) {
        ERL_NIF_TERM msg = enif_make_tuple4(env, tag(env), atom(env, "loaded"), id, result);
        if (!enif_send(NULL, &E.owner, env, msg)) enif_clear_env(env);
    }
    pthread_mutex_unlock(&E.ctl);
}

static bool job_current(const load_job *job) {
    const id_entry *e = &E.ids[job->slot];
    return e->used && e->request == job->request;
}

/* A PCM job's f32le binary as 16-bit, keeping up to two channels. */
static const char *convert_pcm(load_job *job, decoded *d) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(job->env, job->pcm, &bin)) return "badarg";
    int64_t frames = (int64_t)(bin.size / (4 * (size_t)job->channels));
    if (frames == 0) return "no_audio";
    if (frames > (int64_t)MAX_SECONDS * job->source_rate) return "too_long";
    d->channels = job->channels > 2 ? 2 : job->channels;
    d->rate = job->source_rate;
    d->frames = frames;
    d->pcm = sp_from_f32(bin.data, frames, job->channels, d->channels);
    return d->pcm ? NULL : "alloc";
}

static void run_job(load_job *job) {
    int64_t t0 = now_ns();
    decoded d = {0};
    const char *failure = job->path ? decode_file(job->path, &d) : convert_pcm(job, &d);
    sp_sample *s = NULL;
    if (!failure) {
        int64_t frames = d.frames;
        int16_t *pcm = d.pcm;
        if (d.rate != job->rate) {
            pcm = sp_resample(d.pcm, d.frames, d.channels, d.rate, job->rate, &frames);
            free(d.pcm);
            d.pcm = NULL;
        }
        s = sp_sample_wrap(pcm, frames, d.channels, job->rate);
        if (s) atomic_fetch_add(&E.sample_bytes, (int64_t)s->bytes);
        else failure = "alloc";
    } else {
        free(d.pcm);
    }
    double load_ms = (double)(now_ns() - t0) / 1e6;

    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM id = enif_make_copy(env, job->id);
    ERL_NIF_TERM result;
    pthread_mutex_lock(&E.ctl);
    if (!job_current(job)) {
        result = error_tuple(env, "cancelled");
    } else if (failure) {
        /* A first load that failed frees its slot; a reload that failed
         * leaves the loaded sample in place. */
        id_entry *e = &E.ids[job->slot];
        if (!e->loaded) {
            enif_free_env(e->env);
            *e = (id_entry){0};
        }
        result = error_tuple(env, failure);
    } else {
        id_entry *e = &E.ids[job->slot];
        sp_cmd c = {.type = SP_CMD_SAMPLE, .u.sample = {job->slot, s}};
        if (!ctl_push(&c)) {
            /* The queue is full (it holds 1024): give up this load. */
            if (!e->loaded) {
                enif_free_env(e->env);
                *e = (id_entry){0};
            }
            result = error_tuple(env, "busy");
        } else {
            e->loaded = true;
            e->bytes = s->bytes;
            result = enif_make_tuple2(env, ok_atom(env), loaded_info(env, s, d.rate, load_ms));
            s = NULL;
        }
    }
    pthread_mutex_unlock(&E.ctl);
    if (s) {
        atomic_fetch_sub(&E.sample_bytes, (int64_t)s->bytes);
        sp_sample_free(s);
    }
    send_loaded(env, id, result);
    enif_free_env(env);
    LOGI("load %s: %s in %.0f ms", job->path ? job->path : "pcm", failure ? failure : "ok", load_ms);
}

static void *loader_main(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&E.jobs_lock);
        while (!E.jobs_head) pthread_cond_wait(&E.jobs_cv, &E.jobs_lock);
        load_job *job = E.jobs_head;
        E.jobs_head = job->next;
        if (!E.jobs_head) E.jobs_tail = NULL;
        pthread_mutex_unlock(&E.jobs_lock);
        run_job(job);
        enif_free_env(job->env);
        free(job->path);
        free(job);
    }
    return NULL;
}

/* ── NIF helpers ─────────────────────────────────────────────────────────── */

#define REQUIRE_LIBS(env)                                                                                  \
    if (!libs_ok)                                                                                          \
    return enif_make_tuple2(env, atom(env, "error"),                                                       \
                            enif_make_tuple2(env, atom(env, "missing"), atom(env, libs_error ? libs_error : "unknown")))

/* Caller holds ctl. */
static bool is_owner(ErlNifEnv *env) {
    ErlNifPid self;
    return enif_self(env, &self) && E.has_owner && enif_compare_pids(&E.owner, &self) == 0;
}

static int find_id(ERL_NIF_TERM id) {
    for (int i = 0; i < SP_SLOTS; i++)
        if (E.ids[i].used && enif_compare(E.ids[i].id, id) == 0) return i;
    return -1;
}

static bool get_number(ErlNifEnv *env, ERL_NIF_TERM term, double *out) {
    ErlNifSInt64 i;
    if (enif_get_double(env, term, out)) return true;
    if (!enif_get_int64(env, term, &i)) return false;
    *out = (double)i;
    return true;
}

static bool get_bool(ErlNifEnv *env, ERL_NIF_TERM term, bool *out) {
    if (enif_is_identical(term, atom(env, "true"))) *out = true;
    else if (enif_is_identical(term, atom(env, "false"))) *out = false;
    else return false;
    return true;
}

static bool get_range(ErlNifEnv *env, ERL_NIF_TERM term, int lo, int hi, int *out) {
    return enif_get_int(env, term, out) && *out >= lo && *out <= hi;
}

/* A control command for the owner: ok, not_owner, or busy (queue full). */
static ERL_NIF_TERM control(ErlNifEnv *env, const sp_cmd *c) {
    pthread_mutex_lock(&E.ctl);
    bool mine = is_owner(env);
    bool queued = mine && ctl_push(c);
    pthread_mutex_unlock(&E.ctl);
    if (!mine) return error_tuple(env, "not_owner");
    return queued ? ok_atom(env) : error_tuple(env, "busy");
}

/* A live command: anyone, while a stream renders. */
static ERL_NIF_TERM live(ErlNifEnv *env, sp_cmd *c) {
    if (!atomic_load(&E.running)) return error_tuple(env, "not_running");
    c->t_ns = now_ns();
    return push_cmd(c) ? ok_atom(env) : error_tuple(env, "busy");
}

static ERL_NIF_TERM stream_info(ErlNifEnv *env) {
    ERL_NIF_TERM keys[4] = {atom(env, "rate"), atom(env, "burst"), atom(env, "buffer_frames"), atom(env, "low_latency")};
    ERL_NIF_TERM vals[4] = {enif_make_int(env, atomic_load(&E.rate)), enif_make_int(env, E.burst),
                            enif_make_int(env, atomic_load(&E.buffer_frames)),
                            atom(env, E.out && aa.getPerformanceMode(E.out) == AA_PERF_LOW_LATENCY ? "true" : "false")};
    return make_map(env, keys, vals, 4);
}

static void clear_ids_locked(void) {
    for (int i = 0; i < SP_SLOTS; i++) {
        if (E.ids[i].env) enif_free_env(E.ids[i].env);
        E.ids[i] = (id_entry){0};
    }
}

/* ── NIFs ────────────────────────────────────────────────────────────────── */

/* open(Owner) -> {ok, #{rate, burst, buffer_frames, low_latency}} | {error, Reason}.
 * Opens and starts the output stream if none runs (a stream left over from
 * a close that wouldn't stop, or a dead one, is closed first), and makes
 * Owner the engine's owner. Dirty IO. */
static ERL_NIF_TERM nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    REQUIRE_LIBS(env);
    ErlNifPid owner;
    if (!enif_get_local_pid(env, argv[0], &owner)) return enif_make_badarg(env);
    pthread_mutex_lock(&E.lock);
    pthread_mutex_lock(&E.ctl);
    E.owner = owner;
    E.has_owner = true;
    pthread_mutex_unlock(&E.ctl);
    if (E.out && !atomic_load(&E.running) && !close_output_locked()) {
        pthread_mutex_unlock(&E.lock);
        return error_tuple(env, "output_stuck");
    }
    if (!E.out) {
        aaudio_result_t r = open_output_locked();
        if (r != AA_OK) {
            pthread_mutex_unlock(&E.lock);
            LOGE("output open failed: %d", r);
            return error_tuple(env, "output_unavailable");
        }
    }
    if (!atomic_load(&E.events_run)) {
        pthread_mutex_lock(&E.ctl);
        E.events_alive = true;
        pthread_mutex_unlock(&E.ctl);
        atomic_store(&E.events_run, true);
        if (pthread_create(&E.events, NULL, events_main, NULL) != 0) {
            atomic_store(&E.events_run, false);
            pthread_mutex_lock(&E.ctl);
            E.events_alive = false;
            pthread_mutex_unlock(&E.ctl);
            close_output_locked();
            pthread_mutex_unlock(&E.lock);
            return error_tuple(env, "thread");
        }
    }
    ERL_NIF_TERM info = stream_info(env);
    pthread_mutex_unlock(&E.lock);
    return enif_make_tuple2(env, ok_atom(env), info);
}

/* close() -> ok | {error, not_owner | output_stuck}: stop and close the
 * stream (samples, pads and patterns stay). Dirty IO. */
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    REQUIRE_LIBS(env);
    pthread_mutex_lock(&E.lock);
    pthread_mutex_lock(&E.ctl);
    bool mine = is_owner(env);
    pthread_mutex_unlock(&E.ctl);
    if (!mine) {
        pthread_mutex_unlock(&E.lock);
        return error_tuple(env, "not_owner");
    }
    if (atomic_exchange(&E.events_run, false)) pthread_join(E.events, NULL);
    pthread_mutex_lock(&E.ctl);
    E.events_alive = false;
    sp_garbage g;
    while (sp_pop_garbage(&SP, &g)) free_garbage(&g);
    pthread_mutex_unlock(&E.ctl);
    bool closed = close_output_locked();
    pthread_mutex_unlock(&E.lock);
    return closed ? ok_atom(env) : error_tuple(env, "output_stuck");
}

/* reset() -> ok | {error, not_owner | busy}: everything off: voices fade,
 * pads cleared, samples unloaded, pattern dropped, sequencer stopped at 120
 * bpm, straight. `busy` (the command queue is full) changes nothing. */
static ERL_NIF_TERM nif_reset(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    pthread_mutex_lock(&E.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&E.ctl);
        return error_tuple(env, "not_owner");
    }
    sp_cmd c = {.type = SP_CMD_RESET};
    bool queued = ctl_push(&c);
    if (queued) clear_ids_locked();
    pthread_mutex_unlock(&E.ctl);
    return queued ? ok_atom(env) : error_tuple(env, "busy");
}

static bool ensure_loader(void) {
    pthread_mutex_lock(&E.jobs_lock);
    if (!E.loader_started) {
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        E.loader_started = pthread_create(&t, &attr, loader_main, NULL) == 0;
        pthread_attr_destroy(&attr);
        if (!E.loader_started) LOGE("no loader thread");
    }
    bool ok = E.loader_started;
    pthread_mutex_unlock(&E.jobs_lock);
    return ok;
}

static void free_job(load_job *job) {
    if (job->env) enif_free_env(job->env);
    free(job->path);
    free(job);
}

/* Queue `job` for sample `id`: claim (or reuse) its slot, make every
 * earlier load of it stale. */
static ERL_NIF_TERM enqueue_load(ErlNifEnv *env, ERL_NIF_TERM id, load_job *job) {
    if (!ensure_loader()) {
        free_job(job);
        return error_tuple(env, "thread");
    }
    pthread_mutex_lock(&E.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&E.ctl);
        free_job(job);
        return error_tuple(env, "not_owner");
    }
    int slot = find_id(id);
    if (slot < 0) {
        for (int i = 0; i < SP_SLOTS && slot < 0; i++)
            if (!E.ids[i].used) slot = i;
        if (slot < 0) {
            pthread_mutex_unlock(&E.ctl);
            free_job(job);
            return error_tuple(env, "too_many_samples");
        }
        E.ids[slot] = (id_entry){.used = true, .env = enif_alloc_env()};
        E.ids[slot].id = enif_make_copy(E.ids[slot].env, id);
    }
    E.ids[slot].request = ++E.requests;
    job->slot = slot;
    job->request = E.ids[slot].request;
    job->rate = atomic_load(&E.rate) > 0 ? atomic_load(&E.rate) : DEFAULT_RATE;
    job->id = enif_make_copy(job->env, id);
    pthread_mutex_unlock(&E.ctl);

    pthread_mutex_lock(&E.jobs_lock);
    if (E.jobs_tail) E.jobs_tail->next = job;
    else E.jobs_head = job;
    E.jobs_tail = job;
    pthread_cond_signal(&E.jobs_cv);
    pthread_mutex_unlock(&E.jobs_lock);
    return ok_atom(env);
}

/* load_sample(Id, Path) -> ok | {error, not_owner | too_many_samples |
 * {missing, Lib}}. Decodes (MediaCodec) on the loader thread; the result
 * arrives as {magpie_audio, loaded, Id, {ok, Info} | {error, Reason}}. A
 * later load or unload of the same Id makes this one {error, cancelled}. */
static ERL_NIF_TERM nif_load_sample(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    REQUIRE_LIBS(env);
    ErlNifBinary path;
    if (!enif_inspect_iolist_as_binary(env, argv[1], &path) || path.size == 0 || memchr(path.data, 0, path.size))
        return enif_make_badarg(env);
    load_job *job = calloc(1, sizeof(*job));
    if (!job) return error_tuple(env, "alloc");
    job->env = enif_alloc_env();
    if (!(job->path = strndup((const char *)path.data, path.size))) {
        free_job(job);
        return error_tuple(env, "alloc");
    }
    return enqueue_load(env, argv[0], job);
}

/* load_pcm(Id, Pcm, Rate, Channels) -> as load_sample/2, from interleaved
 * f32le PCM (the library's canonical form) instead of a file: no decoder.
 * The binary is held, not copied, until the loader has converted it. */
static ERL_NIF_TERM nif_load_pcm(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int rate, channels;
    if (!enif_is_binary(env, argv[1]) || !get_range(env, argv[2], 1000, 384000, &rate) ||
        !get_range(env, argv[3], 1, 8, &channels))
        return enif_make_badarg(env);
    load_job *job = calloc(1, sizeof(*job));
    if (!job) return error_tuple(env, "alloc");
    job->env = enif_alloc_env();
    job->pcm = enif_make_copy(job->env, argv[1]);
    job->source_rate = rate;
    job->channels = channels;
    return enqueue_load(env, argv[0], job);
}

/* decode(Path) -> {ok, #{pcm, rate, channels, frames, peaks, peak_frames}}
 * | {error, Reason}: a file (MediaCodec: wav, mp3, aac/m4a, flac, ogg, …)
 * as interleaved f32le at its own rate, up to two channels, for importing
 * into the library. Touches no engine state; anyone may call. Dirty IO. */
static ERL_NIF_TERM nif_decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    REQUIRE_LIBS(env);
    ErlNifBinary path_bin;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &path_bin) || path_bin.size == 0 ||
        memchr(path_bin.data, 0, path_bin.size))
        return enif_make_badarg(env);
    char *path = strndup((const char *)path_bin.data, path_bin.size);
    if (!path) return error_tuple(env, "alloc");
    decoded d = {0};
    const char *failure = decode_file(path, &d);
    free(path);
    if (failure) {
        free(d.pcm);
        return error_tuple(env, failure);
    }
    ERL_NIF_TERM pcm;
    size_t n = (size_t)d.frames * (size_t)d.channels;
    unsigned char *out = enif_make_new_binary(env, n * sizeof(float), &pcm);
    if (!out) {
        free(d.pcm);
        return error_tuple(env, "alloc");
    }
    for (size_t i = 0; i < n; i++) {
        float x = d.pcm[i] / 32768.0f;
        memcpy(out + 4 * i, &x, sizeof(x));
    }
    ERL_NIF_TERM keys[6] = {atom(env, "pcm"),    atom(env, "rate"),  atom(env, "channels"),
                            atom(env, "frames"), atom(env, "peaks"), atom(env, "peak_frames")};
    ERL_NIF_TERM vals[6] = {pcm,
                            enif_make_int(env, d.rate),
                            enif_make_int(env, d.channels),
                            enif_make_int64(env, d.frames),
                            peaks_term(env, d.pcm, d.frames, d.channels),
                            enif_make_int(env, SP_PEAK_FRAMES)};
    free(d.pcm);
    return enif_make_tuple2(env, ok_atom(env), make_map(env, keys, vals, 6));
}

/* unload_sample(Id) -> ok | {error, not_owner | unknown_sample | busy}.
 * Voices playing it fade out, pads using it are cleared, a load in flight
 * is cancelled; the memory is freed once the last voice has faded. `busy`
 * (the command queue is full) changes nothing. */
static ERL_NIF_TERM nif_unload_sample(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    pthread_mutex_lock(&E.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&E.ctl);
        return error_tuple(env, "not_owner");
    }
    int slot = find_id(argv[0]);
    if (slot < 0) {
        pthread_mutex_unlock(&E.ctl);
        return error_tuple(env, "unknown_sample");
    }
    sp_cmd c = {.type = SP_CMD_SAMPLE, .u.sample = {slot, NULL}};
    if (E.ids[slot].loaded && !ctl_push(&c)) {
        pthread_mutex_unlock(&E.ctl);
        return error_tuple(env, "busy");
    }
    enif_free_env(E.ids[slot].env);
    E.ids[slot] = (id_entry){0};
    pthread_mutex_unlock(&E.ctl);
    return ok_atom(env);
}

static bool get_mode(ErlNifEnv *env, ERL_NIF_TERM term, uint8_t *out) {
    static const char *names[] = {"one_shot", "gate", "loop", "toggle", "keys"};
    char name[16];
    if (!enif_get_atom(env, term, name, sizeof(name), ERL_NIF_UTF8)) return false;
    for (uint8_t i = 0; i < 5; i++)
        if (strcmp(name, names[i]) == 0) {
            *out = i;
            return true;
        }
    return false;
}

/* set_pad(Pad, {SampleId | nil, StartFrame, EndFrame, GainDb, PitchSt,
 * Reverse, FadeInMs, FadeOutMs, Mode, Choke, Root}) -> ok | {error,
 * not_owner | unknown_sample | busy}. EndFrame 0: to the sample's end. */
static ERL_NIF_TERM nif_set_pad(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int pad, arity, choke, root;
    const ERL_NIF_TERM *t;
    ErlNifSInt64 start, end;
    double gain_db, pitch, fade_in, fade_out;
    bool reverse;
    uint8_t mode;
    if (!get_range(env, argv[0], 0, SP_PADS - 1, &pad) || !enif_get_tuple(env, argv[1], &arity, &t) || arity != 11 ||
        !enif_get_int64(env, t[1], &start) || !enif_get_int64(env, t[2], &end) || !get_number(env, t[3], &gain_db) ||
        !get_number(env, t[4], &pitch) || !get_bool(env, t[5], &reverse) || !get_number(env, t[6], &fade_in) ||
        !get_number(env, t[7], &fade_out) || !get_mode(env, t[8], &mode) || !get_range(env, t[9], 0, 3, &choke) ||
        !get_range(env, t[10], 0, 127, &root) || start < 0 || end < 0 || fade_in < 0 || fade_out < 0)
        return enif_make_badarg(env);
    bool empty = enif_is_identical(t[0], atom(env, "nil"));

    pthread_mutex_lock(&E.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&E.ctl);
        return error_tuple(env, "not_owner");
    }
    int slot = empty ? -1 : find_id(t[0]);
    if (!empty && (slot < 0 || !E.ids[slot].loaded)) {
        pthread_mutex_unlock(&E.ctl);
        return error_tuple(env, "unknown_sample");
    }
    sp_cmd c = {.type = SP_CMD_PAD,
                .pad = (uint8_t)pad,
                .u.pad = {.slot = slot,
                          .start = start,
                          .end = end,
                          .gain = sp_db_to_gain(gain_db),
                          .pitch = (float)pitch,
                          .fade_in_ms = (float)fade_in,
                          .fade_out_ms = (float)fade_out,
                          .reverse = reverse,
                          .mode = mode,
                          .choke = (uint8_t)choke,
                          .root = (uint8_t)root}};
    bool queued = ctl_push(&c);
    pthread_mutex_unlock(&E.ctl);
    return queued ? ok_atom(env) : error_tuple(env, "busy");
}

/* set_pattern(Steps, [{Pos, Pad, Vel, Note}], AtBar) -> {ok, Id} | {error,
 * not_owner | busy}. Steps 16 | 32; Pos straight ticks in [0, Steps·24);
 * Note −1 for the pad's root. AtBar: while playing, wait for the next bar
 * and start there from step 0; else replace now, keeping the position. The
 * pattern sends {magpie_audio, pattern, Id, Frame} when it takes over. */
static ERL_NIF_TERM nif_set_pattern(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int steps;
    unsigned count;
    bool at_bar;
    if (!enif_get_int(env, argv[0], &steps) || (steps != 16 && steps != 32) ||
        !enif_get_list_length(env, argv[1], &count) || count > SP_MAX_STEPS || !get_bool(env, argv[2], &at_bar))
        return enif_make_badarg(env);
    sp_pattern *p = sp_pattern_new((int)count);
    if (!p) return error_tuple(env, "alloc");
    p->length = steps * SP_STEP;
    ERL_NIF_TERM head, tail = argv[1];
    for (unsigned i = 0; enif_get_list_cell(env, tail, &head, &tail); i++) {
        const ERL_NIF_TERM *t;
        int arity, pos, pad, vel, note;
        if (!enif_get_tuple(env, head, &arity, &t) || arity != 4 || !get_range(env, t[0], 0, p->length - 1, &pos) ||
            !get_range(env, t[1], 0, SP_PADS - 1, &pad) || !get_range(env, t[2], 1, 127, &vel) ||
            !get_range(env, t[3], -1, 127, &note)) {
            free(p);
            return enif_make_badarg(env);
        }
        p->steps[i] = (sp_step){pos, (uint8_t)pad, (uint8_t)vel, (int16_t)note};
    }
    sp_pattern_sort(p);

    pthread_mutex_lock(&E.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&E.ctl);
        free(p);
        return error_tuple(env, "not_owner");
    }
    p->id = ++E.patterns;
    sp_cmd c = {.type = SP_CMD_PATTERN, .u.pattern = {p, at_bar}};
    bool queued = ctl_push(&c);
    pthread_mutex_unlock(&E.ctl);
    if (!queued) {
        free(p);
        return error_tuple(env, "busy");
    }
    return enif_make_tuple2(env, ok_atom(env), enif_make_uint(env, p->id));
}

static ERL_NIF_TERM nif_set_tempo(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    double bpm;
    if (!get_number(env, argv[0], &bpm) || bpm < 20 || bpm > 400) return enif_make_badarg(env);
    sp_cmd c = {.type = SP_CMD_TEMPO, .u.value = bpm};
    return control(env, &c);
}

static ERL_NIF_TERM nif_set_swing(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    double swing;
    if (!get_number(env, argv[0], &swing) || swing < 0.5 || swing > 0.75) return enif_make_badarg(env);
    sp_cmd c = {.type = SP_CMD_SWING, .u.value = swing};
    return control(env, &c);
}

static ERL_NIF_TERM nif_play(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    sp_cmd c = {.type = SP_CMD_PLAY};
    return control(env, &c);
}

static ERL_NIF_TERM nif_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    sp_cmd c = {.type = SP_CMD_STOP};
    return control(env, &c);
}

/* trigger(Pad, Velocity, Quantize) -> ok | {error, not_running | busy}.
 * Quantize > 0: while the sequencer plays, start at the next point of a
 * Quantize-tick grid (24 a 16th, 96 a beat, 384 a bar). */
static ERL_NIF_TERM nif_trigger(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int pad, vel, quantize;
    if (!get_range(env, argv[0], 0, SP_PADS - 1, &pad) || !get_range(env, argv[1], 1, 127, &vel) ||
        !get_range(env, argv[2], 0, 4 * SP_BAR, &quantize))
        return enif_make_badarg(env);
    sp_cmd c = {.type = SP_CMD_TRIGGER, .pad = (uint8_t)pad, .vel = (uint8_t)vel, .quantize = quantize};
    return live(env, &c);
}

static ERL_NIF_TERM nif_release(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int pad;
    if (!get_range(env, argv[0], 0, SP_PADS - 1, &pad)) return enif_make_badarg(env);
    sp_cmd c = {.type = SP_CMD_RELEASE, .pad = (uint8_t)pad};
    return live(env, &c);
}

static ERL_NIF_TERM nif_note_on(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int pad, note, vel;
    if (!get_range(env, argv[0], 0, SP_PADS - 1, &pad) || !get_range(env, argv[1], 0, 127, &note) ||
        !get_range(env, argv[2], 1, 127, &vel))
        return enif_make_badarg(env);
    sp_cmd c = {.type = SP_CMD_NOTE_ON, .pad = (uint8_t)pad, .note = (uint8_t)note, .vel = (uint8_t)vel};
    return live(env, &c);
}

static ERL_NIF_TERM nif_note_off(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int pad, note;
    if (!get_range(env, argv[0], 0, SP_PADS - 1, &pad) || !get_range(env, argv[1], 0, 127, &note))
        return enif_make_badarg(env);
    sp_cmd c = {.type = SP_CMD_NOTE_OFF, .pad = (uint8_t)pad, .note = (uint8_t)note};
    return live(env, &c);
}

/* clock() -> #{frame, time, rate} | nil: engine frame `frame` is heard at
 * erlang:monotonic_time(nanosecond) `time`. */
static ERL_NIF_TERM nif_clock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    int64_t frame, ns;
    int rate = atomic_load(&E.rate);
    if (!sp_get_clock(&SP, &frame, &ns) || rate <= 0) return atom(env, "nil");
    int64_t offset = (int64_t)enif_monotonic_time(ERL_NIF_NSEC) - now_ns();
    ERL_NIF_TERM keys[3] = {atom(env, "frame"), atom(env, "time"), atom(env, "rate")};
    ERL_NIF_TERM vals[3] = {enif_make_int64(env, frame), enif_make_int64(env, ns + offset), enif_make_int(env, rate)};
    return make_map(env, keys, vals, 3);
}

static int cmp_float(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y;
}

static ERL_NIF_TERM latency_term(ErlNifEnv *env) {
    float v[LATENCIES];
    pthread_mutex_lock(&E.stats_lock);
    int n = E.latency_n < LATENCIES ? (int)E.latency_n : LATENCIES;
    memcpy(v, E.latency_ms, sizeof(float) * (size_t)n);
    int64_t count = E.latency_n;
    pthread_mutex_unlock(&E.stats_lock);
    if (n == 0) return atom(env, "nil");
    qsort(v, (size_t)n, sizeof(float), cmp_float);
    double sum = 0;
    for (int i = 0; i < n; i++) sum += v[i];
    ERL_NIF_TERM keys[6] = {atom(env, "count"), atom(env, "mean"), atom(env, "p50"),
                            atom(env, "p95"),   atom(env, "min"),  atom(env, "max")};
    ERL_NIF_TERM vals[6] = {enif_make_int64(env, count), enif_make_double(env, sum / n),
                            enif_make_double(env, v[n / 2]), enif_make_double(env, v[(n * 95) / 100 < n ? (n * 95) / 100 : n - 1]),
                            enif_make_double(env, v[0]), enif_make_double(env, v[n - 1])};
    return make_map(env, keys, vals, 6);
}

/* info() -> map of engine diagnostics. Dirty IO (takes `lock` to ask the
 * stream). */
static ERL_NIF_TERM nif_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    enum { N = 27 };
    pthread_mutex_lock(&E.lock);
    AAudioStream *s = E.out;
    int rate = atomic_load(&E.rate);
    double out_latency_ms = -1;
    int64_t pos, time;
    if (s && libs_ok && aa.getTimestamp(s, CLOCK_MONOTONIC, &pos, &time) == AA_OK && rate > 0) {
        double presented = (double)pos + (double)(now_ns() - time) * rate / 1e9;
        out_latency_ms = 1000.0 * ((double)aa.getFramesWritten(s) - presented) / rate;
    }
    int64_t cbs = atomic_load(&E.cb_count), cb_sum = atomic_load(&E.cb_ns_sum), cb_frames = atomic_load(&E.cb_frames);
    pthread_mutex_lock(&E.ctl);
    int samples = 0;
    for (int i = 0; i < SP_SLOTS; i++) samples += E.ids[i].loaded;
    pthread_mutex_unlock(&E.ctl);
    ERL_NIF_TERM keys[N] = {
        atom(env, "libraries"),       atom(env, "running"),          atom(env, "rate"),
        atom(env, "burst"),           atom(env, "buffer_frames"),    atom(env, "buffer_capacity"),
        atom(env, "low_latency"),     atom(env, "exclusive"),        atom(env, "device"),
        atom(env, "output_latency_ms"), atom(env, "underruns"),      atom(env, "reopens"),
        atom(env, "callbacks"),       atom(env, "callback_mean_us"), atom(env, "callback_max_us"),
        atom(env, "callback_gap_max_us"), atom(env, "cpu_load"),     atom(env, "voices_active"),
        atom(env, "voices_peak"),     atom(env, "steals"),           atom(env, "hard_cuts"),
        atom(env, "trigger_latency_ms"), atom(env, "samples"),       atom(env, "sample_bytes"),
        atom(env, "dropped"),         atom(env, "playing"),          atom(env, "frame"),
    };
    ERL_NIF_TERM dropped[3] = {enif_make_uint64(env, atomic_load(&SP.cmds_dropped)),
                               enif_make_uint64(env, atomic_load(&SP.events_dropped)),
                               enif_make_uint64(env, atomic_load(&SP.actions_dropped))};
    ERL_NIF_TERM dropped_keys[3] = {atom(env, "commands"), atom(env, "events"), atom(env, "actions")};
    ERL_NIF_TERM vals[N] = {
        libs_ok ? ok_atom(env) : atom(env, libs_error ? libs_error : "unknown"),
        atom(env, atomic_load(&E.running) ? "true" : "false"),
        enif_make_int(env, rate),
        enif_make_int(env, E.burst),
        enif_make_int(env, s ? aa.getBufferSizeInFrames(s) : 0),
        enif_make_int(env, E.capacity),
        atom(env, s && aa.getPerformanceMode(s) == AA_PERF_LOW_LATENCY ? "true" : "false"),
        atom(env, s && aa.getSharingMode(s) == AA_SHARING_EXCLUSIVE ? "true" : "false"),
        enif_make_int(env, s ? aa.getDeviceId(s) : 0),
        enif_make_double(env, out_latency_ms),
        enif_make_int(env, s ? aa.getXRunCount(s) : 0),
        enif_make_int64(env, atomic_load(&E.reopens)),
        enif_make_int64(env, cbs),
        enif_make_double(env, cbs ? (double)cb_sum / cbs / 1000.0 : 0),
        enif_make_double(env, atomic_load(&E.cb_ns_max) / 1000.0),
        enif_make_double(env, atomic_load(&E.cb_gap_max) / 1000.0),
        enif_make_double(env, cb_frames && rate ? (double)cb_sum / (1e9 * (double)cb_frames / rate) : 0),
        enif_make_int(env, atomic_load(&SP.voices_active)),
        enif_make_int(env, atomic_load(&SP.voices_peak)),
        enif_make_uint64(env, atomic_load(&SP.steals)),
        enif_make_uint64(env, atomic_load(&SP.hard_cuts)),
        latency_term(env),
        enif_make_int(env, samples),
        enif_make_int64(env, atomic_load(&E.sample_bytes)),
        make_map(env, dropped_keys, dropped, 3),
        atom(env, atomic_load(&SP.playing_now) ? "true" : "false"),
        enif_make_int64(env, atomic_load(&E.engine_frame)),
    };
    pthread_mutex_unlock(&E.lock);
    return make_map(env, keys, vals, N);
}

/* reset_stats() -> ok: callback timing, trigger latency, the voice peak,
 * steals and hard cuts start over (for measuring a stretch). */
static ERL_NIF_TERM nif_reset_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    atomic_store(&E.cb_count, 0);
    atomic_store(&E.cb_ns_sum, 0);
    atomic_store(&E.cb_ns_max, 0);
    atomic_store(&E.cb_gap_max, 0);
    atomic_store(&E.cb_frames, 0);
    atomic_store(&E.cb_last_start, 0);
    atomic_store(&SP.voices_peak, 0);
    atomic_store(&SP.steals, 0);
    atomic_store(&SP.hard_cuts, 0);
    pthread_mutex_lock(&E.stats_lock);
    E.latency_n = 0;
    pthread_mutex_unlock(&E.stats_lock);
    return ok_atom(env);
}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)env;
    (void)priv;
    (void)info;
    pthread_mutex_init(&E.lock, NULL);
    pthread_mutex_init(&E.ctl, NULL);
    pthread_mutex_init(&E.push, NULL);
    pthread_mutex_init(&E.jobs_lock, NULL);
    pthread_mutex_init(&E.stats_lock, NULL);
    pthread_cond_init(&E.jobs_cv, NULL);
    sp_init(&SP, DEFAULT_RATE);
    E.drains = true;
    libs_ok = bind_libraries();
    if (!libs_ok) LOGE("could not bind %s", libs_error);
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"open", 1, nif_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close", 0, nif_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"reset", 0, nif_reset, 0},
    {"load_pcm", 4, nif_load_pcm, 0},
    {"decode", 1, nif_decode, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"load_sample", 2, nif_load_sample, 0},
    {"unload_sample", 1, nif_unload_sample, 0},
    {"set_pad", 2, nif_set_pad, 0},
    {"set_pattern", 3, nif_set_pattern, 0},
    {"set_tempo", 1, nif_set_tempo, 0},
    {"set_swing", 1, nif_set_swing, 0},
    {"play", 0, nif_play, 0},
    {"stop", 0, nif_stop, 0},
    {"trigger", 3, nif_trigger, 0},
    {"release", 1, nif_release, 0},
    {"note_on", 3, nif_note_on, 0},
    {"note_off", 2, nif_note_off, 0},
    {"clock", 0, nif_clock, 0},
    {"info", 0, nif_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"reset_stats", 0, nif_reset_stats, 0},
};

ERL_NIF_INIT(Elixir.Magpie.Audio.Nif, nif_funcs, on_load, NULL, NULL, NULL)
