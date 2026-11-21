/*
 * c_src/magpie_audio.c — Magpie's audio engine: the sampler core
 * (sampler.c) and the recorder (recorder.c) behind mob_audio_io's streams
 * (c_src/magpie_io.c's processors), MIDI in and out through mob_midi's C
 * ABI, and the NIF (Magpie.Audio.Nif). The same code builds for Android and
 * iOS; only the "other apps" input (plugins/magpie_capture, MediaProjection)
 * is Android's.
 *
 *   output stream    mob_audio_io's (AAudio low latency / RemoteIO), stereo
 *                    float at the device's own rate, opened by
 *                    Magpie.Audio.Native.Io. "magpie_out" runs sp_render:
 *                    drains the command queue, runs the sequencer and the
 *                    count-in clicks, mixes the voices; it maps engine
 *                    frames onto when they are heard (the engine clock).
 *   mic stream       mob_audio_io's input, mono at the output's rate:
 *                    "magpie_mic" feeds the recorder, each block stamped
 *                    with when it was captured.
 *   capture thread   Kotlin's (MagpieCapture, Android), for other apps:
 *                    16-bit blocks into the recorder through native_write.
 *   event thread     Every 2 ms: turns the renderer's events into messages
 *                    for the owner (coalesced: one playhead and at most a
 *                    start and an end per pad per pass), frees retired
 *                    samples and patterns, gives the recorder the
 *                    count-in's downbeat and sends the input's news and
 *                    meters.
 *   loader thread    load jobs in order: f32 PCM (load_pcm/4, and a file
 *                    load_sample/2's Elixir side decoded with
 *                    MobAudioIo.decode_stream) to 16-bit, resampled to the
 *                    engine's rate, peaks, then handed to the renderer.
 *   MIDI receive     mob_midi's, one per open input port: midi_sink parses
 *                    the bytes into the command queue.
 *   MIDI sending     Sends what the renderer stamped (notes, clock) to the
 *                    MIDI outputs with mob_midi_send, when it is heard.
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
 * Time: mai_now_ns() (CLOCK_MONOTONIC on Android, mach_absolute_time on
 * iOS), the clock of mob_audio_io's mai_time and of mob_midi's timestamps
 * (mob_midi_now_ns), so audio frames, MIDI in and MIDI out share one clock
 * on both platforms.
 *
 * Control calls (samples, pads, patterns, tempo, play, reset, close, the
 * input and the recorder) are the owner's alone ({error, not_owner} for
 * anyone else); live calls (trigger, release, note_on, note_off) are open
 * to every process and only queue a command: they never wait on the stream.
 *
 * Locks, always taken in this order: lock → IN.lock → OUT.ctl → jobs_lock /
 * OUT.push → stats_lock. `lock` covers the threads' lifecycle (open,
 * close) and the NIFs that read across the engine (info); `IN.lock` the
 * input's lifecycle and the recorder's buffers. NIFs taking either run on
 * dirty IO schedulers. `OUT.ctl` covers the owner, the sample table and,
 * while no stream renders, the renderer's role (sp_drain). `OUT.push`
 * serialises producers into the command queue; the audio callbacks never
 * take a lock.
 */

#include <erl_nif.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifdef __ANDROID__
#include <android/log.h>
#include <jni.h>
#include <sys/resource.h>
#define LOG_TAG "magpie_audio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#else
#include <os/log.h>
#include <pthread/qos.h>
#define LOGI(...) os_log(OS_LOG_DEFAULT, "magpie_audio: " __VA_ARGS__)
#define LOGE(...) os_log_error(OS_LOG_DEFAULT, "magpie_audio: " __VA_ARGS__)
#endif

/* mob_midi's C ABI (a dependency: its own path, see its README). */
#include "../deps/mob_midi/priv/include/mob_midi.h"

/* The processors, the sampler and the recorder (mob_audio_io.h with them). */
#include "magpie_io.c"
#include "midi_out.c"
#include "load_queue.c"

#define MAX_SECONDS 300 /* longest sample a load accepts */
#define EVENT_PERIOD_US 2000
#define LATENCIES 256

static int64_t now_ns(void) { return mai_now_ns(); }

/* A real-time-ish priority for our own threads (the event thread, MIDI
 * sending), best effort: Android's audio niceness, iOS's interactive QoS. */
static void raise_priority(int android_nice, const char *who) {
#ifdef __ANDROID__
    if (setpriority(PRIO_PROCESS, (id_t)gettid(), android_nice) != 0) LOGE("%s: could not raise the thread's priority", who);
#else
    (void)android_nice;
    if (pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) != 0)
        LOGE("%{public}s: could not raise the thread's priority", who);
#endif
}

/* ── State ───────────────────────────────────────────────────────────────── */

/* A sample id (any term) and what its slot holds. */
typedef struct {
    bool used;   /* the slot belongs to `id` (loading or loaded) */
    bool loaded; /* a sample is installed */
    ErlNifEnv *env;
    ERL_NIF_TERM id;
    uint64_t request; /* the latest load or unload of this id; older loads are stale */
    size_t bytes;
} id_entry;

/* A load: f32 PCM (`pcm`, held in `env`), or a failure to report
 * (`q.failure`). A file load is queued pending when it is claimed
 * (load_claim/1), and its decode finishes it (load_ticket/4,
 * load_ticket_failed/2): see load_queue.c. */
typedef struct load_job {
    lq_job q; /* first: the queue's link, ticket, pending, failure */
    ERL_NIF_TERM pcm;
    int source_rate, channels;
    int slot;
    uint64_t request;
    int rate;
    ErlNifEnv *env;
    ERL_NIF_TERM id;
} load_job;

static struct {
    pthread_mutex_t lock, jobs_lock, stats_lock;
    lq_queue loads;

    /* Under OUT.ctl. */
    bool events_alive; /* the event thread runs (it alone frees garbage then) */
    ErlNifPid owner;
    bool has_owner;
    id_entry ids[SP_SLOTS];
    uint64_t requests;
    uint32_t patterns;

    /* Under `lock`. */
    pthread_t events;
    _Atomic bool events_run;

    /* Under jobs_lock. */
    bool loader_started;

    /* Trigger latency, newest LATENCIES (under stats_lock). */
    float latency_ms[LATENCIES];
    int64_t latency_n;

    _Atomic int64_t sample_bytes;
    int32_t io_registered; /* mio_register's result at load */
} E;

static void count_in_heard(ErlNifEnv *env, const ErlNifPid *owner, bool has_owner, const sp_event *ev);
static void deliver_input(ErlNifEnv *env, int64_t now);
static ERL_NIF_TERM input_info(ErlNifEnv *env);
static void midi_in_latency(const sp_event *ev);

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) { return enif_make_atom(env, name); }

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static ERL_NIF_TERM ok_atom(ErlNifEnv *env) { return atom(env, "ok"); }

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

/* A control command. Caller holds OUT.ctl. With no stream rendering, the
 * control path plays the renderer and applies it now; with no event
 * thread, it also frees what was retired. */
static bool ctl_push(const sp_cmd *c) {
    bool ok = mio_push(c);
    if (OUT.drains) sp_drain(&SP, false);
    if (!E.events_alive) {
        sp_garbage g;
        while (sp_pop_garbage(&SP, &g)) free_garbage(&g);
    }
    return ok;
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
    int rate = atomic_load(&OUT.rate);
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
    pthread_mutex_lock(&OUT.ctl);
    bool has_owner = E.has_owner;
    ErlNifPid owner = E.owner;
    pthread_mutex_unlock(&OUT.ctl);

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
            if (ev.b) midi_in_latency(&ev);
            else record_latency(&ev);
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
}

static void *events_main(void *arg) {
    (void)arg;
    /* So playhead and voice events keep up with the UI. */
    raise_priority(-16, "events");
    ErlNifEnv *env = enif_alloc_env();
    while (atomic_load(&E.events_run)) {
        int64_t now = now_ns();
        deliver_events(env);
        deliver_input(env, now);
        sp_garbage g;
        while (sp_pop_garbage(&SP, &g)) free_garbage(&g);
        usleep(EVENT_PERIOD_US);
    }
    enif_free_env(env);
    return NULL;
}

/* ── Loading (the loader thread) ─────────────────────────────────────────── */

typedef struct {
    int16_t *pcm; /* interleaved, `channels` per frame */
    int64_t frames;
    int channels, rate;
} decoded;

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
    pthread_mutex_lock(&OUT.ctl);
    if (E.has_owner) {
        ERL_NIF_TERM msg = enif_make_tuple4(env, tag(env), atom(env, "loaded"), id, result);
        if (!enif_send(NULL, &E.owner, env, msg)) enif_clear_env(env);
    }
    pthread_mutex_unlock(&OUT.ctl);
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
    const char *failure = job->q.failure ? job->q.failure : convert_pcm(job, &d);
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
    pthread_mutex_lock(&OUT.ctl);
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
    pthread_mutex_unlock(&OUT.ctl);
    if (s) {
        atomic_fetch_sub(&E.sample_bytes, (int64_t)s->bytes);
        sp_sample_free(s);
    }
    send_loaded(env, id, result);
    enif_free_env(env);
}

static void free_job(load_job *job) {
    if (job->env) enif_free_env(job->env);
    free(job);
}

/* How long the loader waits for a claimed file's decode before giving it
 * up (Magpie.Audio.Native reports a crashed decode itself; this is for a
 * decode nobody will ever finish). */
#define PENDING_TIMEOUT_MS (600 * 1000)

static void *loader_main(void *arg) {
    (void)arg;
    for (;;) {
        load_job *job = (load_job *)lq_take(&E.loads, PENDING_TIMEOUT_MS);
        run_job(job);
        free_job(job);
    }
    return NULL;
}

/* ── NIF helpers ─────────────────────────────────────────────────────────── */

/* Caller holds OUT.ctl. */
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
    pthread_mutex_lock(&OUT.ctl);
    bool mine = is_owner(env);
    bool queued = mine && ctl_push(c);
    pthread_mutex_unlock(&OUT.ctl);
    if (!mine) return error_tuple(env, "not_owner");
    return queued ? ok_atom(env) : error_tuple(env, "busy");
}

/* A live command: anyone, while a stream renders. */
static ERL_NIF_TERM live(ErlNifEnv *env, sp_cmd *c) {
    if (!atomic_load(&OUT.running)) return error_tuple(env, "not_running");
    c->t_ns = now_ns();
    return mio_push(c) ? ok_atom(env) : error_tuple(env, "busy");
}

static void clear_ids_locked(void) {
    for (int i = 0; i < SP_SLOTS; i++) {
        if (E.ids[i].env) enif_free_env(E.ids[i].env);
        E.ids[i] = (id_entry){0};
    }
}

/* ── The input: the mic or other apps, into the recorder ─────────────────── *
 *
 * One input at a time feeds REC (recorder.c) through IN (magpie_io.c). The
 * mic is a mob_audio_io input stream of its own on "magpie_mic"
 * (Magpie.Audio.Native.Io opens it once input_open/1 has made the input
 * OPENING; its STARTED makes it OPEN), so recording never touches the
 * output callback. Other apps are Android's playback capture
 * (MediaProjection + AudioRecord, API 29+) in Kotlin
 * (plugins/magpie_capture), whose read thread hands 16-bit PCM to
 * native_write. Java is called with IN.lock held (start/stop return
 * without waiting on the UI thread); its callbacks take IN.lock
 * themselves, never from inside Kotlin's own lock, and native_write takes
 * no lock. */

#define METER_PERIOD_NS 40000000LL
#define COUNT_IN_BEATS 4

typedef struct {
    float *data;
} pcm_res;

static ErlNifResourceType *pcm_type;

static void pcm_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    free(((pcm_res *)obj)->data);
}

#ifdef __ANDROID__

/* ── Other apps (Android): Java ── */

#define CAPTURE_CLASS "com.genericjam.magpie.capture.MagpieCapture"

extern JavaVM *g_jvm;
extern jobject g_activity;

/* Send `msg` (built in `menv`) to the owner, then free `menv`. `caller`:
 * the NIF's env, or NULL on a thread of our own. */
static void tell_owner(ErlNifEnv *caller, ErlNifEnv *menv, ERL_NIF_TERM msg) {
    pthread_mutex_lock(&OUT.ctl);
    if (E.has_owner) enif_send(caller, &E.owner, menv, msg);
    pthread_mutex_unlock(&OUT.ctl);
    enif_free_env(menv);
}

/* MagpieCapture, found through the activity's class loader. Under IN.lock. */
static struct {
    jclass cls;
    jmethodID start, stop;
} CAP;

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

/* MagpieCapture.nativeStarted(session, rate, channels): capture runs; false
 * tells Kotlin to stop (nobody waits for it any more). Kotlin calls it
 * before its read thread starts. `session` is the input's id. */
static jboolean JNICALL native_started(JNIEnv *j, jclass cls, jlong session, jint rate, jint channels) {
    (void)j;
    (void)cls;
    pthread_mutex_lock(&IN.lock);
    bool current = session == atomic_load(&IN.gen) && atomic_load(&IN.source) == SRC_APPS &&
                   atomic_load(&IN.status) == IN_OPENING && rate > 0 && channels >= 1 && channels <= 2;
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
 * (System.nanoTime, CLOCK_MONOTONIC: mai_now_ns's clock on Android). The
 * read thread; takes no lock. A call for an input that is no longer open
 * (a read thread that outlived its stop) stops at the gate. */
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
    if (CAP.cls) return true;
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
        CAP.start = (*j)->GetStaticMethodID(j, cls, "start", "(IJ)Ljava/lang/String;");
        if (jni_failed(j)) CAP.start = NULL;
        CAP.stop = (*j)->GetStaticMethodID(j, cls, "stop", "()V");
        if (jni_failed(j)) CAP.stop = NULL;
        if (CAP.start && CAP.stop && (*j)->RegisterNatives(j, cls, natives, 3) == 0 && !jni_failed(j)) {
            CAP.cls = (jclass)(*j)->NewGlobalRef(j, cls);
            ok = CAP.cls != NULL;
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
        jstring r = (jstring)(*j)->CallStaticObjectMethod(j, CAP.cls, CAP.start, (jint)rate, (jlong)id);
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
    JNIEnv *j = CAP.cls ? jni_env(&attached) : NULL;
    if (!j) return;
    (*j)->CallStaticVoidMethod(j, CAP.cls, CAP.stop);
    jni_failed(j);
    jni_done(attached);
}

#else

/* Other apps' audio is Android's MediaProjection; iOS has no such thing. */
static const char *capture_start(int rate, int64_t id) {
    (void)rate;
    (void)id;
    return "unsupported";
}

static void capture_stop(void) {}

#endif

/* ── The recording ── */

static void cancel_count_in_locked(void) {
    if (!IN.count_in) return;
    IN.count_in = false;
    sp_cmd c = {.type = SP_CMD_COUNT_IN, .u.count_in = {0, 0}};
    pthread_mutex_lock(&OUT.ctl);
    ctl_push(&c);
    pthread_mutex_unlock(&OUT.ctl);
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
 * shut, the first thing here. The mic's stream is Magpie.Audio.Native.Io's
 * to close (after this, so its STOPPED isn't taken for a lost device).
 * Caller holds IN.lock. */
static void close_input_locked(void) {
    int source = atomic_load(&IN.source);
    atomic_store(&IN.status, IN_CLOSED);
    rc_gate_shut(&IN.gate);
    drop_recording_locked();
    if (source == SRC_APPS) capture_stop();
    atomic_store(&IN.mic_stream, 0);
    atomic_store(&IN.source, SRC_NONE);
    atomic_store(&IN.news, IN_NEWS_NONE);
    atomic_fetch_add(&IN.gen, 1); /* late calls and events from that input are stale */
}

/* The event thread, on the count-in's event: the recorder starts with the
 * audio captured when the downbeat is heard (if that take is still armed;
 * the recorder ignores an earlier one's); the owner hears of the beats. */
static void count_in_heard(ErlNifEnv *env, const ErlNifPid *owner, bool has_owner, const sp_event *ev) {
    rc_start_at(&REC, (uint32_t)ev->a, mio_heard_ns(ev->until));
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

/* The event thread, every pass: the mic's news (started, gone), the
 * recording's start and end, and every METER_PERIOD_NS the level and the
 * new peaks. */
static void deliver_input(ErlNifEnv *env, int64_t now) {
    if (atomic_load(&IN.source) == SRC_NONE || pthread_mutex_trylock(&IN.lock) != 0) return;
    pthread_mutex_lock(&OUT.ctl);
    bool has_owner = E.has_owner;
    ErlNifPid owner = E.owner;
    pthread_mutex_unlock(&OUT.ctl);

    int64_t id = atomic_load(&IN.gen);
    int news = atomic_exchange(&IN.news, IN_NEWS_NONE);
    if (news == IN_NEWS_STARTED && has_owner) {
        ERL_NIF_TERM keys[3] = {atom(env, "source"), atom(env, "rate"), atom(env, "channels")};
        ERL_NIF_TERM vals[3] = {atom(env, "mic"), enif_make_int(env, REC.rate), enif_make_int(env, REC.channels)};
        send_owner(&owner, env,
                   enif_make_tuple5(env, tag(env), atom(env, "input"), enif_make_int64(env, id), atom(env, "started"),
                                    make_map(env, keys, vals, 3)));
    } else if (news == IN_NEWS_LOST && has_owner) {
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

/* mob_midi (deps/mob_midi) holds the devices, the app's own "Magpie" device
 * and their ports; Magpie.Midi opens them with deliver: :native and hands
 * this NIF the output handles (midi_outputs/1). No MIDI byte passes through
 * the BEAM. In: mob_midi calls midi_sink on a port's receive thread with
 * the bytes, their timestamp and the port's source and generation; it
 * parses them (one parser per source) and queues one SP_CMD_MIDI per
 * message. Out: the renderer stamps messages with engine frames into
 * SP.midi.out; the sending thread turns each frame into mai_now_ns time
 * through the engine clock, sleeps until then and queues the bytes on
 * every output with mob_midi_send, stamped with that time. */

#define MIDI_SOURCES MOB_MIDI_MAX_SOURCES
#define MIDI_OUTPUTS 32               /* outputs the sending thread sends to */
#define MIDI_LATE_CLOCK_NS 20000000LL /* a tick this late is dropped, not sent in a burst */
#define MIDI_BATCH_NS 100000LL        /* messages this close together go in one send */
#define MIDI_RETRY_NS 10000000LL      /* a refusing output owed note-offs is tried this often */
#define MIDI_SEND_MAX 256
#define MIDI_STATS 512

_Static_assert(MIDI_SOURCES == SP_MIDI_SOURCES, "a gone bit per mob_midi source");

/* A source's parser, fed only by the source's current generation (see
 * midi_sink). */
typedef struct {
    pthread_mutex_t lock;
    uint32_t generation; /* the port being parsed; 0: none (never opened, or gone) */
    mi_parser parser;
} midi_source;

static struct {
    midi_source sources[MIDI_SOURCES];
    bool sink; /* midi_sink is mob_midi's sink */
    /* The outputs (midi_outputs/1), under out_lock: the NIF replaces them,
     * the sending thread sends to them. `next` is the NIF's scratch. */
    pthread_mutex_t out_lock;
    midi_out outs[MIDI_OUTPUTS], next[MIDI_OUTPUTS];
    int n_outs;
    /* The sending thread: started and joined under E.lock. */
    pthread_t out;
    bool out_started;
    _Atomic bool out_run;
    /* Notes left in the out queue by an earlier stream (midi_start_locked
     * fills it, the new thread sends it). */
    mo_event stale[MO_RING];
    int n_stale;
    /* received: parsed messages; sent: messages handed to the outputs (what
     * they refused: OUT_STATS, midi_out.c). */
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
    if (atomic_load(&OUT.running)) return;
    pthread_mutex_lock(&OUT.ctl);
    if (OUT.drains) sp_drain(&SP, false);
    pthread_mutex_unlock(&OUT.ctl);
}

/* What input `source` held ends: SP_CMD_MIDI_GONE in the command queue, so
 * after what the input sent before; if the full queue refuses it, a bit the
 * renderer applies after the commands queued by then (never lost). */
static void source_gone(int source) {
    sp_cmd c = {.type = SP_CMD_MIDI_GONE, .u.midi = {.src = (uint8_t)source}};
    if (!mio_push(&c)) atomic_fetch_or(&SP.midi.gone, 1ull << source);
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
    if (!atomic_load(&OUT.running) && !release) return;
    if (!mio_push(&c)) {
        if (release) source_gone(x->src);
        return;
    }
    if (release) midi_drain_offline();
}

/* mob_midi's sink: a port's receive thread, under mob_midi's lock of the
 * source, so calls for one source never overlap. mob_midi delivers only the
 * source's current generation; a new one is another port on the source (or
 * another app sending into Magpie's own device): a fresh parser (no running
 * status or SysEx left by the port before), and what the old one held ends.
 * A timestamp of 0 (senders that don't stamp) or more than a second off
 * isn't on mob_midi_now_ns's clock: the message counts as arriving now. */
static void midi_sink(void *ctx, uint32_t source, uint32_t generation, const uint8_t *bytes, size_t len,
                      int64_t timestamp_ns) {
    (void)ctx;
    if (source == 0 || source >= MIDI_SOURCES || generation == 0 || len == 0) return;
    midi_ctx x = {.t_ns = mob_midi_timestamp_or(timestamp_ns, mob_midi_now_ns()), .src = (uint8_t)source};
    midi_source *s = &MI.sources[source];
    pthread_mutex_lock(&s->lock);
    if (generation != s->generation) {
        if (s->generation) source_gone((int)source);
        s->generation = generation;
        s->parser = (mi_parser){0};
    }
    mi_parse(&s->parser, bytes, len, midi_emit, &x);
    pthread_mutex_unlock(&s->lock);
}

/* Every source parsed here whose port has closed since (unplugged, closed
 * by Magpie.Midi, another app stopped sending into Magpie's own device):
 * what it held ends, and its late bytes can't reach the next port on it.
 * mob_midi_source_info is lock-free; a generation the sink moved on
 * meanwhile has ended its voices itself. */
static void midi_sources_check(void) {
    for (uint32_t i = 1; i < MIDI_SOURCES; i++) {
        midi_source *s = &MI.sources[i];
        pthread_mutex_lock(&s->lock);
        uint32_t seen = s->generation;
        pthread_mutex_unlock(&s->lock);
        uint32_t current = 0;
        if (!seen || (mob_midi_source_info(i, &current, NULL, NULL) == MOB_MIDI_OK && current == seen)) continue;
        pthread_mutex_lock(&s->lock);
        if (s->generation == seen) {
            s->generation = 0;
            s->parser = (mi_parser){0};
            source_gone((int)i);
        }
        pthread_mutex_unlock(&s->lock);
    }
}

/* The sending thread: a batch to every output (midi_out.c). */
static void outs_send(const uint8_t *buf, int n, const mo_event *evs, int count, int64_t at) {
    pthread_mutex_lock(&MI.out_lock);
    for (int i = 0; i < MI.n_outs; i++) out_send(&MI.outs[i], buf, n, evs, count, at);
    pthread_mutex_unlock(&MI.out_lock);
    atomic_fetch_add_explicit(&MI.sent, (uint64_t)count, memory_order_relaxed);
}

/* The sending thread with nothing to send (see out_retry). */
static void outs_retry(void) {
    pthread_mutex_lock(&MI.out_lock);
    for (int i = 0; i < MI.n_outs; i++) out_retry(&MI.outs[i]);
    pthread_mutex_unlock(&MI.out_lock);
}

/* The sending thread's copy of the clock map: a read that loses to the
 * render's update (sp_get_clock gives up rather than spin) uses the last
 * one instead of sending early. */
typedef struct {
    int64_t frame, ns;
    int rate;
} midi_clock;

/* When engine frame `frame` is heard (mai_now_ns), or now before there has
 * been a presentation time. */
static int64_t frame_ns(midi_clock *c, int64_t frame) {
    int64_t cf, cns;
    int rate = atomic_load(&OUT.rate);
    if (sp_get_clock(&SP, &cf, &cns) && rate > 0) *c = (midi_clock){cf, cns, rate};
    if (c->rate <= 0) return now_ns();
    return c->ns + (int64_t)((double)(frame - c->frame) * 1e9 / c->rate);
}

/* Until mai_now_ns() reaches `t`. Android: an absolute sleep on its clock
 * (CLOCK_MONOTONIC). Elsewhere mai_now_ns is the host-tick clock no
 * clock_nanosleep takes: relative sleeps until it is reached. */
static void sleep_until(int64_t t) {
#ifdef __ANDROID__
    struct timespec ts = {.tv_sec = (time_t)(t / 1000000000LL), .tv_nsec = (long)(t % 1000000000LL)};
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR) {
    }
#else
    for (int64_t d = t - now_ns(); d > 0; d = t - now_ns()) {
        struct timespec ts = {.tv_sec = (time_t)(d / 1000000000LL), .tv_nsec = (long)(d % 1000000000LL)};
        nanosleep(&ts, NULL);
    }
#endif
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
    raise_priority(-19, "midi");
    uint8_t buf[MIDI_SEND_MAX];
    mo_event evs[MIDI_SEND_MAX];
    midi_clock clk = {0, 0, 0};
    for (int i = 0; i < MI.n_stale;) {
        int n = 0, count = 0;
        for (; i < MI.n_stale && n + MI.stale[i].len <= MIDI_SEND_MAX; i++) {
            memcpy(buf + n, MI.stale[i].b, MI.stale[i].len);
            n += MI.stale[i].len;
            evs[count++] = MI.stale[i];
        }
        outs_send(buf, n, evs, count, 0);
    }
    MI.n_stale = 0;
    int64_t retry_at = 0;
    while (atomic_load(&MI.out_run)) {
        mo_event ev;
        if (!mo_peek(&SP.midi.out, &ev)) {
            int64_t now = now_ns();
            if (now >= retry_at) {
                outs_retry();
                retry_at = now + MIDI_RETRY_NS;
            }
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
            evs[count++] = ev;
        }
        if (n == 0) continue;
        int64_t sent_at = now_ns();
        outs_send(buf, n, evs, count, t);
        stat_push(MI.late_us, &MI.late_n, (float)((sent_at - t) / 1000.0));
    }
    return NULL;
}

/* Start the sending thread. What is left in the out queue from an earlier
 * run is stale: the notes whose other half went out go first, at once
 * (mo_take_stale: a note-on that went out keeps its note-off, a voice still
 * holding its note gets its note-on), the rest is dropped. Caller holds
 * E.lock; the queue has no consumer until the thread starts. */
static void midi_start_locked(void) {
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
    int rate = atomic_load(&OUT.rate);
    if (!sp_get_clock(&SP, &cf, &cns) || rate <= 0) return;
    double heard_ns = (double)cns + (double)(ev->frame - cf) * 1e9 / rate;
    stat_push(MI.in_ms, &MI.in_n, (float)((heard_ns - (double)ev->t_ns) / 1e6));
}

static ERL_NIF_TERM ring_term(ErlNifEnv *env, const float *ring, const int64_t *count_at, int size);

static ERL_NIF_TERM midi_info(ErlNifEnv *env) {
    pthread_mutex_lock(&MI.out_lock);
    int outputs = MI.n_outs, refusing = 0;
    for (int i = 0; i < MI.n_outs; i++) refusing += MI.outs[i].refusing;
    pthread_mutex_unlock(&MI.out_lock);
    ERL_NIF_TERM keys[13] = {atom(env, "bound"),         atom(env, "received"),    atom(env, "applied"),
                             atom(env, "sent"),          atom(env, "out_dropped"), atom(env, "late_ticks_dropped"),
                             atom(env, "refused"),       atom(env, "discards"),    atom(env, "offs_owed"),
                             atom(env, "outputs"),       atom(env, "refusing"),    atom(env, "in_latency_ms"),
                             atom(env, "out_late_us")};
    ERL_NIF_TERM vals[13] = {atom(env, MI.sink ? "true" : "false"),
                             enif_make_uint64(env, atomic_load(&MI.received)),
                             enif_make_uint64(env, atomic_load(&SP.midi.in_messages)),
                             enif_make_uint64(env, atomic_load(&MI.sent)),
                             enif_make_uint64(env, atomic_load(&SP.midi.out.dropped)),
                             enif_make_uint64(env, atomic_load(&MI.late_dropped)),
                             enif_make_uint64(env, atomic_load(&OUT_STATS.refused)),
                             enif_make_uint64(env, atomic_load(&OUT_STATS.discards)),
                             enif_make_uint64(env, atomic_load(&OUT_STATS.offs_owed)),
                             enif_make_int(env, outputs),
                             enif_make_int(env, refusing),
                             ring_term(env, MI.in_ms, &MI.in_n, MIDI_STATS),
                             ring_term(env, MI.late_us, &MI.late_n, MIDI_STATS)};
    return make_map(env, keys, vals, 13);
}

/* ── NIFs ────────────────────────────────────────────────────────────────── */

/* open(Owner) -> ok | {error, thread | processors}: make Owner the engine's
 * owner and start the event and MIDI sending threads (if they aren't). The
 * output stream is Magpie.Audio.Native.Io's, on "magpie_out". Dirty IO. */
static ERL_NIF_TERM nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid owner;
    if (!enif_get_local_pid(env, argv[0], &owner)) return enif_make_badarg(env);
    if (E.io_registered != MAI_OK) return error_tuple(env, "processors");
    pthread_mutex_lock(&E.lock);
    pthread_mutex_lock(&OUT.ctl);
    E.owner = owner;
    E.has_owner = true;
    pthread_mutex_unlock(&OUT.ctl);
    if (!atomic_load(&E.events_run)) {
        pthread_mutex_lock(&OUT.ctl);
        E.events_alive = true;
        pthread_mutex_unlock(&OUT.ctl);
        atomic_store(&E.events_run, true);
        if (pthread_create(&E.events, NULL, events_main, NULL) != 0) {
            atomic_store(&E.events_run, false);
            pthread_mutex_lock(&OUT.ctl);
            E.events_alive = false;
            pthread_mutex_unlock(&OUT.ctl);
            pthread_mutex_unlock(&E.lock);
            return error_tuple(env, "thread");
        }
    }
    midi_start_locked();
    pthread_mutex_unlock(&E.lock);
    return ok_atom(env);
}

/* close() -> ok | {error, not_owner}: stop the event and MIDI sending
 * threads (samples, pads and patterns stay; the output stream is closed
 * by Magpie.Audio.Native.Io). Dirty IO. */
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    pthread_mutex_lock(&E.lock);
    pthread_mutex_lock(&OUT.ctl);
    bool mine = is_owner(env);
    pthread_mutex_unlock(&OUT.ctl);
    if (!mine) {
        pthread_mutex_unlock(&E.lock);
        return error_tuple(env, "not_owner");
    }
    if (atomic_exchange(&E.events_run, false)) pthread_join(E.events, NULL);
    pthread_mutex_lock(&OUT.ctl);
    E.events_alive = false;
    sp_garbage g;
    while (sp_pop_garbage(&SP, &g)) free_garbage(&g);
    pthread_mutex_unlock(&OUT.ctl);
    midi_stop_locked();
    pthread_mutex_unlock(&E.lock);
    return ok_atom(env);
}

/* reset() -> ok | {error, not_owner | busy}: everything off: voices fade,
 * pads cleared, samples unloaded, pattern dropped, sequencer stopped at 120
 * bpm, straight. `busy` (the command queue is full) changes nothing. */
static ERL_NIF_TERM nif_reset(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    pthread_mutex_lock(&OUT.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&OUT.ctl);
        return error_tuple(env, "not_owner");
    }
    sp_cmd c = {.type = SP_CMD_RESET};
    bool queued = ctl_push(&c);
    if (queued) clear_ids_locked();
    pthread_mutex_unlock(&OUT.ctl);
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

static void queue_job(load_job *job) { lq_push(&E.loads, &job->q); }

/* Claim (or reuse) sample `id`'s slot for a new request, making every
 * earlier load of it stale: the slot, or -1 with `*failure` set. Caller
 * holds OUT.ctl and is the owner. */
static int claim_slot_locked(ERL_NIF_TERM id, uint64_t *request, const char **failure) {
    int slot = find_id(id);
    if (slot < 0) {
        for (int i = 0; i < SP_SLOTS && slot < 0; i++)
            if (!E.ids[i].used) slot = i;
        if (slot < 0) {
            *failure = "too_many_samples";
            return -1;
        }
        E.ids[slot] = (id_entry){.used = true, .env = enif_alloc_env()};
        E.ids[slot].id = enif_make_copy(E.ids[slot].env, id);
    }
    E.ids[slot].request = ++E.requests;
    *request = E.ids[slot].request;
    return slot;
}

/* load_pcm(Id, Pcm, Rate, Channels) -> ok | {error, not_owner |
 * too_many_samples | thread | alloc}: interleaved f32le PCM (the library's
 * canonical form) as sample Id, on the loader thread; the result arrives as
 * {magpie_audio, loaded, Id, {ok, Info} | {error, Reason}}. A later load or
 * unload of the same Id makes this one {error, cancelled}. The binary is
 * held, not copied, until the loader has converted it. */
static ERL_NIF_TERM nif_load_pcm(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int rate, channels;
    if (!enif_is_binary(env, argv[1]) || !get_range(env, argv[2], 1000, 384000, &rate) ||
        !get_range(env, argv[3], 1, 8, &channels))
        return enif_make_badarg(env);
    if (!ensure_loader()) return error_tuple(env, "thread");
    load_job *job = calloc(1, sizeof(*job));
    if (!job) return error_tuple(env, "alloc");
    job->env = enif_alloc_env();
    job->pcm = enif_make_copy(job->env, argv[1]);
    job->source_rate = rate;
    job->channels = channels;
    job->id = enif_make_copy(job->env, argv[0]);
    const char *failure = NULL;
    pthread_mutex_lock(&OUT.ctl);
    if (!is_owner(env)) failure = "not_owner";
    else job->slot = claim_slot_locked(argv[0], &job->request, &failure);
    job->rate = mio_rate();
    pthread_mutex_unlock(&OUT.ctl);
    if (failure) {
        free_job(job);
        return error_tuple(env, failure);
    }
    queue_job(job);
    return ok_atom(env);
}

/* load_claim(Id) -> {ok, Ticket} | {error, not_owner | too_many_samples}:
 * a file load of sample Id begins (Magpie.Audio.Native decodes it): the
 * slot is claimed and the load queued now, pending, so loads and unloads of
 * Id keep the order they were made in, and so do their `loaded` messages.
 * load_ticket/4 or load_ticket_failed/2 with Ticket finishes it. */
static ERL_NIF_TERM nif_load_claim(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    if (!ensure_loader()) return error_tuple(env, "thread");
    load_job *job = calloc(1, sizeof(*job));
    if (!job) return error_tuple(env, "alloc");
    job->env = enif_alloc_env();
    job->id = enif_make_copy(job->env, argv[0]);
    job->q.pending = true;
    const char *failure = NULL;
    pthread_mutex_lock(&OUT.ctl);
    if (!is_owner(env)) failure = "not_owner";
    else job->slot = claim_slot_locked(argv[0], &job->request, &failure);
    job->rate = mio_rate();
    pthread_mutex_unlock(&OUT.ctl);
    if (failure) {
        free_job(job);
        return error_tuple(env, failure);
    }
    uint64_t ticket = job->q.request = job->request;
    queue_job(job);
    return enif_make_tuple2(env, ok_atom(env), enif_make_uint64(env, ticket));
}

typedef struct {
    ERL_NIF_TERM pcm;
    int rate, channels;
    const char *failure;
} ticket_fill;

/* lq_fill's: the decode's PCM, or its failure, into the pending job. */
static void fill_job(lq_job *q, void *arg) {
    load_job *job = (load_job *)q;
    const ticket_fill *f = arg;
    if (f->failure) {
        job->q.failure = f->failure;
        return;
    }
    job->pcm = enif_make_copy(job->env, f->pcm);
    job->source_rate = f->rate;
    job->channels = f->channels;
}

/* load_ticket(Ticket, Pcm, Rate, Channels) -> ok | {error, not_pending}:
 * the claimed load's decoded f32le PCM (as load_pcm/4; a load of the same
 * Id made since the claim makes it {error, cancelled}). Anyone (the
 * decoding process). */
static ERL_NIF_TERM nif_load_ticket(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifUInt64 ticket;
    int rate, channels;
    if (!enif_get_uint64(env, argv[0], &ticket) || !enif_is_binary(env, argv[1]) ||
        !get_range(env, argv[2], 1000, 384000, &rate) || !get_range(env, argv[3], 1, 8, &channels))
        return enif_make_badarg(env);
    ticket_fill f = {argv[1], rate, channels, NULL};
    return lq_fill(&E.loads, ticket, fill_job, &f) ? ok_atom(env) : error_tuple(env, "not_pending");
}

/* load_ticket_failed(Ticket, Reason) -> ok | {error, not_pending}: the
 * claimed load's file didn't decode; the owner hears {error, Reason} in the
 * load's turn. Anyone. */
static ERL_NIF_TERM nif_load_ticket_failed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    static const char *reasons[] = {"not_found", "unsupported", "no_audio", "decode_error",
                                    "too_long",  "alloc",       "busy",     "cancelled"};
    ErlNifUInt64 ticket;
    char name[16];
    const char *reason = NULL;
    if (!enif_get_uint64(env, argv[0], &ticket) || !enif_get_atom(env, argv[1], name, sizeof(name), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    for (size_t i = 0; i < sizeof(reasons) / sizeof(reasons[0]) && !reason; i++)
        if (strcmp(name, reasons[i]) == 0) reason = reasons[i];
    if (!reason) return enif_make_badarg(env);
    ticket_fill f = {0, 0, 0, reason};
    return lq_fill(&E.loads, ticket, fill_job, &f) ? ok_atom(env) : error_tuple(env, "not_pending");
}

/* import_chunk(Chunk, Channels) -> {Pcm, Peaks}: a decoded chunk of
 * interleaved native-endian f32 (`Channels` per frame) as the library
 * keeps it: the first two channels, clipped to ±1, with its peaks (one byte
 * per 256 frames). Anyone. */
static ERL_NIF_TERM nif_import_chunk(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary in;
    int channels;
    if (!enif_inspect_binary(env, argv[0], &in) || !get_range(env, argv[1], 1, 64, &channels) ||
        in.size % (4 * (size_t)channels) != 0)
        return enif_make_badarg(env);
    int keep = channels > 2 ? 2 : channels;
    int64_t frames = (int64_t)(in.size / (4 * (size_t)channels));
    ERL_NIF_TERM pcm, peaks;
    float *out = (float *)enif_make_new_binary(env, (size_t)frames * (size_t)keep * sizeof(float), &pcm);
    uint8_t *p = enif_make_new_binary(env, (size_t)sp_peak_count(frames), &peaks);
    if (!out || !p) return error_tuple(env, "alloc");
    mio_import_chunk(in.data, frames, channels, keep, out, p);
    return enif_make_tuple2(env, pcm, peaks);
}

/* unload_sample(Id) -> ok | {error, not_owner | unknown_sample | busy}.
 * Voices playing it fade out, pads using it are cleared, a load in flight
 * is cancelled; the memory is freed once the last voice has faded. `busy`
 * (the command queue is full) changes nothing. */
static ERL_NIF_TERM nif_unload_sample(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    pthread_mutex_lock(&OUT.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&OUT.ctl);
        return error_tuple(env, "not_owner");
    }
    int slot = find_id(argv[0]);
    if (slot < 0) {
        pthread_mutex_unlock(&OUT.ctl);
        return error_tuple(env, "unknown_sample");
    }
    sp_cmd c = {.type = SP_CMD_SAMPLE, .u.sample = {slot, NULL}};
    if (E.ids[slot].loaded && !ctl_push(&c)) {
        pthread_mutex_unlock(&OUT.ctl);
        return error_tuple(env, "busy");
    }
    enif_free_env(E.ids[slot].env);
    E.ids[slot] = (id_entry){0};
    pthread_mutex_unlock(&OUT.ctl);
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

    pthread_mutex_lock(&OUT.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&OUT.ctl);
        return error_tuple(env, "not_owner");
    }
    int slot = empty ? -1 : find_id(t[0]);
    if (!empty && (slot < 0 || !E.ids[slot].loaded)) {
        pthread_mutex_unlock(&OUT.ctl);
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
    pthread_mutex_unlock(&OUT.ctl);
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

    pthread_mutex_lock(&OUT.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&OUT.ctl);
        free(p);
        return error_tuple(env, "not_owner");
    }
    p->id = ++E.patterns;
    sp_cmd c = {.type = SP_CMD_PATTERN, .u.pattern = {p, at_bar}};
    bool queued = ctl_push(&c);
    pthread_mutex_unlock(&OUT.ctl);
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
    int rate = atomic_load(&OUT.rate);
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

/* info() -> map of the engine's diagnostics (Magpie.Audio.Native merges
 * the streams' from mob_audio_io). Dirty IO. */
static ERL_NIF_TERM nif_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    enum { N = 21 };
    pthread_mutex_lock(&E.lock);
    int rate = atomic_load(&OUT.rate);
    int64_t cbs = atomic_load(&OUT.cb_count), cb_sum = atomic_load(&OUT.cb_ns_sum),
            cb_frames = atomic_load(&OUT.cb_frames);
    pthread_mutex_lock(&OUT.ctl);
    int samples = 0;
    for (int i = 0; i < SP_SLOTS; i++) samples += E.ids[i].loaded;
    pthread_mutex_unlock(&OUT.ctl);
    ERL_NIF_TERM keys[N] = {
        atom(env, "running"),          atom(env, "rate"),              atom(env, "callbacks"),
        atom(env, "callback_mean_us"), atom(env, "callback_max_us"),   atom(env, "callback_gap_max_us"),
        atom(env, "cpu_load"),         atom(env, "voices_active"),     atom(env, "voices_peak"),
        atom(env, "steals"),           atom(env, "hard_cuts"),         atom(env, "trigger_latency_ms"),
        atom(env, "samples"),          atom(env, "sample_bytes"),      atom(env, "dropped"),
        atom(env, "playing"),          atom(env, "frame"),             atom(env, "starts"),
        atom(env, "skipped"),          atom(env, "input"),             atom(env, "midi"),
    };
    ERL_NIF_TERM dropped[3] = {enif_make_uint64(env, atomic_load(&SP.cmds_dropped)),
                               enif_make_uint64(env, atomic_load(&SP.events_dropped)),
                               enif_make_uint64(env, atomic_load(&SP.actions_dropped))};
    ERL_NIF_TERM dropped_keys[3] = {atom(env, "commands"), atom(env, "events"), atom(env, "actions")};
    ERL_NIF_TERM vals[N] = {
        atom(env, atomic_load(&OUT.running) ? "true" : "false"),
        enif_make_int(env, rate),
        enif_make_int64(env, cbs),
        enif_make_double(env, cbs ? (double)cb_sum / cbs / 1000.0 : 0),
        enif_make_double(env, atomic_load(&OUT.cb_ns_max) / 1000.0),
        enif_make_double(env, atomic_load(&OUT.cb_gap_max) / 1000.0),
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
        enif_make_int64(env, atomic_load(&OUT.engine_frame)),
        enif_make_int64(env, atomic_load(&OUT.starts)),
        enif_make_int64(env, atomic_load(&OUT.skipped)),
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
    atomic_store(&OUT.cb_count, 0);
    atomic_store(&OUT.cb_ns_sum, 0);
    atomic_store(&OUT.cb_ns_max, 0);
    atomic_store(&OUT.cb_gap_max, 0);
    atomic_store(&OUT.cb_frames, 0);
    atomic_store(&OUT.cb_last_start, 0);
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
    atomic_store(&OUT_STATS.refused, 0);
    atomic_store(&OUT_STATS.discards, 0);
    atomic_store(&OUT_STATS.offs_owed, 0);
    pthread_mutex_unlock(&E.stats_lock);
    return ok_atom(env);
}

static bool owner_now(ErlNifEnv *env) {
    pthread_mutex_lock(&OUT.ctl);
    bool mine = is_owner(env);
    pthread_mutex_unlock(&OUT.ctl);
    return mine;
}

/* input_sources() -> [mic | apps]: the sources input_open/1 can open here
 * (other apps' audio is Android's). */
static ERL_NIF_TERM nif_input_sources(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
#ifdef __ANDROID__
    return enif_make_list2(env, atom(env, "mic"), atom(env, "apps"));
#else
    return enif_make_list1(env, atom(env, "mic"));
#endif
}

/* input_open(mic | apps) -> {ok, Input, Rate} | {ok, Input} | {error,
 * Reason}: close any input, then open this one as Input (a positive
 * integer). The mic: OPENING at the engine's Rate, until "magpie_mic"'s
 * stream (Magpie.Audio.Native.Io opens it next) starts; other apps:
 * Kotlin asks for consent. The owner hears {magpie_audio, input, Input,
 * started, Info} or {magpie_audio, input, Input, closed, Reason}. Reasons
 * now: not_owner (nothing changed), unsupported (other apps below API 29,
 * or on iOS), busy, no_activity, error (what was open is closed). Dirty
 * IO. */
static ERL_NIF_TERM nif_input_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int source = enif_is_identical(argv[0], atom(env, "mic"))    ? SRC_MIC
                 : enif_is_identical(argv[0], atom(env, "apps")) ? SRC_APPS
                                                                 : SRC_NONE;
    if (source == SRC_NONE) return enif_make_badarg(env);
    pthread_mutex_lock(&IN.lock);
    const char *failure = NULL;
    ERL_NIF_TERM opened = 0;
    int rate = mio_rate();
    if (!owner_now(env)) {
        failure = "not_owner";
    } else {
        close_input_locked();
        int64_t id = atomic_fetch_add(&IN.gen, 1) + 1;
        atomic_store(&IN.callbacks, 0);
        atomic_store(&IN.clock_misses, 0);
        atomic_store(&IN.newest_ns, 0);
        atomic_store(&IN.source, source);
        atomic_store(&IN.status, IN_OPENING);
        if (source == SRC_MIC) {
            opened = enif_make_tuple3(env, ok_atom(env), enif_make_int64(env, id), enif_make_int(env, rate));
        } else {
            failure = capture_start(rate, id);
            if (failure) close_input_locked();
            else opened = enif_make_tuple2(env, ok_atom(env), enif_make_int64(env, id));
        }
    }
    pthread_mutex_unlock(&IN.lock);
    return failure ? error_tuple(env, failure) : opened;
}

/* input_close() -> ok | {error, not_owner}: close the input; a recording
 * in progress is dropped (the mic's stream: Magpie.Audio.Native.Io closes
 * it after this). Dirty IO. */
static ERL_NIF_TERM nif_input_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    pthread_mutex_lock(&IN.lock);
    bool mine = owner_now(env);
    if (mine) close_input_locked();
    pthread_mutex_unlock(&IN.lock);
    return mine ? ok_atom(env) : error_tuple(env, "not_owner");
}

/* record_start(now | on_sound | count_in, MaxSeconds, ThresholdDb,
 * PreRollMs) -> {ok, Take} | {error, not_owner | no_input | recording |
 * not_running | alloc | busy}. Arms the recorder on the open input as Take
 * (a positive integer), its buffer for MaxSeconds allocated now. on_sound:
 * from the first frame at or over ThresholdDb (dBFS), PreRollMs before it;
 * count_in: one bar of clicks at the tempo (from the sequencer's next bar
 * while it plays), then from the audio captured when the downbeat after
 * them is heard. */
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
    else if (mode == RC_AT_TIME && !atomic_load(&OUT.running)) failure = "not_running";
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
            pthread_mutex_lock(&OUT.ctl);
            bool queued = ctl_push(&c);
            pthread_mutex_unlock(&OUT.ctl);
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

/* The input in info/0: nil, or what is open and how it runs (the mic
 * stream's own figures come from mob_audio_io, merged by
 * Magpie.Audio.Native). Caller holds nothing but `lock`. */
static ERL_NIF_TERM input_info(ErlNifEnv *env) {
    pthread_mutex_lock(&IN.lock);
    int source = atomic_load(&IN.source);
    ERL_NIF_TERM result = atom(env, "nil");
    if (source != SRC_NONE) {
        int64_t newest = atomic_load(&IN.newest_ns);
        int status = atomic_load(&IN.status);
        bool open = status == IN_OPEN;
        ERL_NIF_TERM keys[9] = {atom(env, "source"),       atom(env, "status"),     atom(env, "rate"),
                                atom(env, "channels"),     atom(env, "callbacks"),  atom(env, "clock_misses"),
                                atom(env, "latency_ms"),   atom(env, "recorder"),   atom(env, "stream")};
        ERL_NIF_TERM vals[9] = {
            atom(env, source == SRC_MIC ? "mic" : "apps"),
            atom(env, open ? "open" : status == IN_OPENING ? "opening" : "closed"),
            enif_make_int(env, open ? REC.rate : 0),
            enif_make_int(env, open ? REC.channels : 0),
            enif_make_int64(env, atomic_load(&IN.callbacks)),
            enif_make_int64(env, atomic_load(&IN.clock_misses)),
            enif_make_double(env, newest > 0 ? (double)(now_ns() - newest) / 1e6 : -1),
            atom(env, IN.armed ? rec_state_name(atomic_load(&REC.state)) : "idle"),
            enif_make_int(env, atomic_load(&IN.mic_stream)),
        };
        result = make_map(env, keys, vals, 9);
    }
    pthread_mutex_unlock(&IN.lock);
    return result;
}

/* set_midi(nil | {InChannel, OutChannel, Clock, NoteMasks, OutNotes}) -> ok
 * | {error, not_owner | busy | alloc}: the kit's MIDI table (owner only).
 * InChannel 0 (all) | 1..16, OutChannel 1..16, Clock internal | send,
 * NoteMasks 128 integers (a bit per pad), OutNotes 64 integers (-1: the
 * pad sends nothing). */
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
    pthread_mutex_lock(&OUT.ctl);
    if (!is_owner(env)) {
        pthread_mutex_unlock(&OUT.ctl);
        free(m);
        return error_tuple(env, "not_owner");
    }
    sp_cmd c = {.type = SP_CMD_MIDI_MAP, .u.map = m};
    bool queued = ctl_push(&c);
    pthread_mutex_unlock(&OUT.ctl);
    if (!queued) {
        free(m);
        return error_tuple(env, "busy");
    }
    return ok_atom(env);
}

/* midi_outputs([Handle]) -> ok: the outputs MIDI out goes to, as mob_midi
 * output handles (Magpie's own device's output, each opened device's
 * input). An output kept from the last list keeps what it is owed. Anyone;
 * dirty IO (waits for the sending thread's current send). */
static ERL_NIF_TERM nif_midi_outputs(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    unsigned len;
    if (!enif_get_list_length(env, argv[0], &len) || len > MIDI_OUTPUTS) return enif_make_badarg(env);
    mob_midi_port handles[MIDI_OUTPUTS];
    ERL_NIF_TERM head, tail = argv[0];
    for (unsigned i = 0; enif_get_list_cell(env, tail, &head, &tail); i++) {
        ErlNifSInt64 h;
        if (!enif_get_int64(env, head, &h) || h <= 0) return enif_make_badarg(env);
        handles[i] = (mob_midi_port)h;
    }
    pthread_mutex_lock(&MI.out_lock);
    for (unsigned i = 0; i < len; i++) {
        MI.next[i] = (midi_out){.handle = handles[i]};
        for (int k = 0; k < MI.n_outs; k++)
            if (MI.outs[k].handle == handles[i]) MI.next[i] = MI.outs[k];
    }
    memcpy(MI.outs, MI.next, len * sizeof(midi_out));
    MI.n_outs = (int)len;
    pthread_mutex_unlock(&MI.out_lock);
    return ok_atom(env);
}

/* midi_sources_changed() -> ok: an input closed or changed hands (see
 * midi_sources_check). Anyone; dirty IO (may apply commands offline). */
static ERL_NIF_TERM nif_midi_sources_changed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    midi_sources_check();
    return ok_atom(env);
}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    pcm_type = enif_open_resource_type(env, NULL, "magpie_pcm", pcm_dtor, ERL_NIF_RT_CREATE, NULL);
    if (!pcm_type) return 1;
    pthread_mutex_init(&E.lock, NULL);
    pthread_mutex_init(&MI.out_lock, NULL);
    for (int i = 0; i < MIDI_SOURCES; i++) pthread_mutex_init(&MI.sources[i].lock, NULL);
    pthread_mutex_init(&E.jobs_lock, NULL);
    pthread_mutex_init(&E.stats_lock, NULL);
    lq_init(&E.loads);
    mio_init();
    /* The output and the mic: open/1 refuses without them. */
    E.io_registered = mio_register();
    if (E.io_registered != MAI_OK)
        LOGE("no processors (%d; mob_audio_io ABI %d, built against %d)", (int)E.io_registered,
             (int)mai_abi_version(), MAI_ABI_VERSION);
    /* Audio frames and MIDI timestamps must be on one clock. */
    int64_t skew = mob_midi_now_ns() - mai_now_ns();
    if (skew > 1000000 || skew < -1000000) LOGE("midi: mob_midi's clock is %lld ns off mob_audio_io's", (long long)skew);
    /* MIDI in from mob_midi's threads: the sources' locks are ready. */
    int rc = mob_midi_abi_version() == MOB_MIDI_ABI_VERSION ? mob_midi_set_sink(midi_sink, NULL) : MOB_MIDI_ERR_INVALID;
    MI.sink = rc == MOB_MIDI_OK;
    if (!MI.sink)
        LOGE("midi: no sink (%d; mob_midi ABI %d, built against %d)", rc, (int)mob_midi_abi_version(),
             MOB_MIDI_ABI_VERSION);
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"open", 1, nif_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close", 0, nif_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"reset", 0, nif_reset, 0},
    {"load_pcm", 4, nif_load_pcm, 0},
    {"load_claim", 1, nif_load_claim, 0},
    {"load_ticket", 4, nif_load_ticket, 0},
    {"load_ticket_failed", 2, nif_load_ticket_failed, 0},
    {"import_chunk", 2, nif_import_chunk, 0},
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
    {"input_sources", 0, nif_input_sources, 0},
    {"input_open", 1, nif_input_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"input_close", 0, nif_input_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"record_start", 4, nif_record_start, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"record_stop", 0, nif_record_stop, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"record_cancel", 0, nif_record_cancel, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_midi", 1, nif_set_midi, 0},
    {"midi_outputs", 1, nif_midi_outputs, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"midi_sources_changed", 0, nif_midi_sources_changed, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.Magpie.Audio.Nif, nif_funcs, on_load, NULL, NULL, NULL)
