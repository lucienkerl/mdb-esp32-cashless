/*
 * Host test for main/mdb_trace.h — the real header, not a copy.
 *
 * Covers what the field depends on: words come out in order, grouped into the
 * frames an operator expects (VMC command / our reply), a batch never splits a
 * frame, nothing is captured while the trace is off, and a full ring drops
 * words and says so instead of blocking the MDB task.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "mdb_trace.h"

static mdb_trace_ring_t ring;   /* ~8 KB: keep it off the stack */

static void reset(bool active)
{
    memset(&ring, 0, sizeof ring);
    mdb_trace_set_active(&ring, active);
}

static void push(uint16_t w, mdb_trace_dir_t d, uint32_t t_us)
{
    mdb_trace_push(&ring, w, d, t_us);
}

static void expect(const char *got, const char *want)
{
    if (strcmp(got, want) != 0) {
        printf("expected: %s\n     got: %s\n", want, got);
        assert(!"batch mismatch");
    }
}

int main(void)
{
    char out[2048];

    /* --- a POLL and our JUST RESET reply -------------------------------- */
    reset(true);
    /* VMC: address 0x12 (cashless #1 + POLL) with mode bit, then checksum. */
    push(0x112, MDB_TRACE_RX, 1000);
    push(0x012, MDB_TRACE_RX, 2150);
    /* Us: 0x00 JUST RESET + checksum word (mode bit set). */
    push(0x000, MDB_TRACE_TX, 4000);
    push(0x100, MDB_TRACE_TX, 4000);

    /* Too early: the last frame might still be growing. */
    assert(mdb_trace_drain_json(&ring, 4500, out, sizeof out) > 0);
    expect(out, "{\"drop\":0,\"f\":[[3,\"r\",\"112012\"]]}");

    /* Once it has been idle past the gap it is flushed, and only once. */
    assert(mdb_trace_drain_json(&ring, 9000, out, sizeof out) > 0);
    expect(out, "{\"drop\":0,\"f\":[[5,\"t\",\"000100\"]]}");
    assert(mdb_trace_drain_json(&ring, 20000, out, sizeof out) == 0);

    /* --- an idle gap splits two frames of the same direction ------------ */
    reset(true);
    push(0x112, MDB_TRACE_RX, 0);
    push(0x012, MDB_TRACE_RX, 1200);
    push(0x112, MDB_TRACE_RX, 100000);   /* next poll, 100 ms later */
    push(0x012, MDB_TRACE_RX, 101200);
    assert(mdb_trace_drain_json(&ring, 110000, out, sizeof out) > 0);
    expect(out, "{\"drop\":0,\"f\":[[110,\"r\",\"112012\"],[10,\"r\",\"112012\"]]}");

    /* --- a word stamped after the consumer's clock sample --------------- */
    reset(true);
    push(0x112, MDB_TRACE_RX, 5000);          /* "now" below is 4000: 1 ms behind */
    assert(mdb_trace_drain_json(&ring, 4000, out, sizeof out) == 0);   /* not flushed */
    assert(mdb_trace_drain_json(&ring, 20000, out, sizeof out) > 0);
    expect(out, "{\"drop\":0,\"f\":[[15,\"r\",\"112\"]]}");
    reset(true);
    push(0x112, MDB_TRACE_RX, 5000);
    push(0x112, MDB_TRACE_RX, 5000 + 100000u);
    assert(mdb_trace_drain_json(&ring, 4000, out, sizeof out) > 0);    /* first frame: age clamps to 0 */
    expect(out, "{\"drop\":0,\"f\":[[0,\"r\",\"112\"]]}");

    /* --- another peripheral's checksum (mode bit) stays in the frame ----- */
    reset(true);
    push(0x108, MDB_TRACE_RX, 0);      /* VMC -> coin changer */
    push(0x008, MDB_TRACE_RX, 1200);
    push(0x100, MDB_TRACE_RX, 3500);   /* its ACK/checksum, mode bit set */
    assert(mdb_trace_drain_json(&ring, 50000, out, sizeof out) > 0);
    expect(out, "{\"drop\":0,\"f\":[[50,\"r\",\"108008100\"]]}");

    /* --- two mode-bit words in a row are two frames --------------------- */
    reset(true);
    push(0x100, MDB_TRACE_RX, 0);      /* ACK */
    push(0x112, MDB_TRACE_RX, 1200);   /* next address right behind it */
    push(0x012, MDB_TRACE_RX, 2400);
    assert(mdb_trace_drain_json(&ring, 50000, out, sizeof out) > 0);
    expect(out, "{\"drop\":0,\"f\":[[50,\"r\",\"100\"],[48,\"r\",\"112012\"]]}");

    /* --- the 9-bit word is masked, nothing above bit 8 leaks ------------ */
    reset(true);
    push(0xFFFF, MDB_TRACE_RX, 0);
    assert(mdb_trace_drain_json(&ring, 50000, out, sizeof out) > 0);
    expect(out, "{\"drop\":0,\"f\":[[50,\"r\",\"1FF\"]]}");

    /* --- nothing is captured while the trace is off --------------------- */
    reset(false);
    push(0x112, MDB_TRACE_RX, 0);
    push(0x012, MDB_TRACE_RX, 1200);
    mdb_trace_set_active(&ring, true);
    assert(mdb_trace_drain_json(&ring, 50000, out, sizeof out) == 0);

    /* Stopping discards what was still pending: a restart never replays it. */
    push(0x112, MDB_TRACE_RX, 60000);
    mdb_trace_set_active(&ring, false);
    assert(mdb_trace_drain_json(&ring, 70000, out, sizeof out) == 0);
    mdb_trace_set_active(&ring, true);
    assert(mdb_trace_drain_json(&ring, 80000, out, sizeof out) == 0);

    /* --- a full ring drops and counts, the producer never blocks -------- */
    reset(true);
    for (uint32_t i = 0; i < MDB_TRACE_RING_SIZE + 10; i++)
        push(0x012, MDB_TRACE_RX, i * 5000u);   /* 5 ms apart: one frame each */
    assert(atomic_load(&ring.dropped) == 10);

    size_t total_frames = 0;
    int first = 1;
    for (int rounds = 0; rounds < 1000; rounds++) {
        size_t n = mdb_trace_drain_json(&ring, (MDB_TRACE_RING_SIZE + 10u) * 5000u + 100000u,
                                        out, sizeof out);
        if (n == 0) break;
        assert(n < sizeof out);
        assert(out[n - 1] == '}' && out[n - 2] == ']');
        if (first) {
            assert(strncmp(out, "{\"drop\":10,", 11) == 0);   /* reported once */
            first = 0;
        } else {
            assert(strncmp(out, "{\"drop\":0,", 10) == 0);
        }
        for (const char *p = out; (p = strstr(p, "\"r\"")) != NULL; p++) total_frames++;
    }
    assert(total_frames == MDB_TRACE_RING_SIZE);   /* nothing lost but the 10 */
    assert(atomic_load(&ring.dropped) == 0);

    /* --- a small buffer makes batches, never a torn frame --------------- */
    reset(true);
    for (uint32_t i = 0; i < 40; i++) {
        push(0x112, MDB_TRACE_RX, i * 10000u);
        push(0x012, MDB_TRACE_RX, i * 10000u + 1200u);
    }
    char small[128];
    size_t frames_seen = 0;
    for (int rounds = 0; rounds < 100; rounds++) {
        size_t n = mdb_trace_drain_json(&ring, 1000000u, small, sizeof small);
        if (n == 0) break;
        assert(n < sizeof small);
        assert(small[n - 1] == '}');
        for (const char *p = small; (p = strstr(p, "\"112012\"")) != NULL; p++) frames_seen++;
    }
    assert(frames_seen == 40);

    /* --- a block longer than the frame cap is split, not overrun -------- */
    reset(true);
    for (uint32_t i = 0; i < MDB_TRACE_MAX_WORDS + 4; i++)
        push(i == 0 ? 0x110 : 0x001, MDB_TRACE_RX, i * 1200u);
    assert(mdb_trace_drain_json(&ring, 500000, out, sizeof out) > 0);
    assert(strstr(out, "],[") != NULL);    /* two frames */

    puts("mdb_trace: ok");
    return 0;
}
