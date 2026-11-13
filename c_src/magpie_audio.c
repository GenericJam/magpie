/*
 * c_src/magpie_audio.c — Magpie's audio engine on Android: the sampler core
 * (sampler.c) behind an AAudio output stream, the recorder (recorder.c) on
 * an input (the mic, or other apps through plugins/magpie_capture), NDK
 * MediaCodec decoding, and the NIF (Magpie.Audio.Nif).
 *
 *   output callback  AAudio, low-latency performance mode, shared, stereo
 *                    float at the device's own rate. Runs sp_render: drains
 *                    the command queue, runs the sequencer and the count-in
 *                    clicks, mixes the voices.
 *   mic callback     AAudio input, low latency, mono at the output's rate:
 *                    feeds the recorder, each block stamped with when it
 *                    was captured (the input timestamp).
 *   capture thread   Kotlin's (MagpieCapture), for other apps: 16-bit
 *                    blocks into the recorder through native_write.
 *   event thread     Every 2 ms: turns the renderer's events into messages
 *                    for the owner (coalesced: one playhead and at most a
 *                    start and an end per pad per pass), frees retired
 *                    samples and patterns, refreshes the clock mappings
 *                    (getTimestamp, output and mic) every 20 ms, grows the
 *                    buffer by a burst after an underrun, reopens the stream
 *                    after a disconnect (headphones, Bluetooth), gives the
 *                    recorder the count-in's downbeat and sends the input's
 *                    meters.
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
 *   {magpie_audio, input, Input, started, #{source, rate, channels}}
 *   {magpie_audio, input, Input, closed, denied | stopped | disconnected | error}
 *   {magpie_audio, meter, Input, LevelDb, #{take, state, frames, peaks}}   every 40 ms with an input
 *   {magpie_audio, record, Take, started, #{pre_roll_frames, late_frames}}
 *   {magpie_audio, record, Take, full, Frames}
 *   {magpie_audio, count_in, Take, FirstFrame, DownbeatFrame}
 *
 * Input is the id input_open/1 returned, Take the one record_start/4
 * returned (the meter's take: nil while none is armed): a message about
 * an input or a take that is over can still be in a mailbox when the next
 * one starts. Frames are engine frames (rendered since the engine
 * started); clock/0 maps them onto erlang:monotonic_time/1.
 *
 * Control calls (samples, pads, patterns, tempo, play, reset, close, the
 * input and the recorder) are the owner's alone ({error, not_owner} for
 * anyone else); live calls (trigger, release, note_on, note_off) are open
 * to every process and only queue a command: they never wait on the stream.
 *
 * Locks, always taken in this order: lock → IN.lock → ctl → jobs_lock /
 * push → stats_lock. `lock` covers the stream's lifecycle (open, close,
 * reopen) and the NIFs that ask the stream (info); `IN.lock` the input's
 * lifecycle and the recorder's buffers. NIFs taking either run on dirty IO
 * schedulers. `ctl` covers the owner, the sample table and, while no stream
 * renders, the renderer's role (sp_drain). `push` serialises producers into
 * the command queue; the audio callbacks never take a lock.
 *
 * AAudio and libmediandk are opened with dlopen: the app links against
 * android-24 headers, where AAudio (API 26) doesn't exist, while the app's
 * minSdk is 28, so both libraries are always present at run time.
 */

#include <errno.h>
#include <dlfcn.h>
#include <erl_nif.h>
#include <fcntl.h>
#include <jni.h>
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
#include "recorder.c"

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
    AA_DIRECTION_INPUT = 1,
    AA_FORMAT_PCM_FLOAT = 2,
    AA_SHARING_EXCLUSIVE = 0,
    AA_SHARING_SHARED = 1,
    AA_PERF_LOW_LATENCY = 12,
    AA_USAGE_MEDIA = 1,
    AA_CONTENT_MUSIC = 2,
    AA_PRESET_VOICE_RECOGNITION = 6,
    AA_PRESET_UNPROCESSED = 9,
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
    void (*setSampleRate)(AAudioStreamBuilder *, int32_t);
    void (*setInputPreset)(AAudioStreamBuilder *, int32_t);
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
    int32_t (*getChannelCount)(AAudioStream *);
    int32_t (*getInputPreset)(AAudioStream *);
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
    BIND(aa, a, setSampleRate, "AAudioStreamBuilder_setSampleRate");
    BIND(aa, a, setInputPreset, "AAudioStreamBuilder_setInputPreset");
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
    BIND(aa, a, getChannelCount, "AAudioStream_getChannelCount");
    BIND(aa, a, getInputPreset, "AAudioStream_getInputPreset");
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

/* The input and the recorder (further down): the event thread refreshes
 * the input's clock, sends its meters and hands the count-in's downbeat
 * to the recorder. */
static void refresh_input_clock(void);
static void deliver_input(ErlNifEnv *env, int64_t now);
static void count_in_heard(ErlNifEnv *env, const ErlNifPid *owner, bool has_owner, const sp_event *ev);
static ERL_NIF_TERM input_info(ErlNifEnv *env);
static void midi_in_latency(const sp_event *ev);

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

    sp_event ev, head = {.type = 0xff}, tempo = {.type = 0xff};
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
            if (ev.b) midi_in_latency(&ev);
            else record_latency(&ev);
            break;
        case SP_EV_TRANSPORT:
            if (has_owner)
                send_owner(&owner, env,
                           enif_make_tuple4(env, tag(env), atom(env, "transport"), atom(env, ev.a ? "true" : "false"),
                                            enif_make_int64(env, ev.frame)));
            break;
        case SP_EV_TEMPO:
            tempo = ev;
            break;
        case SP_EV_COUNT_IN:
            count_in_heard(env, &owner, has_owner, &ev);
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
    if (tempo.type == SP_EV_TEMPO && has_owner)
        send_owner(&owner, env,
                   enif_make_tuple3(env, tag(env), atom(env, "tempo"), enif_make_double(env, tempo.a / 1000.0)));
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
        if (now >= next_clock) {
            if (atomic_load(&E.running)) {
                refresh_clock();
                tune_buffer();
            }
            refresh_input_clock();
            next_clock = now + CLOCK_PERIOD_NS;
        }
        deliver_events(env);
        deliver_input(env, now);
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

/* ── The input: the mic or other apps, into the recorder ─────────────────── *
 *
 * One input at a time feeds REC (recorder.c). The mic is an AAudio input
 * stream of its own (its callback is the producer), so recording never
 * touches the output callback; other apps are Android's playback capture
 * (MediaProjection + AudioRecord, API 29+) in Kotlin
 * (plugins/magpie_capture), whose read thread hands 16-bit PCM to
 * native_write. `IN.lock` covers the input's lifecycle and the recorder's
 * buffers (lock order in the header). Java is called with IN.lock held
 * (start/stop return without waiting on the UI thread); its callbacks
 * take IN.lock themselves, never from inside Kotlin's own lock, and
 * native_write takes no lock. */

#define CAPTURE_CLASS "com.genericjam.magpie.capture.MagpieCapture"
#define METER_PERIOD_NS 40000000LL
#define COUNT_IN_BEATS 4

extern JavaVM *g_jvm;
extern jobject g_activity;

enum { SRC_NONE, SRC_MIC, SRC_APPS };
enum { IN_CLOSED, IN_OPENING, IN_OPEN };

static rc_recorder REC;

static struct {
    pthread_mutex_t lock;
    _Atomic int source, status;
    /* The input's id: bumps on every open (the new input's id, which the
     * owner's messages and Kotlin's calls carry) and every close. */
    _Atomic int64_t gen;
    /* Open for the input's id while it is IN_OPEN: its producer (the mic's
     * callback, Kotlin's read thread) writes to REC only through it. */
    rc_gate gate;
    AAudioStream *mic; /* under lock */
    int preset;
    _Atomic bool mic_dead; /* its error callback ran: the event thread reports it */

    /* Input frame `clk_pos` was captured at CLOCK_MONOTONIC `clk_ns` (seqlock;
     * the event thread writes, the mic callback reads). */
    _Atomic uint32_t clk_seq;
    _Atomic int64_t clk_pos, clk_ns;
    int64_t cb_frames; /* mic callback's own: frames it has been handed */
    _Atomic int64_t callbacks, clock_misses, newest_ns;

    /* The recording, under lock. */
    bool armed, count_in, start_sent, full_sent;
    int64_t peaks_sent, next_meter;

    /* Java: MagpieCapture, found through the activity's class loader. */
    jclass cls;
    jmethodID start, stop;
} IN;

typedef struct {
    float *data;
} pcm_res;

static ErlNifResourceType *pcm_type;

static void pcm_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    free(((pcm_res *)obj)->data);
}

/* Send `msg` (built in `menv`) to the owner, then free `menv`. `caller`:
 * the NIF's env, or NULL on a thread of our own. */
static void tell_owner(ErlNifEnv *caller, ErlNifEnv *menv, ERL_NIF_TERM msg) {
    pthread_mutex_lock(&E.ctl);
    if (E.has_owner) enif_send(caller, &E.owner, menv, msg);
    pthread_mutex_unlock(&E.ctl);
    enif_free_env(menv);
}

static void tell_closed(ErlNifEnv *caller, int64_t id, const char *reason) {
    ErlNifEnv *m = enif_alloc_env();
    tell_owner(caller, m,
               enif_make_tuple5(m, tag(m), atom(m, "input"), enif_make_int64(m, id), atom(m, "closed"),
                                atom(m, reason)));
}

static void tell_started(ErlNifEnv *caller, int64_t id, const char *source, int rate, int channels) {
    ErlNifEnv *m = enif_alloc_env();
    ERL_NIF_TERM keys[3] = {atom(m, "source"), atom(m, "rate"), atom(m, "channels")};
    ERL_NIF_TERM vals[3] = {atom(m, source), enif_make_int(m, rate), enif_make_int(m, channels)};
    tell_owner(caller, m,
               enif_make_tuple5(m, tag(m), atom(m, "input"), enif_make_int64(m, id), atom(m, "started"),
                                make_map(m, keys, vals, 3)));
}

/* ── Java ── */

static JNIEnv *jni_env(bool *attached) {
    *attached = false;
    if (!g_jvm) return NULL;
    JNIEnv *j = NULL;
    jint rc = (*g_jvm)->GetEnv(g_jvm, (void **)&j, JNI_VERSION_1_6);
    if (rc == JNI_OK) return j;
    if (rc != JNI_EDETACHED || (*g_jvm)->AttachCurrentThread(g_jvm, &j, NULL) != JNI_OK) return NULL;
    *attached = true;
    return j;
}

static void jni_done(bool attached) {
    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
}

static bool jni_failed(JNIEnv *j) {
    if (!(*j)->ExceptionCheck(j)) return false;
    (*j)->ExceptionClear(j);
    return true;
}

static jmethodID method(JNIEnv *j, jclass cls, const char *name, const char *sig) {
    jmethodID id = cls ? (*j)->GetMethodID(j, cls, name, sig) : NULL;
    return jni_failed(j) ? NULL : id;
}

/* Whether the app holds RECORD_AUDIO (AAudio would open a silent stream
 * without it). True when Java can't be asked: the stream decides. */
static bool mic_permitted(void) {
    bool attached;
    JNIEnv *j = jni_env(&attached);
    if (!j || !g_activity) {
        if (j) jni_done(attached);
        return true;
    }
    bool ok = true;
    if ((*j)->PushLocalFrame(j, 8) == JNI_OK) {
        jmethodID check =
            method(j, (*j)->GetObjectClass(j, g_activity), "checkSelfPermission", "(Ljava/lang/String;)I");
        jstring name = (*j)->NewStringUTF(j, "android.permission.RECORD_AUDIO");
        if (check && name) {
            jint r = (*j)->CallIntMethod(j, g_activity, check, name);
            if (!jni_failed(j)) ok = r == 0; /* PERMISSION_GRANTED */
        }
        jni_failed(j);
        (*j)->PopLocalFrame(j, NULL);
    }
    jni_done(attached);
    return ok;
}

/* MagpieCapture.nativeStarted(session, rate, channels): capture runs; false
 * tells Kotlin to stop (nobody waits for it any more). Kotlin calls it
 * before its read thread starts. `session` is the input's id. */
static jboolean JNICALL native_started(JNIEnv *j, jclass cls, jlong session, jint rate, jint channels) {
    (void)j;
    (void)cls;
    pthread_mutex_lock(&IN.lock);
    bool current = session == atomic_load(&IN.gen) && atomic_load(&IN.source) == SRC_APPS &&
                   atomic_load(&IN.status) == IN_OPENING && rate > 0 &&
                   channels >= 1 && channels <= 2;
    if (current) {
        rc_init(&REC, rate, channels);
        atomic_store(&IN.status, IN_OPEN);
        rc_gate_open(&IN.gate, session);
        tell_started(NULL, session, "apps", rate, channels);
    }
    pthread_mutex_unlock(&IN.lock);
    LOGI("other apps: capture %s at %d Hz, %d channels", current ? "started" : "not wanted", rate, channels);
    return current ? JNI_TRUE : JNI_FALSE;
}

/* MagpieCapture.nativeWrite(session, buffer, frames, t0): 16-bit
 * interleaved PCM from a direct buffer, its first frame captured at `t0`
 * (System.nanoTime, CLOCK_MONOTONIC). The read thread; takes no lock. A
 * call for an input that is no longer open (a read thread that outlived
 * its stop) stops at the gate. */
static void JNICALL native_write(JNIEnv *j, jclass cls, jlong session, jobject buffer, jint frames, jlong t0) {
    (void)cls;
    static float scratch[2 * 1024]; /* the gate admits one input's thread */
    if (frames <= 0 || !rc_enter(&IN.gate, session)) return;
    const int16_t *pcm = (*j)->GetDirectBufferAddress(j, buffer);
    const int ch = REC.channels, rate = REC.rate;
    for (jint done = 0; pcm && done < frames;) {
        int n = frames - done > 1024 ? 1024 : frames - done;
        for (int i = 0; i < n * ch; i++) scratch[i] = pcm[(int64_t)done * ch + i] / 32768.0f;
        rc_write(&REC, scratch, n, t0 + (int64_t)((double)done * 1e9 / rate));
        done += n;
    }
    rc_leave(&IN.gate);
    if (!pcm) return;
    atomic_fetch_add(&IN.callbacks, 1);
    atomic_store(&IN.newest_ns, t0 + (int64_t)((double)frames * 1e9 / rate));
}

/* MagpieCapture.nativeEnded(session, reason): consent refused ("denied"),
 * the user stopped the projection ("stopped"), or capture failed
 * ("error"). The owner closes the input (input_close/0) to release it. */
static void JNICALL native_ended(JNIEnv *j, jclass cls, jlong session, jstring reason) {
    (void)cls;
    char why[16] = "error";
    const char *s = reason ? (*j)->GetStringUTFChars(j, reason, NULL) : NULL;
    if (s) {
        if (strcmp(s, "denied") == 0 || strcmp(s, "stopped") == 0) strcpy(why, s);
        (*j)->ReleaseStringUTFChars(j, reason, s);
    }
    pthread_mutex_lock(&IN.lock);
    bool current = session == atomic_load(&IN.gen) && atomic_load(&IN.source) == SRC_APPS &&
                   atomic_load(&IN.status) != IN_CLOSED;
    if (current) {
        atomic_store(&IN.status, IN_CLOSED);
        rc_gate_shut(&IN.gate);
        tell_closed(NULL, session, why);
    }
    pthread_mutex_unlock(&IN.lock);
    LOGI("other apps: ended (%s)%s", why, current ? "" : ", not current");
}

/* Find MagpieCapture through the activity's class loader (FindClass on a
 * native thread only sees the system's) and register its natives. Caller
 * holds IN.lock. */
static bool capture_bind(JNIEnv *j) {
    if (IN.cls) return true;
    if (!g_activity || (*j)->PushLocalFrame(j, 16) != JNI_OK) return false;
    bool ok = false;
    jmethodID get_loader =
        method(j, (*j)->GetObjectClass(j, g_activity), "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject loader = get_loader ? (*j)->CallObjectMethod(j, g_activity, get_loader) : NULL;
    if (jni_failed(j)) loader = NULL;
    jmethodID load_class =
        loader ? method(j, (*j)->GetObjectClass(j, loader), "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") : NULL;
    jclass cls = load_class ? (jclass)(*j)->CallObjectMethod(j, loader, load_class, (*j)->NewStringUTF(j, CAPTURE_CLASS))
                            : NULL;
    if (jni_failed(j)) cls = NULL;
    if (cls) {
        JNINativeMethod natives[] = {
            {"nativeStarted", "(JII)Z", (void *)native_started},
            {"nativeWrite", "(JLjava/nio/ByteBuffer;IJ)V", (void *)native_write},
            {"nativeEnded", "(JLjava/lang/String;)V", (void *)native_ended},
        };
        IN.start = (*j)->GetStaticMethodID(j, cls, "start", "(IJ)Ljava/lang/String;");
        if (jni_failed(j)) IN.start = NULL;
        IN.stop = (*j)->GetStaticMethodID(j, cls, "stop", "()V");
        if (jni_failed(j)) IN.stop = NULL;
        if (IN.start && IN.stop && (*j)->RegisterNatives(j, cls, natives, 3) == 0 && !jni_failed(j)) {
            IN.cls = (jclass)(*j)->NewGlobalRef(j, cls);
            ok = IN.cls != NULL;
        }
    }
    if (!ok) LOGE("other apps: %s not usable", CAPTURE_CLASS);
    (*j)->PopLocalFrame(j, NULL);
    return ok;
}

/* Ask Kotlin to start input `id`: NULL (the consent dialog is up; the
 * outcome comes through native_started / native_ended) or a reason.
 * Caller holds IN.lock. */
static const char *capture_start(int rate, int64_t id) {
    static char reason[24];
    bool attached;
    JNIEnv *j = jni_env(&attached);
    if (!j) return "unsupported";
    const char *failure = NULL;
    if (!capture_bind(j)) {
        failure = "unsupported";
    } else {
        jstring r = (jstring)(*j)->CallStaticObjectMethod(j, IN.cls, IN.start, (jint)rate, (jlong)id);
        if (jni_failed(j)) {
            failure = "error";
        } else if (r) {
            const char *s = (*j)->GetStringUTFChars(j, r, NULL);
            if (s && s[0]) {
                snprintf(reason, sizeof(reason), "%s", s);
                failure = reason;
            }
            if (s) (*j)->ReleaseStringUTFChars(j, r, s);
            (*j)->DeleteLocalRef(j, r);
        }
    }
    jni_done(attached);
    return failure;
}

/* Stop capture: Kotlin joins its read thread (for up to a second) before
 * returning; a native_write after it stops at the gate. Caller holds
 * IN.lock. */
static void capture_stop(void) {
    bool attached;
    JNIEnv *j = IN.cls ? jni_env(&attached) : NULL;
    if (!j) return;
    (*j)->CallStaticVoidMethod(j, IN.cls, IN.stop);
    jni_failed(j);
    jni_done(attached);
}

/* ── The mic ── */

static bool input_clock(int64_t *pos, int64_t *ns) {
    for (int tries = 0; tries < 4; tries++) {
        uint32_t a = atomic_load_explicit(&IN.clk_seq, memory_order_acquire);
        int64_t p = atomic_load_explicit(&IN.clk_pos, memory_order_relaxed);
        int64_t t = atomic_load_explicit(&IN.clk_ns, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (!(a & 1) && a == atomic_load_explicit(&IN.clk_seq, memory_order_relaxed)) {
            *pos = p;
            *ns = t;
            return t > 0;
        }
    }
    return false;
}

/* The mic's callback: its frames go to the recorder, stamped with when
 * they were captured (the input timestamp; before the first one, "just
 * now"). Frame k of the stream is the k-th the callback is handed.
 * `user` is the input's id: a stream closed under it (one that wouldn't
 * stop) stops at the gate. */
static int32_t mic_cb(AAudioStream *s, void *user, void *data, int32_t frames) {
    (void)s;
    if (!rc_enter(&IN.gate, (int64_t)(intptr_t)user)) return AA_CALLBACK_CONTINUE;
    const int rate = REC.rate;
    int64_t pos, ns, t0;
    if (input_clock(&pos, &ns)) {
        t0 = ns + (int64_t)((double)(IN.cb_frames - pos) * 1e9 / rate);
    } else {
        t0 = now_ns() - (int64_t)((double)frames * 1e9 / rate);
        atomic_fetch_add_explicit(&IN.clock_misses, 1, memory_order_relaxed);
    }
    rc_write(&REC, data, frames, t0);
    IN.cb_frames += frames;
    rc_leave(&IN.gate);
    atomic_fetch_add_explicit(&IN.callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&IN.newest_ns, t0 + (int64_t)((double)frames * 1e9 / rate), memory_order_relaxed);
    return AA_CALLBACK_CONTINUE;
}

/* `user` is the input's id, as for mic_cb: only the open mic's error counts. */
static void mic_error_cb(AAudioStream *s, void *user, aaudio_result_t err) {
    (void)s;
    LOGE("mic stream error %d", err);
    if ((int64_t)(intptr_t)user == atomic_load(&IN.gen)) atomic_store(&IN.mic_dead, true);
}

static aaudio_result_t open_mic(int rate, int preset, int64_t id) {
    AAudioStreamBuilder *b;
    aaudio_result_t r = aa.createStreamBuilder(&b);
    if (r != AA_OK) return r;
    aa.setDirection(b, AA_DIRECTION_INPUT);
    aa.setSampleRate(b, rate);
    aa.setChannelCount(b, 1);
    aa.setFormat(b, AA_FORMAT_PCM_FLOAT);
    aa.setSharingMode(b, AA_SHARING_SHARED);
    aa.setPerformanceMode(b, AA_PERF_LOW_LATENCY);
    aa.setInputPreset(b, preset);
    aa.setDataCallback(b, mic_cb, (void *)(intptr_t)id);
    aa.setErrorCallback(b, mic_error_cb, (void *)(intptr_t)id);
    r = aa.openStream(b, &IN.mic);
    aa.builderDelete(b);
    return r;
}

/* The event thread, every 20 ms: the mic's timestamp. */
static void refresh_input_clock(void) {
    if (atomic_load(&IN.source) != SRC_MIC || pthread_mutex_trylock(&IN.lock) != 0) return;
    int64_t pos, ns;
    if (IN.mic && atomic_load(&IN.status) == IN_OPEN && aa.getTimestamp(IN.mic, CLOCK_MONOTONIC, &pos, &ns) == AA_OK) {
        uint32_t s = atomic_load_explicit(&IN.clk_seq, memory_order_relaxed);
        atomic_store_explicit(&IN.clk_seq, s + 1, memory_order_relaxed);
        atomic_thread_fence(memory_order_release);
        atomic_store_explicit(&IN.clk_pos, pos, memory_order_relaxed);
        atomic_store_explicit(&IN.clk_ns, ns, memory_order_relaxed);
        atomic_store_explicit(&IN.clk_seq, s + 2, memory_order_release);
    }
    pthread_mutex_unlock(&IN.lock);
}

/* ── The recording ── */

static void cancel_count_in_locked(void) {
    if (!IN.count_in) return;
    IN.count_in = false;
    sp_cmd c = {.type = SP_CMD_COUNT_IN, .u.count_in = {0, 0}};
    pthread_mutex_lock(&E.ctl);
    ctl_push(&c);
    pthread_mutex_unlock(&E.ctl);
}

/* Disarm and drop what was recorded. Caller holds IN.lock. */
static void drop_recording_locked(void) {
    if (!IN.armed) return;
    rc_finish(&REC);
    cancel_count_in_locked();
    rc_free_buffers(&REC);
    IN.armed = false;
    IN.peaks_sent = 0;
}

/* Close whatever input is open; no producer writes to REC once its gate is
 * shut, the first thing here. False when the mic stream wouldn't stop: it
 * stays allocated (closed to the owner, shut out of the recorder) for the
 * next close to try again. Caller holds IN.lock. */
static bool close_input_locked(void) {
    int source = atomic_load(&IN.source);
    atomic_store(&IN.status, IN_CLOSED);
    rc_gate_shut(&IN.gate);
    drop_recording_locked();
    if (source == SRC_MIC && IN.mic) {
        if (!stop_stream(IN.mic)) return false;
        aa.close(IN.mic);
        IN.mic = NULL;
    } else if (source == SRC_APPS) {
        capture_stop();
    }
    atomic_store(&IN.source, SRC_NONE);
    atomic_fetch_add(&IN.gen, 1); /* late calls and events from that input are stale */
    atomic_store(&IN.mic_dead, false);
    return true;
}

/* The event thread, on the count-in's event: the recorder starts with the
 * audio captured when the downbeat is heard (if that take is still armed;
 * the recorder ignores an earlier one's); the owner hears of the beats. */
static void count_in_heard(ErlNifEnv *env, const ErlNifPid *owner, bool has_owner, const sp_event *ev) {
    int rate = atomic_load(&E.rate);
    int64_t cf, cns, heard;
    if (sp_get_clock(&SP, &cf, &cns) && rate > 0) {
        heard = cns + (int64_t)((double)(ev->until - cf) * 1e9 / rate);
    } else {
        int64_t ahead = ev->until - atomic_load(&E.engine_frame) + atomic_load(&SP.latency_frames);
        heard = now_ns() + (int64_t)((double)ahead * 1e9 / (rate > 0 ? rate : DEFAULT_RATE));
    }
    rc_start_at(&REC, (uint32_t)ev->a, heard);
    if (has_owner)
        send_owner(owner, env,
                   enif_make_tuple5(env, tag(env), atom(env, "count_in"), enif_make_uint(env, (uint32_t)ev->a),
                                    enif_make_int64(env, ev->frame), enif_make_int64(env, ev->until)));
}

static const char *rec_state_name(int state) {
    switch (state) {
    case RC_WAIT_SOUND: return "waiting";
    case RC_WAIT_TIME: return "counting";
    case RC_RECORDING: return "recording";
    case RC_FULL: return "full";
    default: return "idle";
    }
}

/* The take a message is about: armed, REC.gen (both change only under
 * IN.lock, which the caller holds); nil while none is. */
static ERL_NIF_TERM take_term(ErlNifEnv *env) {
    return IN.armed ? enif_make_uint(env, atomic_load(&REC.gen)) : atom(env, "nil");
}

/* The event thread, every pass: a dead mic, the recording's start and end,
 * and every METER_PERIOD_NS the level and the new peaks. */
static void deliver_input(ErlNifEnv *env, int64_t now) {
    if (atomic_load(&IN.source) == SRC_NONE || pthread_mutex_trylock(&IN.lock) != 0) return;
    pthread_mutex_lock(&E.ctl);
    bool has_owner = E.has_owner;
    ErlNifPid owner = E.owner;
    pthread_mutex_unlock(&E.ctl);

    int64_t id = atomic_load(&IN.gen);
    if (atomic_load(&IN.source) == SRC_MIC && atomic_exchange(&IN.mic_dead, false) &&
        atomic_load(&IN.status) == IN_OPEN) {
        atomic_store(&IN.status, IN_CLOSED);
        rc_gate_shut(&IN.gate);
        if (has_owner)
            send_owner(&owner, env,
                       enif_make_tuple5(env, tag(env), atom(env, "input"), enif_make_int64(env, id), atom(env, "closed"),
                                        atom(env, "disconnected")));
    }
    if (atomic_load(&IN.status) == IN_OPEN && has_owner) {
        int state = atomic_load(&REC.state);
        int64_t started = atomic_load(&REC.started_at);
        if (IN.armed && !IN.start_sent && started >= 0) {
            IN.start_sent = true;
            int64_t trigger = atomic_load(&REC.trigger_at);
            ERL_NIF_TERM keys[2] = {atom(env, "pre_roll_frames"), atom(env, "late_frames")};
            ERL_NIF_TERM vals[2] = {enif_make_int64(env, trigger > started ? trigger - started : 0),
                                    enif_make_int64(env, started > trigger ? started - trigger : 0)};
            send_owner(&owner, env,
                       enif_make_tuple5(env, tag(env), atom(env, "record"), take_term(env), atom(env, "started"),
                                        make_map(env, keys, vals, 2)));
        }
        if (IN.armed && !IN.full_sent && state == RC_FULL) {
            IN.full_sent = true;
            send_owner(&owner, env,
                       enif_make_tuple5(env, tag(env), atom(env, "record"), take_term(env), atom(env, "full"),
                                        enif_make_int64(env, atomic_load(&REC.frames))));
        }
        if (now >= IN.next_meter) {
            IN.next_meter = now + METER_PERIOD_NS;
            int64_t frames = IN.armed ? atomic_load(&REC.frames) : 0;
            int64_t peaks = IN.armed ? atomic_load(&REC.peak_bytes) : 0;
            ERL_NIF_TERM fresh;
            int64_t fresh_n = peaks > IN.peaks_sent ? peaks - IN.peaks_sent : 0;
            unsigned char *p = enif_make_new_binary(env, (size_t)fresh_n, &fresh);
            if (fresh_n > 0) memcpy(p, REC.peaks + IN.peaks_sent, (size_t)fresh_n);
            if (IN.armed) IN.peaks_sent = peaks;
            ERL_NIF_TERM keys[4] = {atom(env, "take"), atom(env, "state"), atom(env, "frames"), atom(env, "peaks")};
            ERL_NIF_TERM vals[4] = {take_term(env), atom(env, IN.armed ? rec_state_name(state) : "idle"),
                                    enif_make_int64(env, frames), fresh};
            send_owner(&owner, env,
                       enif_make_tuple5(env, tag(env), atom(env, "meter"), enif_make_int64(env, id),
                                        enif_make_double(env, rc_db(rc_take_level(&REC))), make_map(env, keys, vals, 4)));
        }
    }
    pthread_mutex_unlock(&IN.lock);
}

/* ── MIDI ────────────────────────────────────────────────────────────────── */

/* Kotlin (plugins/magpie_midi) holds the ports and devices; no MIDI byte
 * passes through the BEAM. In: each receiver hands its bytes and their
 * timestamp to native_in, which parses them (one parser per source, under
 * the source's lock) and queues one SP_CMD_MIDI per message. Out:
 * the renderer stamps messages with engine frames into SP.midi.out; the
 * sending thread turns each frame into CLOCK_MONOTONIC through the output
 * timestamp, sleeps until then and calls MagpieMidi.send with that time.
 * Device events (tag, JSON) go to the listener as {magpie_midi, Tag, Json}. */

#define MIDI_CLASS "com.genericjam.magpie.midi.MagpieMidi"
#define MIDI_SOURCES 16
#define MIDI_LATE_CLOCK_NS 20000000LL /* a tick this late is dropped, not sent in a burst */
#define MIDI_BATCH_NS 100000LL        /* messages this close together go in one send */
#define MIDI_SEND_MAX 256
#define MIDI_STATS 512

/* A source's parser, fed only by the port with the highest generation seen
 * on it so far (see native_in). */
typedef struct {
    pthread_mutex_t lock;
    int64_t generation;
    mi_parser parser;
} midi_source;

static struct {
    pthread_mutex_t lock; /* the class and its methods once bound, the listener */
    jclass cls;
    jmethodID attach, send, devices, open, close, ble_scan, ble_connect, ble_disconnect;
    ErlNifPid listener;
    bool has_listener;
    midi_source sources[MIDI_SOURCES];
    /* The sending thread: started and joined under E.lock. */
    pthread_t out;
    bool out_started;
    _Atomic bool out_run;
    /* Notes left in the out queue by an earlier stream (midi_start_locked
     * fills it, the new thread sends it). */
    mo_event stale[MO_RING];
    int n_stale;
    _Atomic uint64_t received, sent, late_dropped;
    /* Under E.stats_lock: send time − stamp (µs); MIDI timestamp → heard (ms). */
    float late_us[MIDI_STATS], in_ms[MIDI_STATS];
    int64_t late_n, in_n;
} MI;

typedef struct {
    int64_t t_ns;
    uint8_t src;
} midi_ctx;

/* With no stream rendering, the control path renders: now, if it does
 * (else the stream being reopened does first). */
static void midi_drain_offline(void) {
    if (atomic_load(&E.running)) return;
    pthread_mutex_lock(&E.ctl);
    if (E.drains) sp_drain(&SP, false);
    pthread_mutex_unlock(&E.ctl);
}

/* What input `source` held ends: SP_CMD_MIDI_GONE in the command queue, so
 * after what the input sent before; if the full queue refuses it, a bit the
 * renderer applies after the commands queued by then (never lost). */
static void source_gone(int source) {
    sp_cmd c = {.type = SP_CMD_MIDI_GONE, .u.midi = {.src = (uint8_t)source}};
    if (!push_cmd(&c)) atomic_fetch_or(&SP.midi.gone, 1u << source);
    midi_drain_offline();
}

/* With no stream only what releases voices goes (a note-off, CC 120/123),
 * applied offline: a note held across a route change still ends. A release
 * the full command queue refuses ends everything its input holds instead
 * (source_gone): an early end, never a stuck note. */
static void midi_emit(void *ctx, mi_msg m) {
    atomic_fetch_add_explicit(&MI.received, 1, memory_order_relaxed);
    const midi_ctx *x = ctx;
    sp_cmd c = {.type = SP_CMD_MIDI, .u.midi = {m.status, m.d1, m.d2, x->src}, .t_ns = x->t_ns};
    uint8_t kind = m.status & 0xF0;
    bool release = m.status < 0xF0 && (kind == 0x80 || (kind == 0x90 && m.d2 == 0) ||
                                       (kind == 0xB0 && (m.d1 == 120 || m.d1 == 123)));
    if (!atomic_load(&E.running) && !release) return;
    if (!push_cmd(&c)) {
        if (release) source_gone(x->src);
        return;
    }
    if (release) midi_drain_offline();
}

/* Under the source's lock: `generation` becomes current, from a fresh
 * parser. True if it is newer: the port that had the source is done. */
static bool source_renew_locked(midi_source *s, int64_t generation) {
    if (generation <= s->generation) return false;
    s->generation = generation;
    s->parser = (mi_parser){0};
    return true;
}

/* MagpieMidi.nativeIn(source, generation, data, offset, count, timestamp): a
 * receiver's thread. Kotlin gives a source a new, higher generation when a
 * port takes it, when it is given back and when the Magpie port's service
 * is created, and tells C (nativeActivate) before the port can deliver.
 * Under the source's lock, a newer generation starts a fresh parser (no
 * running status or SysEx left by the port that had the source before) and
 * an older one's bytes are dropped (a closed port's thread delivering a
 * last message). So two threads never parse on one source at once, and one
 * port's bytes never land in another's stream. A timestamp of 0 (senders
 * that don't stamp) or more than a second off isn't System.nanoTime: the
 * message counts as arriving now. */
static void JNICALL native_in(JNIEnv *j, jclass cls, jint source, jlong generation, jbyteArray data, jint offset,
                              jint count, jlong timestamp) {
    (void)cls;
    if (source < 0 || source >= MIDI_SOURCES || count <= 0 || !data) return;
    int64_t now = now_ns();
    midi_ctx ctx = {.t_ns = timestamp > now - 1000000000LL && timestamp < now + 1000000000LL ? timestamp : now,
                    .src = (uint8_t)source};
    uint8_t buf[256];
    midi_source *s = &MI.sources[source];
    pthread_mutex_lock(&s->lock);
    if (source_renew_locked(s, generation)) source_gone(source);
    for (jint done = 0; generation == s->generation && done < count;) {
        jint n = count - done > (jint)sizeof(buf) ? (jint)sizeof(buf) : count - done;
        (*j)->GetByteArrayRegion(j, data, offset + done, n, (jbyte *)buf);
        if (jni_failed(j)) break;
        mi_parse(&s->parser, buf, n, midi_emit, &ctx);
        done += n;
    }
    pthread_mutex_unlock(&s->lock);
}

/* MagpieMidi.nativeActivate(source, generation): from now on only that
 * generation's bytes are parsed on the source, from a fresh parser; what
 * the port that had it held ends. */
static void JNICALL native_activate(JNIEnv *j, jclass cls, jint source, jlong generation) {
    (void)j;
    (void)cls;
    if (source < 0 || source >= MIDI_SOURCES) return;
    midi_source *s = &MI.sources[source];
    pthread_mutex_lock(&s->lock);
    if (source_renew_locked(s, generation)) source_gone(source);
    pthread_mutex_unlock(&s->lock);
}

/* MagpieMidi.nativeEvent(tag, json): a device event for the listener. */
static void JNICALL native_event(JNIEnv *j, jclass cls, jstring tag, jbyteArray json) {
    (void)cls;
    const char *t = tag ? (*j)->GetStringUTFChars(j, tag, NULL) : NULL;
    if (!t) return;
    ErlNifEnv *m = enif_alloc_env();
    jsize len = json ? (*j)->GetArrayLength(j, json) : 0;
    ERL_NIF_TERM bin;
    unsigned char *p = enif_make_new_binary(m, (size_t)len, &bin);
    if (len > 0) (*j)->GetByteArrayRegion(j, json, 0, len, (jbyte *)p);
    ERL_NIF_TERM msg = enif_make_tuple3(m, atom(m, "magpie_midi"), atom(m, t), bin);
    (*j)->ReleaseStringUTFChars(j, tag, t);
    if (!jni_failed(j)) {
        pthread_mutex_lock(&MI.lock);
        if (MI.has_listener) enif_send(NULL, &MI.listener, m, msg);
        pthread_mutex_unlock(&MI.lock);
    }
    enif_free_env(m);
}

static jmethodID static_method(JNIEnv *j, jclass cls, const char *name, const char *sig) {
    jmethodID id = (*j)->GetStaticMethodID(j, cls, name, sig);
    return jni_failed(j) ? NULL : id;
}

/* Find MagpieMidi through the activity's class loader, register its natives
 * and tell it (attach) that they are there. Takes MI.lock; attach is
 * called after it is released (it sends an event, which takes it). */
static bool midi_bind(JNIEnv *j) {
    pthread_mutex_lock(&MI.lock);
    if (MI.cls) {
        pthread_mutex_unlock(&MI.lock);
        return true;
    }
    bool ok = false;
    if (g_activity && (*j)->PushLocalFrame(j, 16) == JNI_OK) {
        jmethodID get_loader =
            method(j, (*j)->GetObjectClass(j, g_activity), "getClassLoader", "()Ljava/lang/ClassLoader;");
        jobject loader = get_loader ? (*j)->CallObjectMethod(j, g_activity, get_loader) : NULL;
        if (jni_failed(j)) loader = NULL;
        jmethodID load_class = loader ? method(j, (*j)->GetObjectClass(j, loader), "loadClass",
                                               "(Ljava/lang/String;)Ljava/lang/Class;")
                                      : NULL;
        jclass cls =
            load_class ? (jclass)(*j)->CallObjectMethod(j, loader, load_class, (*j)->NewStringUTF(j, MIDI_CLASS)) : NULL;
        if (jni_failed(j)) cls = NULL;
        if (cls) {
            JNINativeMethod natives[] = {
                {"nativeIn", "(IJ[BIIJ)V", (void *)native_in},
                {"nativeActivate", "(IJ)V", (void *)native_activate},
                {"nativeEvent", "(Ljava/lang/String;[B)V", (void *)native_event},
            };
            MI.attach = static_method(j, cls, "attach", "()V");
            MI.send = static_method(j, cls, "send", "([BIJ)V");
            MI.devices = static_method(j, cls, "devices", "()[B");
            MI.open = static_method(j, cls, "open", "(I)Ljava/lang/String;");
            MI.close = static_method(j, cls, "close", "(I)V");
            MI.ble_scan = static_method(j, cls, "bleScan", "(I)Ljava/lang/String;");
            MI.ble_connect = static_method(j, cls, "bleConnect", "(Ljava/lang/String;)Ljava/lang/String;");
            MI.ble_disconnect = static_method(j, cls, "bleDisconnect", "(Ljava/lang/String;)V");
            if (MI.attach && MI.send && MI.devices && MI.open && MI.close && MI.ble_scan && MI.ble_connect &&
                MI.ble_disconnect && (*j)->RegisterNatives(j, cls, natives, 3) == 0 && !jni_failed(j)) {
                MI.cls = (jclass)(*j)->NewGlobalRef(j, cls);
                ok = MI.cls != NULL;
            }
        }
        (*j)->PopLocalFrame(j, NULL);
    }
    jclass bound = MI.cls;
    jmethodID attach = MI.attach;
    pthread_mutex_unlock(&MI.lock);
    if (ok) {
        (*j)->CallStaticVoidMethod(j, bound, attach);
        jni_failed(j);
        LOGI("midi: bound");
    } else {
        LOGE("midi: %s not usable", MIDI_CLASS);
    }
    return ok;
}

/* MIDI bound (binding it if it isn't), with a JNI env for this thread;
 * NULL without. Pair with jni_done. */
static JNIEnv *midi_env(bool *attached) {
    JNIEnv *j = jni_env(attached);
    if (!j) return NULL;
    if (!midi_bind(j)) {
        jni_done(*attached);
        return NULL;
    }
    return j;
}

/* The sending thread's copy of the clock map: a read that loses to the
 * event thread's update (sp_get_clock gives up rather than spin) uses the
 * last one instead of sending early. */
typedef struct {
    int64_t frame, ns;
    int rate;
} midi_clock;

/* When engine frame `frame` is heard (CLOCK_MONOTONIC), or now before
 * there has been a timestamp. */
static int64_t frame_ns(midi_clock *c, int64_t frame) {
    int64_t cf, cns;
    int rate = atomic_load(&E.rate);
    if (sp_get_clock(&SP, &cf, &cns) && rate > 0) *c = (midi_clock){cf, cns, rate};
    if (c->rate <= 0) return now_ns();
    return c->ns + (int64_t)((double)(frame - c->frame) * 1e9 / c->rate);
}

static void sleep_until(int64_t t) {
    struct timespec ts = {.tv_sec = (time_t)(t / 1000000000LL), .tv_nsec = (long)(t % 1000000000LL)};
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR) {
    }
}

static void stat_push(float *ring, int64_t *n, float v) {
    pthread_mutex_lock(&E.stats_lock);
    ring[(*n)++ % MIDI_STATS] = v;
    pthread_mutex_unlock(&E.stats_lock);
}

/* The sending thread: each message at the time it is heard, stamped with
 * it. Messages within MIDI_BATCH_NS of the first go in the same send. A
 * tick more than MIDI_LATE_CLOCK_NS late is dropped (a stalled client
 * would otherwise get a burst of clock); notes go however late. */
static void *midi_out_main(void *arg) {
    (void)arg;
    if (setpriority(PRIO_PROCESS, (id_t)gettid(), -19) != 0) LOGE("midi: could not raise the sending thread's priority");
    JNIEnv *j = NULL;
    if (!g_jvm || (*g_jvm)->AttachCurrentThreadAsDaemon(g_jvm, &j, NULL) != JNI_OK) {
        LOGE("midi: the sending thread has no JVM");
        return NULL;
    }
    jbyteArray local = (*j)->NewByteArray(j, MIDI_SEND_MAX);
    jbyteArray arr = local ? (jbyteArray)(*j)->NewGlobalRef(j, local) : NULL;
    if (local) (*j)->DeleteLocalRef(j, local);
    uint8_t buf[MIDI_SEND_MAX];
    midi_clock clk = {0, 0, 0};
    for (int i = 0; arr && i < MI.n_stale;) {
        int n = 0, count = 0;
        for (; i < MI.n_stale && n + MI.stale[i].len <= MIDI_SEND_MAX; i++, count++) {
            memcpy(buf + n, MI.stale[i].b, MI.stale[i].len);
            n += MI.stale[i].len;
        }
        (*j)->SetByteArrayRegion(j, arr, 0, n, (const jbyte *)buf);
        (*j)->CallStaticVoidMethod(j, MI.cls, MI.send, arr, (jint)n, (jlong)now_ns());
        jni_failed(j);
        atomic_fetch_add_explicit(&MI.sent, (uint64_t)count, memory_order_relaxed);
    }
    MI.n_stale = 0;
    while (arr && atomic_load(&MI.out_run)) {
        mo_event ev;
        if (!mo_peek(&SP.midi.out, &ev)) {
            usleep(1000);
            continue;
        }
        int64_t t = frame_ns(&clk, ev.frame), now = now_ns();
        if (t - now > 5000000LL) {
            /* Far ahead (the stream renders ~20–40 ms ahead): look again
             * shortly, so a stop doesn't wait and the clock map stays fresh. */
            usleep(2000);
            continue;
        }
        if (t > now) sleep_until(t);
        int n = 0, count = 0;
        while (mo_peek(&SP.midi.out, &ev) && n + ev.len <= MIDI_SEND_MAX) {
            int64_t te = frame_ns(&clk, ev.frame);
            if (te > t + MIDI_BATCH_NS) break;
            mo_drop(&SP.midi.out);
            if (ev.kind == MO_CLOCK && now_ns() - te > MIDI_LATE_CLOCK_NS) {
                atomic_fetch_add_explicit(&MI.late_dropped, 1, memory_order_relaxed);
                continue;
            }
            memcpy(buf + n, ev.b, ev.len);
            n += ev.len;
            count++;
        }
        if (n == 0) continue;
        (*j)->SetByteArrayRegion(j, arr, 0, n, (const jbyte *)buf);
        int64_t sent_at = now_ns();
        (*j)->CallStaticVoidMethod(j, MI.cls, MI.send, arr, (jint)n, (jlong)t);
        jni_failed(j);
        atomic_fetch_add_explicit(&MI.sent, (uint64_t)count, memory_order_relaxed);
        stat_push(MI.late_us, &MI.late_n, (float)((sent_at - t) / 1000.0));
    }
    if (arr) (*j)->DeleteGlobalRef(j, arr);
    (*g_jvm)->DetachCurrentThread(g_jvm);
    return NULL;
}

/* Bind MIDI and start the sending thread. What is left in the out queue
 * from an earlier stream is stale: the notes whose other half went out go
 * first, at once (mo_take_stale: a note-on that went out keeps its note-off,
 * a voice still holding its note gets its note-on), the rest is dropped.
 * Caller holds E.lock; the queue has no consumer until the thread starts. */
static void midi_start_locked(void) {
    bool attached;
    JNIEnv *j = midi_env(&attached);
    if (!j) return;
    jni_done(attached);
    if (MI.out_started) return;
    MI.n_stale = mo_take_stale(&SP.midi.out, MI.stale);
    atomic_store(&MI.out_run, true);
    MI.out_started = pthread_create(&MI.out, NULL, midi_out_main, NULL) == 0;
    if (!MI.out_started) {
        atomic_store(&MI.out_run, false);
        LOGE("midi: no sending thread");
    }
}

/* Caller holds E.lock. */
static void midi_stop_locked(void) {
    if (!MI.out_started) return;
    atomic_store(&MI.out_run, false);
    pthread_join(MI.out, NULL);
    MI.out_started = false;
}

/* The event thread: a MIDI note's timestamp → when its voice is heard. */
static void midi_in_latency(const sp_event *ev) {
    int64_t cf, cns;
    int rate = atomic_load(&E.rate);
    if (!sp_get_clock(&SP, &cf, &cns) || rate <= 0) return;
    double heard_ns = (double)cns + (double)(ev->frame - cf) * 1e9 / rate;
    stat_push(MI.in_ms, &MI.in_n, (float)((heard_ns - (double)ev->t_ns) / 1e6));
}

static ERL_NIF_TERM ring_term(ErlNifEnv *env, const float *ring, const int64_t *count_at, int size);

static ERL_NIF_TERM midi_info(ErlNifEnv *env) {
    ERL_NIF_TERM keys[9] = {atom(env, "bound"),        atom(env, "received"),         atom(env, "applied"),
                            atom(env, "sent"),         atom(env, "out_dropped"),      atom(env, "late_ticks_dropped"),
                            atom(env, "in_latency_ms"), atom(env, "out_late_us"),     atom(env, "follow_bpm")};
    int64_t milli = atomic_load(&SP.midi.follow_bpm_milli);
    ERL_NIF_TERM vals[9] = {atom(env, MI.cls ? "true" : "false"),
                            enif_make_uint64(env, atomic_load(&MI.received)),
                            enif_make_uint64(env, atomic_load(&SP.midi.in_messages)),
                            enif_make_uint64(env, atomic_load(&MI.sent)),
                            enif_make_uint64(env, atomic_load(&SP.midi.out.dropped)),
                            enif_make_uint64(env, atomic_load(&MI.late_dropped)),
                            ring_term(env, MI.in_ms, &MI.in_n, MIDI_STATS),
                            ring_term(env, MI.late_us, &MI.late_n, MIDI_STATS),
                            milli > 0 ? enif_make_double(env, milli / 1000.0) : atom(env, "nil")};
    return make_map(env, keys, vals, 9);
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
    midi_start_locked();
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
    midi_stop_locked();
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
 * Reverse, FadeInMs, FadeOutMs, Mode, Choke, Root}, Stop) -> ok | {error,
 * not_owner | unknown_sample | busy}. EndFrame 0: to the sample's end.
 * Stop: the pad's sounding voices fade and its waiting quantized launches
 * go, in the same step as the change (with no stream too). */
static ERL_NIF_TERM nif_set_pad(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int pad, arity, choke, root;
    const ERL_NIF_TERM *t;
    ErlNifSInt64 start, end;
    double gain_db, pitch, fade_in, fade_out;
    bool reverse, stop;
    uint8_t mode;
    if (!get_range(env, argv[0], 0, SP_PADS - 1, &pad) || !enif_get_tuple(env, argv[1], &arity, &t) || arity != 11 ||
        !enif_get_int64(env, t[1], &start) || !enif_get_int64(env, t[2], &end) || !get_number(env, t[3], &gain_db) ||
        !get_number(env, t[4], &pitch) || !get_bool(env, t[5], &reverse) || !get_number(env, t[6], &fade_in) ||
        !get_number(env, t[7], &fade_out) || !get_mode(env, t[8], &mode) || !get_range(env, t[9], 0, 3, &choke) ||
        !get_range(env, t[10], 0, 127, &root) || !get_bool(env, argv[2], &stop) || start < 0 || end < 0 ||
        fade_in < 0 || fade_out < 0)
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
                .stop = stop,
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

/* The newest `size` values of a stats ring (under stats_lock) as count,
 * mean, p50, p95, min and max; nil when empty. */
static ERL_NIF_TERM ring_term(ErlNifEnv *env, const float *ring, const int64_t *count_at, int size) {
    float v[MIDI_STATS > LATENCIES ? MIDI_STATS : LATENCIES];
    pthread_mutex_lock(&E.stats_lock);
    int64_t count = *count_at;
    int n = count < size ? (int)count : size;
    memcpy(v, ring, sizeof(float) * (size_t)n);
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

static ERL_NIF_TERM latency_term(ErlNifEnv *env) { return ring_term(env, E.latency_ms, &E.latency_n, LATENCIES); }

/* info() -> map of engine diagnostics. Dirty IO (takes `lock` to ask the
 * stream). */
static ERL_NIF_TERM nif_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    enum { N = 29 };
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
        atom(env, "input"),           atom(env, "midi"),
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
        input_info(env),
        midi_info(env),
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
    MI.late_n = 0;
    MI.in_n = 0;
    atomic_store(&MI.received, 0);
    atomic_store(&MI.sent, 0);
    atomic_store(&MI.late_dropped, 0);
    pthread_mutex_unlock(&E.stats_lock);
    return ok_atom(env);
}

static bool owner_now(ErlNifEnv *env) {
    pthread_mutex_lock(&E.ctl);
    bool mine = is_owner(env);
    pthread_mutex_unlock(&E.ctl);
    return mine;
}

static void set_input_clock(int64_t pos, int64_t ns) {
    uint32_t s = atomic_load(&IN.clk_seq);
    atomic_store(&IN.clk_seq, s + 1);
    atomic_store(&IN.clk_pos, pos);
    atomic_store(&IN.clk_ns, ns);
    atomic_store(&IN.clk_seq, s + 2);
}

/* Open the mic as input `id`: mono float at `rate`, low latency, shared,
 * unprocessed (no AGC or noise suppression) where the phone has it. NULL
 * or a reason. Caller holds IN.lock, nothing is open. */
static const char *open_mic_locked(ErlNifEnv *env, int rate, int64_t id) {
    if (!mic_permitted()) return "no_permission";
    aaudio_result_t r = open_mic(rate, AA_PRESET_UNPROCESSED, id);
    if (r != AA_OK) {
        LOGI("mic: unprocessed input refused (%d), voice recognition instead", r);
        r = open_mic(rate, AA_PRESET_VOICE_RECOGNITION, id);
    }
    if (r != AA_OK) {
        LOGE("mic open failed: %d", r);
        return "input_unavailable";
    }
    int got = aa.getSampleRate(IN.mic), channels = aa.getChannelCount(IN.mic);
    if (channels < 1 || channels > 2) channels = 1;
    rc_init(&REC, got, channels);
    IN.preset = aa.getInputPreset(IN.mic);
    IN.cb_frames = 0;
    set_input_clock(0, 0);
    atomic_store(&IN.callbacks, 0);
    atomic_store(&IN.clock_misses, 0);
    atomic_store(&IN.mic_dead, false);
    atomic_store(&IN.source, SRC_MIC);
    atomic_store(&IN.status, IN_OPEN);
    rc_gate_open(&IN.gate, id);
    r = aa.requestStart(IN.mic);
    if (r != AA_OK) {
        LOGE("mic start failed: %d", r);
        close_input_locked();
        return "input_unavailable";
    }
    LOGI("mic open: device %d, %d Hz, %d channel(s), burst %d, preset %d, %s", aa.getDeviceId(IN.mic), got, channels,
         aa.getFramesPerBurst(IN.mic), IN.preset,
         aa.getPerformanceMode(IN.mic) == AA_PERF_LOW_LATENCY ? "low latency" : "not low latency");
    tell_started(env, id, "mic", got, channels);
    return NULL;
}

/* input_open(mic | apps) -> {ok, Input} | {error, Reason}: close any input,
 * then open this one as Input (a positive integer). The owner hears
 * {magpie_audio, input, Input, started, Info} (the mic: at once; other
 * apps: after the consent dialog and the capture service) or
 * {magpie_audio, input, Input, closed, Reason}. Reasons now: not_owner
 * (nothing changed), input_stuck (the open mic wouldn't stop: closed to
 * the owner, still allocated), no_permission, input_unavailable,
 * unsupported, busy, no_activity (what was open is closed). Dirty IO. */
static ERL_NIF_TERM nif_input_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    REQUIRE_LIBS(env);
    int source = enif_is_identical(argv[0], atom(env, "mic"))    ? SRC_MIC
                 : enif_is_identical(argv[0], atom(env, "apps")) ? SRC_APPS
                                                                 : SRC_NONE;
    if (source == SRC_NONE) return enif_make_badarg(env);
    pthread_mutex_lock(&IN.lock);
    const char *failure = NULL;
    ERL_NIF_TERM opened = 0;
    int rate = atomic_load(&E.rate) > 0 ? atomic_load(&E.rate) : DEFAULT_RATE;
    if (!owner_now(env)) {
        failure = "not_owner";
    } else if (!close_input_locked()) {
        failure = "input_stuck";
    } else {
        int64_t id = atomic_fetch_add(&IN.gen, 1) + 1;
        if (source == SRC_MIC) {
            failure = open_mic_locked(env, rate, id);
        } else {
            atomic_store(&IN.source, SRC_APPS);
            atomic_store(&IN.status, IN_OPENING);
            atomic_store(&IN.callbacks, 0);
            failure = capture_start(rate, id);
            if (failure) close_input_locked();
        }
        if (!failure) opened = enif_make_tuple2(env, ok_atom(env), enif_make_int64(env, id));
    }
    pthread_mutex_unlock(&IN.lock);
    return failure ? error_tuple(env, failure) : opened;
}

/* input_close() -> ok | {error, not_owner | input_stuck}: close the input;
 * a recording in progress is dropped. Dirty IO. */
static ERL_NIF_TERM nif_input_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    REQUIRE_LIBS(env);
    pthread_mutex_lock(&IN.lock);
    const char *failure = !owner_now(env) ? "not_owner" : !close_input_locked() ? "input_stuck" : NULL;
    pthread_mutex_unlock(&IN.lock);
    return failure ? error_tuple(env, failure) : ok_atom(env);
}

/* record_start(now | on_sound | count_in, MaxSeconds, ThresholdDb,
 * PreRollMs) -> {ok, Take} | {error, not_owner | no_input | recording |
 * not_running | alloc | busy}. Arms the recorder on the open input as Take
 * (a positive integer), its
 * buffer for MaxSeconds allocated now. on_sound: from the first frame at
 * or over ThresholdDb (dBFS), PreRollMs before it; count_in: one bar of
 * clicks at the tempo (from the sequencer's next bar while it plays), then
 * from the audio captured when the downbeat after them is heard. */
static ERL_NIF_TERM nif_record_start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    double max_s, db, pre_ms;
    int mode = enif_is_identical(argv[0], atom(env, "now"))        ? RC_NOW
               : enif_is_identical(argv[0], atom(env, "on_sound")) ? RC_ON_SOUND
               : enif_is_identical(argv[0], atom(env, "count_in")) ? RC_AT_TIME
                                                                   : -1;
    if (mode < 0 || !get_number(env, argv[1], &max_s) || max_s <= 0 || max_s > MAX_SECONDS ||
        !get_number(env, argv[2], &db) || db < -120 || db > 0 || !get_number(env, argv[3], &pre_ms) || pre_ms < 0 ||
        pre_ms > 2000)
        return enif_make_badarg(env);
    pthread_mutex_lock(&IN.lock);
    const char *failure = NULL;
    if (!owner_now(env)) failure = "not_owner";
    else if (atomic_load(&IN.status) != IN_OPEN) failure = "no_input";
    else if (IN.armed) failure = "recording";
    else if (mode == RC_AT_TIME && !atomic_load(&E.running)) failure = "not_running";
    if (!failure) {
        int rate = REC.rate;
        int64_t max_frames = llround(max_s * rate), pre = llround(pre_ms * rate / 1000.0);
        int64_t ring = mode == RC_NOW ? 0 : pre > rate / 2 ? pre : rate / 2;
        if (!rc_arm(&REC, mode, max_frames, (float)pow(10.0, db / 20.0), pre, ring)) failure = "alloc";
    }
    if (!failure) {
        IN.armed = true;
        IN.start_sent = false;
        IN.full_sent = false;
        IN.peaks_sent = 0;
        IN.count_in = false;
        if (mode == RC_AT_TIME) {
            sp_cmd c = {.type = SP_CMD_COUNT_IN, .u.count_in = {atomic_load(&REC.gen), COUNT_IN_BEATS}};
            pthread_mutex_lock(&E.ctl);
            bool queued = ctl_push(&c);
            pthread_mutex_unlock(&E.ctl);
            if (queued) {
                IN.count_in = true;
            } else {
                drop_recording_locked();
                failure = "busy";
            }
        }
    }
    ERL_NIF_TERM take = enif_make_tuple2(env, ok_atom(env), enif_make_uint(env, atomic_load(&REC.gen)));
    pthread_mutex_unlock(&IN.lock);
    return failure ? error_tuple(env, failure) : take;
}

/* record_stop() -> {ok, #{pcm, rate, channels, frames, peaks, peak_frames}}
 * | {error, not_owner | not_recording | not_started | alloc}: the recording
 * as interleaved f32le at the input's rate, with its peaks. not_started:
 * it never began (no sound yet, or before the downbeat); the recorder is
 * disarmed either way. The PCM binary is the recorder's buffer, not a
 * copy. Dirty IO. */
static ERL_NIF_TERM nif_record_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    pthread_mutex_lock(&IN.lock);
    if (!owner_now(env) || !IN.armed) {
        bool mine = owner_now(env);
        pthread_mutex_unlock(&IN.lock);
        return error_tuple(env, mine ? "not_recording" : "not_owner");
    }
    rc_finish(&REC);
    cancel_count_in_locked();
    IN.armed = false;
    IN.peaks_sent = 0;
    int64_t frames = atomic_load(&REC.frames);
    if (frames == 0) {
        rc_free_buffers(&REC);
        pthread_mutex_unlock(&IN.lock);
        return error_tuple(env, "not_started");
    }
    int64_t n_peaks = rc_flush_peak(&REC);
    int channels = REC.channels, rate = REC.rate;
    size_t bytes = (size_t)frames * (size_t)channels * sizeof(float);
    float *data = realloc(REC.buf, bytes); /* shrinks in place: the unused tail of the maximum goes */
    if (!data) data = REC.buf;
    REC.buf = NULL;
    ERL_NIF_TERM pcm, peaks;
    unsigned char *p = enif_make_new_binary(env, (size_t)n_peaks, &peaks);
    pcm_res *res = p ? enif_alloc_resource(pcm_type, sizeof(pcm_res)) : NULL;
    if (!res) {
        free(data);
        rc_free_buffers(&REC);
        pthread_mutex_unlock(&IN.lock);
        return error_tuple(env, "alloc");
    }
    res->data = data;
    pcm = enif_make_resource_binary(env, res, data, bytes);
    enif_release_resource(res);
    memcpy(p, REC.peaks, (size_t)n_peaks);
    rc_free_buffers(&REC);
    pthread_mutex_unlock(&IN.lock);
    ERL_NIF_TERM keys[6] = {atom(env, "pcm"),    atom(env, "rate"),  atom(env, "channels"),
                            atom(env, "frames"), atom(env, "peaks"), atom(env, "peak_frames")};
    ERL_NIF_TERM vals[6] = {pcm,   enif_make_int(env, rate), enif_make_int(env, channels), enif_make_int64(env, frames),
                            peaks, enif_make_int(env, RC_PEAK_FRAMES)};
    return enif_make_tuple2(env, ok_atom(env), make_map(env, keys, vals, 6));
}

/* record_cancel() -> ok | {error, not_owner}: disarm, drop what was
 * recorded, cancel a count-in. Dirty IO. */
static ERL_NIF_TERM nif_record_cancel(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    pthread_mutex_lock(&IN.lock);
    bool mine = owner_now(env);
    if (mine) drop_recording_locked();
    pthread_mutex_unlock(&IN.lock);
    return mine ? ok_atom(env) : error_tuple(env, "not_owner");
}

/* The input in info/0: nil, or what is open and how it runs. Caller holds
 * nothing but `lock`. */
static ERL_NIF_TERM input_info(ErlNifEnv *env) {
    pthread_mutex_lock(&IN.lock);
    int source = atomic_load(&IN.source);
    ERL_NIF_TERM result = atom(env, "nil");
    if (source != SRC_NONE) {
        int64_t newest = atomic_load(&IN.newest_ns);
        int status = atomic_load(&IN.status);
        bool mic = source == SRC_MIC && IN.mic;
        ERL_NIF_TERM keys[12] = {atom(env, "source"),    atom(env, "status"),        atom(env, "rate"),
                                 atom(env, "channels"),  atom(env, "preset"),        atom(env, "callbacks"),
                                 atom(env, "clock_misses"), atom(env, "latency_ms"), atom(env, "recorder"),
                                 atom(env, "burst"),     atom(env, "overruns"),      atom(env, "low_latency")};
        ERL_NIF_TERM vals[12] = {
            atom(env, source == SRC_MIC ? "mic" : "apps"),
            atom(env, status == IN_OPEN ? "open" : status == IN_OPENING ? "opening" : "closed"),
            enif_make_int(env, REC.rate),
            enif_make_int(env, REC.channels),
            enif_make_int(env, source == SRC_MIC ? IN.preset : 0),
            enif_make_int64(env, atomic_load(&IN.callbacks)),
            enif_make_int64(env, atomic_load(&IN.clock_misses)),
            enif_make_double(env, newest > 0 ? (double)(now_ns() - newest) / 1e6 : -1),
            atom(env, IN.armed ? rec_state_name(atomic_load(&REC.state)) : "idle"),
            enif_make_int(env, mic ? aa.getFramesPerBurst(IN.mic) : 0),
            enif_make_int(env, mic ? aa.getXRunCount(IN.mic) : 0),
            atom(env, mic && aa.getPerformanceMode(IN.mic) == AA_PERF_LOW_LATENCY ? "true" : "false"),
        };
        result = make_map(env, keys, vals, 12);
    }
    pthread_mutex_unlock(&IN.lock);
    return result;
}

/* set_midi(nil | {InChannel, OutChannel, Clock, NoteMasks, OutNotes}) -> ok
 * | {error, not_owner | busy | alloc}: the kit's MIDI table (owner only).
 * InChannel 0 (all) | 1..16, OutChannel 1..16, Clock internal | follow |
 * send, NoteMasks 128 integers (a bit per pad), OutNotes 64 integers (-1:
 * the pad sends nothing). */
static ERL_NIF_TERM nif_set_midi(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    sp_midi_map *m = NULL;
    if (!enif_is_identical(argv[0], atom(env, "nil"))) {
        const ERL_NIF_TERM *t;
        int arity, in_ch, out_ch;
        unsigned len;
        if (!enif_get_tuple(env, argv[0], &arity, &t) || arity != 5 || !get_range(env, t[0], 0, 16, &in_ch) ||
            !get_range(env, t[1], 1, 16, &out_ch) || !enif_get_list_length(env, t[3], &len) || len != 128 ||
            !enif_get_list_length(env, t[4], &len) || len != SP_PADS)
            return enif_make_badarg(env);
        uint8_t clock;
        if (enif_is_identical(t[2], atom(env, "internal"))) clock = SP_CLOCK_INTERNAL;
        else if (enif_is_identical(t[2], atom(env, "follow"))) clock = SP_CLOCK_FOLLOW;
        else if (enif_is_identical(t[2], atom(env, "send"))) clock = SP_CLOCK_SEND;
        else return enif_make_badarg(env);
        m = calloc(1, sizeof(*m));
        if (!m) return error_tuple(env, "alloc");
        *m = (sp_midi_map){.in_channel = (uint8_t)in_ch, .out_channel = (uint8_t)out_ch, .clock = clock};
        ERL_NIF_TERM head, tail = t[3];
        for (int i = 0; enif_get_list_cell(env, tail, &head, &tail); i++) {
            ErlNifUInt64 mask;
            if (!enif_get_uint64(env, head, &mask)) {
                free(m);
                return enif_make_badarg(env);
            }
            m->notes[i] = mask;
        }
        tail = t[4];
        for (int i = 0; enif_get_list_cell(env, tail, &head, &tail); i++) {
            int note;
            if (!get_range(env, head, -1, 127, &note)) {
                free(m);
                return enif_make_badarg(env);
            }
            m->out_note[i] = (int16_t)note;
        }
    }
    pthread_mutex_lock(&E.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&E.ctl);
        free(m);
        return error_tuple(env, "not_owner");
    }
    sp_cmd c = {.type = SP_CMD_MIDI_MAP, .u.map = m};
    bool queued = ctl_push(&c);
    pthread_mutex_unlock(&E.ctl);
    if (!queued) {
        free(m);
        return error_tuple(env, "busy");
    }
    return ok_atom(env);
}

/* midi_listen(Pid) -> ok | {error, unavailable}: device events to Pid,
 * starting with the port's connection counts now (attach sends them; the
 * one sent when MIDI was bound may have gone before there was a listener).
 * Dirty IO (binds MIDI on first use). */
static ERL_NIF_TERM nif_midi_listen(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[0], &pid)) return enif_make_badarg(env);
    pthread_mutex_lock(&MI.lock);
    MI.listener = pid;
    MI.has_listener = true;
    pthread_mutex_unlock(&MI.lock);
    bool attached;
    JNIEnv *j = midi_env(&attached);
    if (!j) return error_tuple(env, "unavailable");
    (*j)->CallStaticVoidMethod(j, MI.cls, MI.attach);
    jni_failed(j);
    jni_done(attached);
    return ok_atom(env);
}

/* A Kotlin answer: "" → ok, else {error, Reason} (null: error). */
static ERL_NIF_TERM reason_term(ErlNifEnv *env, JNIEnv *j, jstring r) {
    if (jni_failed(j) || !r) return error_tuple(env, "error");
    const char *s = (*j)->GetStringUTFChars(j, r, NULL);
    ERL_NIF_TERM out = s && s[0] ? error_tuple(env, s) : ok_atom(env);
    if (s) (*j)->ReleaseStringUTFChars(j, r, s);
    (*j)->DeleteLocalRef(j, r);
    return out;
}

/* midi_devices() -> {ok, Json} | {error, unavailable}. Dirty IO. */
static ERL_NIF_TERM nif_midi_devices(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    bool attached;
    JNIEnv *j = midi_env(&attached);
    if (!j) return error_tuple(env, "unavailable");
    jbyteArray json = (jbyteArray)(*j)->CallStaticObjectMethod(j, MI.cls, MI.devices);
    ERL_NIF_TERM out = error_tuple(env, "error");
    if (!jni_failed(j) && json) {
        jsize len = (*j)->GetArrayLength(j, json);
        ERL_NIF_TERM bin;
        unsigned char *p = enif_make_new_binary(env, (size_t)len, &bin);
        (*j)->GetByteArrayRegion(j, json, 0, len, (jbyte *)p);
        if (!jni_failed(j)) out = enif_make_tuple2(env, ok_atom(env), bin);
        (*j)->DeleteLocalRef(j, json);
    }
    jni_done(attached);
    return out;
}

/* midi_open(Id) / midi_close(Id): open a device both ways (outcome as an
 * event) or close it. Dirty IO. */
static ERL_NIF_TERM nif_midi_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int id;
    if (!enif_get_int(env, argv[0], &id)) return enif_make_badarg(env);
    bool attached;
    JNIEnv *j = midi_env(&attached);
    if (!j) return error_tuple(env, "unavailable");
    ERL_NIF_TERM out = reason_term(env, j, (jstring)(*j)->CallStaticObjectMethod(j, MI.cls, MI.open, (jint)id));
    jni_done(attached);
    return out;
}

static ERL_NIF_TERM nif_midi_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int id;
    if (!enif_get_int(env, argv[0], &id)) return enif_make_badarg(env);
    bool attached;
    JNIEnv *j = midi_env(&attached);
    if (!j) return error_tuple(env, "unavailable");
    (*j)->CallStaticVoidMethod(j, MI.cls, MI.close, (jint)id);
    ERL_NIF_TERM out = jni_failed(j) ? error_tuple(env, "error") : ok_atom(env);
    jni_done(attached);
    return out;
}

/* midi_ble_scan(Ms) -> ok | {error, Reason}. Dirty IO. */
static ERL_NIF_TERM nif_midi_ble_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int ms;
    if (!get_range(env, argv[0], 1, 600000, &ms)) return enif_make_badarg(env);
    bool attached;
    JNIEnv *j = midi_env(&attached);
    if (!j) return error_tuple(env, "unavailable");
    ERL_NIF_TERM out = reason_term(env, j, (jstring)(*j)->CallStaticObjectMethod(j, MI.cls, MI.ble_scan, (jint)ms));
    jni_done(attached);
    return out;
}

/* An address binary as a Java string (NULL: not one). */
static jstring address_string(ErlNifEnv *env, JNIEnv *j, ERL_NIF_TERM term) {
    ErlNifBinary b;
    char s[32];
    if (!enif_inspect_binary(env, term, &b) || b.size == 0 || b.size >= sizeof(s)) return NULL;
    memcpy(s, b.data, b.size);
    s[b.size] = 0;
    return (*j)->NewStringUTF(j, s);
}

/* midi_ble_connect(Address) -> ok | {error, Reason}; midi_ble_disconnect. Dirty IO. */
static ERL_NIF_TERM nif_midi_ble_connect(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    bool attached;
    JNIEnv *j = midi_env(&attached);
    if (!j) return error_tuple(env, "unavailable");
    jstring a = address_string(env, j, argv[0]);
    ERL_NIF_TERM out = a ? reason_term(env, j, (jstring)(*j)->CallStaticObjectMethod(j, MI.cls, MI.ble_connect, a))
                         : enif_make_badarg(env);
    if (a) (*j)->DeleteLocalRef(j, a);
    jni_done(attached);
    return out;
}

static ERL_NIF_TERM nif_midi_ble_disconnect(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    bool attached;
    JNIEnv *j = midi_env(&attached);
    if (!j) return error_tuple(env, "unavailable");
    jstring a = address_string(env, j, argv[0]);
    ERL_NIF_TERM out = enif_make_badarg(env);
    if (a) {
        (*j)->CallStaticVoidMethod(j, MI.cls, MI.ble_disconnect, a);
        out = jni_failed(j) ? error_tuple(env, "error") : ok_atom(env);
        (*j)->DeleteLocalRef(j, a);
    }
    jni_done(attached);
    return out;
}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    pthread_mutex_init(&E.lock, NULL);
    pthread_mutex_init(&IN.lock, NULL);
    pthread_mutex_init(&MI.lock, NULL);
    for (int i = 0; i < MIDI_SOURCES; i++) pthread_mutex_init(&MI.sources[i].lock, NULL);
    pcm_type = enif_open_resource_type(env, NULL, "magpie_pcm", pcm_dtor, ERL_NIF_RT_CREATE, NULL);
    if (!pcm_type) return 1;
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
    {"set_pad", 3, nif_set_pad, 0},
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
    {"input_open", 1, nif_input_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"input_close", 0, nif_input_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"record_start", 4, nif_record_start, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"record_stop", 0, nif_record_stop, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"record_cancel", 0, nif_record_cancel, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_midi", 1, nif_set_midi, 0},
    {"midi_listen", 1, nif_midi_listen, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"midi_devices", 0, nif_midi_devices, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"midi_open", 1, nif_midi_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"midi_close", 1, nif_midi_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"midi_ble_scan", 1, nif_midi_ble_scan, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"midi_ble_connect", 1, nif_midi_ble_connect, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"midi_ble_disconnect", 1, nif_midi_ble_disconnect, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.Magpie.Audio.Nif, nif_funcs, on_load, NULL, NULL, NULL)
