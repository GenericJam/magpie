/*
 * c_src/load_queue.c — the loader thread's queue (plain C, in the host
 * harness c_src/test/io_host.c; c_src/magpie_audio.c embeds an lq_job at
 * the start of its load jobs).
 *
 * Jobs run in the order they were queued. A file load is queued when it is
 * claimed, `pending` until its decode (an Elixir process) hands over the
 * PCM or the failure (lq_fill); the loader waits for it in its turn, so
 * every load of an id finishes, and its `loaded` message goes out, in the
 * order the loads were made: Magpie.Engine hands each one to the caller
 * waiting longest for that id. A pending job nobody fills within the
 * timeout finishes as "decode_error".
 */

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>

typedef struct lq_job {
    struct lq_job *next;
    uint64_t request; /* the ticket of a pending job */
    bool pending;
    const char *failure;
} lq_job;

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t cv;
    lq_job *head, *tail, *waiting; /* `waiting`: the pending job lq_take waits on */
} lq_queue;

static void lq_init(lq_queue *q) {
    pthread_mutex_init(&q->lock, NULL);
    pthread_cond_init(&q->cv, NULL);
    q->head = q->tail = q->waiting = NULL;
}

static void lq_push(lq_queue *q, lq_job *j) {
    j->next = NULL;
    pthread_mutex_lock(&q->lock);
    if (q->tail) q->tail->next = j;
    else q->head = j;
    q->tail = j;
    pthread_cond_broadcast(&q->cv);
    pthread_mutex_unlock(&q->lock);
}

/* The loader: the next job, once it isn't pending (or, pending for
 * `timeout_ms`, failed as "decode_error"). Blocks while the queue is empty. */
static lq_job *lq_take(lq_queue *q, int64_t timeout_ms) {
    pthread_mutex_lock(&q->lock);
    while (!q->head) pthread_cond_wait(&q->cv, &q->lock);
    lq_job *j = q->head;
    q->head = j->next;
    if (!q->head) q->tail = NULL;
    if (j->pending) {
        q->waiting = j;
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        int64_t ns = until.tv_nsec + (timeout_ms % 1000) * 1000000LL;
        until.tv_sec += (time_t)(timeout_ms / 1000 + ns / 1000000000LL);
        until.tv_nsec = (long)(ns % 1000000000LL);
        while (j->pending && pthread_cond_timedwait(&q->cv, &q->lock, &until) != ETIMEDOUT) {
        }
        if (j->pending) {
            j->pending = false;
            j->failure = "decode_error";
        }
        q->waiting = NULL;
    }
    pthread_mutex_unlock(&q->lock);
    return j;
}

/* Finish pending job `ticket` with `fill(job, arg)` (under the queue's
 * lock): true, or false when no job of that ticket is pending (it finished
 * or timed out already). */
static bool lq_fill(lq_queue *q, uint64_t ticket, void (*fill)(lq_job *, void *), void *arg) {
    pthread_mutex_lock(&q->lock);
    lq_job *j = q->waiting && q->waiting->pending && q->waiting->request == ticket ? q->waiting : NULL;
    for (lq_job *k = q->head; !j && k; k = k->next)
        if (k->pending && k->request == ticket) j = k;
    if (j) {
        fill(j, arg);
        j->pending = false;
        pthread_cond_broadcast(&q->cv);
    }
    pthread_mutex_unlock(&q->lock);
    return j != NULL;
}
