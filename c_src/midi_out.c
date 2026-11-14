/*
 * c_src/midi_out.c — what each MIDI output took, refused and is owed.
 * magpie_audio.c's sending thread sends every batch of messages (notes,
 * clock, transport; c_src/midi.c's mo_event) to every output through
 * mob_midi_send. Plain C over mob_midi.h's send / discard, so the host test
 * (c_src/test/midi_host.c) runs it against a fake port.
 *
 * mob_midi refuses every send to a port whose queue filled (a listener that
 * stopped reading) until the queue has drained. A note-off must still get
 * out: one refused is owed, and goes before anything else once the port
 * takes sends again. What the port still queued at the refusal is late
 * (notes and clock a stalled listener would get in a burst), so it is
 * discarded, and the note-offs that were among it are owed too.
 *
 * Includers include mob_midi.h and sampler.c (midi.c) first.
 */

#define MIDI_NOTES (16 * 128) /* a bit per channel and note */
#define MIDI_NOTE_WORDS (MIDI_NOTES / 64)

/* An output and what it owes. A bit per channel and note: `held`, note-ons
 * the port took whose note-off it hasn't; `offs`, note-offs it took since
 * it last refused (the discard at a refusal may drop them, so they are owed
 * then); `owed`, the note-offs to send first. */
typedef struct {
    mob_midi_port handle;
    bool refusing;
    uint64_t held[MIDI_NOTE_WORDS], offs[MIDI_NOTE_WORDS], owed[MIDI_NOTE_WORDS];
} midi_out;

/* refused: messages an output refused; discards: queues dropped at a
 * refusal; offs_owed: note-offs sent after a refusal. */
static struct {
    _Atomic uint64_t refused, discards, offs_owed;
} OUT_STATS;

static inline void bit_set(uint64_t *m, int i) { m[i >> 6] |= 1ull << (i & 63); }
static inline void bit_clear(uint64_t *m, int i) { m[i >> 6] &= ~(1ull << (i & 63)); }
static inline bool bit_test(const uint64_t *m, int i) { return (m[i >> 6] >> (i & 63)) & 1; }

/* 1 a note-on, -1 a note-off (or note-on velocity 0), 0 anything else. */
static int note_kind(const mo_event *ev) {
    if (ev->kind != MO_NOTE) return 0;
    uint8_t k = ev->b[0] & 0xF0;
    if (k == 0x90 && ev->b[2] > 0) return 1;
    return k == 0x80 || k == 0x90 ? -1 : 0;
}

/* What the port took (`taken`) or refused of a send. A refused note-on was
 * never heard and owes nothing; a refused note-off of a held note is owed. */
static void out_track(midi_out *o, const mo_event *evs, int count, bool taken) {
    for (int i = 0; i < count; i++) {
        int kind = note_kind(&evs[i]);
        if (!kind) continue;
        int b = (evs[i].b[0] & 0x0F) * 128 + (evs[i].b[1] & 0x7F);
        if (taken && kind > 0) {
            bit_set(o->held, b);
        } else if (taken) {
            bit_clear(o->held, b);
            bit_set(o->offs, b);
        } else if (kind < 0 && bit_test(o->held, b)) {
            bit_clear(o->held, b);
            bit_set(o->owed, b);
        }
    }
}

/* The port refused a send: it refuses every one until it has drained.
 * What it still queues goes; the note-offs that were among it are owed. */
static void out_refuse(midi_out *o) {
    o->refusing = true;
    if (mob_midi_discard(o->handle) > 0) atomic_fetch_add_explicit(&OUT_STATS.discards, 1, memory_order_relaxed);
    for (int w = 0; w < MIDI_NOTE_WORDS; w++) {
        o->owed[w] |= o->offs[w];
        o->offs[w] = 0;
    }
}

/* Owed note-offs to send: not those of notes held again since (a note-on
 * the port took after), whose voice's own note-off ends them. */
static bool out_owes(const midi_out *o) {
    for (int w = 0; w < MIDI_NOTE_WORDS; w++)
        if (o->owed[w] & ~o->held[w]) return true;
    return false;
}

/* The owed note-offs, in one send at `at` (<= 0: now). True when the port
 * took them (it takes sends again), or has gone or lost its listeners
 * (nothing sounds there): nothing is owed any more. */
static bool out_pay(midi_out *o, int64_t at) {
    uint8_t buf[MIDI_NOTES * 3];
    size_t n = 0;
    for (int w = 0; w < MIDI_NOTE_WORDS; w++) {
        for (uint64_t m = o->owed[w] & ~o->held[w]; m; m &= m - 1) {
            int b = w * 64 + __builtin_ctzll(m);
            buf[n++] = (uint8_t)(0x80 | (b >> 7));
            buf[n++] = (uint8_t)(b & 0x7F);
            buf[n++] = 0;
        }
    }
    int rc = n ? mob_midi_send(o->handle, buf, n, at) : MOB_MIDI_OK;
    if (rc == MOB_MIDI_ERR_QUEUE_FULL) return false;
    if (rc == MOB_MIDI_OK) {
        for (int w = 0; w < MIDI_NOTE_WORDS; w++) o->offs[w] |= o->owed[w] & ~o->held[w];
        atomic_fetch_add_explicit(&OUT_STATS.offs_owed, n / 3, memory_order_relaxed);
    }
    memset(o->owed, 0, sizeof(o->owed));
    o->refusing = false;
    return true;
}

/* One batch (`count` messages, `n` bytes) to one output at `at`: the owed
 * note-offs first, and the batch only once the port took them. */
static void out_send(midi_out *o, const uint8_t *buf, int n, const mo_event *evs, int count, int64_t at) {
    bool was_refusing = o->refusing;
    int rc = MOB_MIDI_ERR_QUEUE_FULL;
    if (!out_owes(o) || out_pay(o, at)) rc = mob_midi_send(o->handle, buf, (size_t)n, at);
    switch (rc) {
    case MOB_MIDI_OK:
        /* Taking sends again: what was still owed is of notes held again. */
        o->refusing = false;
        memset(o->owed, 0, sizeof(o->owed));
        out_track(o, evs, count, true);
        break;
    case MOB_MIDI_ERR_QUEUE_FULL:
        /* Refusing already (still draining): its queue went at the first
         * refusal (and what it took just now, if anything, still queues). */
        if (!was_refusing) out_refuse(o);
        o->refusing = true;
        out_track(o, evs, count, false);
        atomic_fetch_add_explicit(&OUT_STATS.refused, (uint64_t)count, memory_order_relaxed);
        break;
    case MOB_MIDI_ERR_NO_LISTENER:
        /* Nobody listens to Magpie's own output: nothing sounds there. */
        *o = (midi_out){.handle = o->handle};
        break;
    default:
        /* Closed (Magpie.Midi takes it out of the list next): dropped. */
        break;
    }
}

/* Nothing else to send: a refusing output owed note-offs tries them (once
 * it has drained they needn't wait for the next note or tick). */
static void out_retry(midi_out *o) {
    if (o->refusing && out_owes(o)) out_pay(o, 0);
}
