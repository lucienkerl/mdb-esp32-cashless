/*
 * mdb_trace.h — live MDB bus trace: lock-free capture ring + batch encoder.
 *
 * Why this exists: the regular `/mdb-log` payload is a state snapshot, it says
 * nothing about what actually crossed the bus. For field debugging (a VMC that
 * never leaves DISABLED, a checksum error that only shows up on one machine)
 * the operator needs the raw words, in order, as they happen.
 *
 * Constraints that shape the design:
 *  - The capture point is `read_9()` / `write_payload_9()`, i.e. the 9600-baud
 *    bit-banged MDB path. It must never block, never take a FreeRTOS lock and
 *    never touch the network. So the producer only does a bounded store into a
 *    single-producer / single-consumer ring and returns.
 *  - A separate low-priority task owns the consumer side: it groups words into
 *    frames, encodes a JSON batch and publishes it over MQTT.
 *  - Nothing is captured unless a trace was explicitly started (and it expires
 *    on its own): the cost on a cellular uplink is real.
 *
 * The header is pure C11 (no ESP-IDF includes) so the encoder can be unit
 * tested on the host: see test/trace/run.sh.
 *
 * All shared fields are 32-bit atomics on purpose: on Xtensa the toolchain
 * turns 8/16-bit atomics into library calls that take a spinlock, which has no
 * business in the MDB sampling path. 32-bit loads/stores are plain
 * instructions.
 *
 * Threading contract (SPSC):
 *   producer  : mdb_trace_push()                       — MDB task only
 *   consumer  : mdb_trace_drain_json()                 — trace task only
 *   any task  : mdb_trace_set_active() / _is_active()  — flag only
 *
 * Wire format of one batch (JSON, plaintext like /mdb-log):
 *
 *   {"drop":0,"f":[[12,"t","10B"],[9,"r","1120"],...]}
 *
 *   drop : words lost to ring overflow since the previous batch
 *   f    : frames, oldest first; each is [age_ms, dir, words]
 *          age_ms : milliseconds between the frame's first word and the moment
 *                   the batch was built (the receiver subtracts it from its own
 *                   clock — the device may have no wall-clock time)
 *          dir    : "r" received from the bus, "t" transmitted by this device
 *          words  : concatenated 3-digit upper-case hex, one per 9-bit MDB word
 *                   (bit 8 is the mode bit): "10B" = address/mode word 0x10B.
 */
#ifndef MDB_TRACE_H
#define MDB_TRACE_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* Ring capacity in words. Power of two. A vend burst is a few hundred words,
 * the consumer drains every ~500 ms, so 1024 leaves wide margin even if one
 * MQTT publish stalls. 8 KB of static RAM. */
#define MDB_TRACE_RING_SIZE      1024u

/* Longest MDB block we keep in one frame (data + checksum). */
#define MDB_TRACE_MAX_WORDS      36u

/* Two words further apart than this are not part of the same frame. One 9-bit
 * word takes ~1.15 ms on the wire and the spec allows up to 1 ms of idle
 * between bytes of a block, so consecutive words of a block land ≤ ~2.2 ms
 * apart; a VMC poll cycle is far longer. */
#define MDB_TRACE_FRAME_GAP_US   3000u

#define MDB_TRACE_MODE_BIT       0x100u

typedef enum {
    MDB_TRACE_RX = 0,   /* seen on the bus (VMC or another peripheral) */
    MDB_TRACE_TX = 1,   /* driven by this device */
} mdb_trace_dir_t;

typedef struct {
    uint32_t t_us;      /* low 32 bits of the µs clock when the word completed */
    uint16_t word;      /* 9-bit MDB word, bit 8 = mode bit */
    uint8_t  dir;       /* mdb_trace_dir_t */
} mdb_trace_entry_t;

typedef struct {
    mdb_trace_entry_t entries[MDB_TRACE_RING_SIZE];
    _Atomic uint32_t  head;      /* next slot to write — producer owned   */
    _Atomic uint32_t  tail;      /* next slot to read  — consumer owned   */
    _Atomic uint32_t  dropped;   /* words lost because the ring was full  */
    _Atomic uint32_t  active;    /* capture on/off (32-bit on purpose, see below) */

    /* Consumer-owned: the frame currently being assembled. */
    uint16_t cur_words[MDB_TRACE_MAX_WORDS];
    uint8_t  cur_len;
    uint8_t  cur_dir;
    uint32_t cur_first_us;
    uint32_t cur_last_us;
} mdb_trace_ring_t;

static inline void mdb_trace_set_active(mdb_trace_ring_t *r, bool on)
{
    atomic_store_explicit(&r->active, on ? 1 : 0, memory_order_release);
}

static inline bool mdb_trace_is_active(mdb_trace_ring_t *r)
{
    return atomic_load_explicit(&r->active, memory_order_relaxed) != 0;
}

/* Producer. Wait-free, no locks, safe to call with interrupts disabled. */
static inline void mdb_trace_push(mdb_trace_ring_t *r, uint16_t word,
                                  mdb_trace_dir_t dir, uint32_t t_us)
{
    if (!mdb_trace_is_active(r)) return;

    uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);

    if (head - tail >= MDB_TRACE_RING_SIZE) {
        atomic_fetch_add_explicit(&r->dropped, 1, memory_order_relaxed);
        return;
    }

    mdb_trace_entry_t *e = &r->entries[head & (MDB_TRACE_RING_SIZE - 1u)];
    e->t_us = t_us;
    e->word = word & 0x1FFu;
    e->dir  = (uint8_t) dir;

    atomic_store_explicit(&r->head, head + 1u, memory_order_release);
}

/* Would `e` start a new frame rather than extend the open one? */
static inline bool mdb_trace_breaks_frame(const mdb_trace_ring_t *r,
                                          const mdb_trace_entry_t *e)
{
    if (e->dir != r->cur_dir)                                  return true;
    if (r->cur_len >= MDB_TRACE_MAX_WORDS)                     return true;
    if ((uint32_t)(e->t_us - r->cur_last_us) > MDB_TRACE_FRAME_GAP_US) return true;

    /* Two mode-bit words back to back are an address/ACK following another
     * address/ACK, never the middle of one block. (A mode-bit word after data
     * words is a peripheral's checksum and stays in the frame.) */
    if ((e->word & MDB_TRACE_MODE_BIT) &&
        (r->cur_words[r->cur_len - 1u] & MDB_TRACE_MODE_BIT))  return true;

    return false;
}

/* Append the open frame to out[*used..cap) as one JSON array element.
 * Returns false, leaving everything untouched, when it does not fit (room is
 * always kept for the closing "]}"). */
static inline bool mdb_trace_emit_frame(const mdb_trace_ring_t *r, uint32_t now_us,
                                        char *out, size_t cap, size_t *used,
                                        unsigned *frames)
{
    /* "," + [age,"d","<3*words>"] + "]}" + NUL: 32 chars of fixed overhead
     * covers the largest age (10 digits) with room to spare. */
    size_t need = 32u + (size_t) r->cur_len * 3u;
    if (*used + need > cap) return false;

    /* The producer can stamp a word a hair after the consumer sampled `now`:
     * treat that as "just now", never as a 71-minute-old frame. */
    int32_t age_us = (int32_t)(now_us - r->cur_first_us);
    uint32_t age_ms = age_us > 0 ? (uint32_t) age_us / 1000u : 0u;

    char *p = out + *used;
    int n = snprintf(p, cap - *used, "%s[%lu,\"%c\",\"",
                     *frames ? "," : "", (unsigned long) age_ms,
                     r->cur_dir == MDB_TRACE_TX ? 't' : 'r');
    if (n < 0 || (size_t) n >= cap - *used) return false;
    p += n;

    for (uint8_t i = 0; i < r->cur_len; i++) {
        n = snprintf(p, cap - (size_t)(p - out), "%03X", (unsigned) r->cur_words[i]);
        if (n != 3) return false;
        p += 3;
    }

    n = snprintf(p, cap - (size_t)(p - out), "\"]");
    if (n != 2) return false;
    p += 2;

    *used = (size_t)(p - out);
    (*frames)++;
    return true;
}

/* Consumer. Turns the pending words into one JSON batch in out[0..cap).
 *
 * Returns the batch length (without NUL), or 0 when there is nothing worth
 * publishing yet. When the buffer fills up the remaining words stay in the
 * ring for the next call. A frame still open at the end is only flushed once
 * it has been idle for longer than the frame gap, so a block is never split
 * across two batches. `now_us` is the same µs clock the producer stamps with.
 *
 * While capture is off this just discards whatever is pending, so a later
 * start never replays stale words. */
static inline size_t mdb_trace_drain_json(mdb_trace_ring_t *r, uint32_t now_us,
                                          char *out, size_t cap)
{
    if (!mdb_trace_is_active(r)) {
        atomic_store_explicit(&r->tail,
            atomic_load_explicit(&r->head, memory_order_acquire),
            memory_order_release);
        atomic_store_explicit(&r->dropped, 0, memory_order_relaxed);
        r->cur_len = 0;
        return 0;
    }

    uint32_t drop = atomic_load_explicit(&r->dropped, memory_order_relaxed);

    int n = snprintf(out, cap, "{\"drop\":%lu,\"f\":[", (unsigned long) drop);
    if (n < 0 || (size_t) n >= cap) return 0;

    size_t   used   = (size_t) n;
    unsigned frames = 0;

    for (;;) {
        uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
        uint32_t head = atomic_load_explicit(&r->head, memory_order_acquire);
        if (tail == head) break;

        const mdb_trace_entry_t *e = &r->entries[tail & (MDB_TRACE_RING_SIZE - 1u)];

        if (r->cur_len && mdb_trace_breaks_frame(r, e)) {
            if (!mdb_trace_emit_frame(r, now_us, out, cap, &used, &frames))
                goto close;                 /* full: keep `e` for next time */
            r->cur_len = 0;
        }

        if (r->cur_len == 0) {
            r->cur_dir      = e->dir;
            r->cur_first_us = e->t_us;
        }
        r->cur_words[r->cur_len++] = e->word;
        r->cur_last_us = e->t_us;

        atomic_store_explicit(&r->tail, tail + 1u, memory_order_release);
    }

    /* Ring empty: flush the open frame once it is certainly complete. */
    if (r->cur_len && (int32_t)(now_us - r->cur_last_us) > (int32_t) MDB_TRACE_FRAME_GAP_US) {
        if (mdb_trace_emit_frame(r, now_us, out, cap, &used, &frames))
            r->cur_len = 0;
    }

close:
    if (frames == 0) return 0;

    atomic_fetch_sub_explicit(&r->dropped, drop, memory_order_relaxed);

    out[used++] = ']';
    out[used++] = '}';
    out[used]   = '\0';
    return used;
}

#endif /* MDB_TRACE_H */
