#include "doctest.h"
#include "SegmentIndex.h"

static SegmentState absent() { return SegmentState{false, 0, 0}; }
static SegmentState present(uint32_t seq, uint32_t recs) {
    return SegmentState{true, seq, recs};
}

TEST_CASE("SegmentIndex: a fresh index starts empty at segment 0") {
    SegmentIndex idx;
    idx.initialize(8, 4000);
    CHECK(idx.currentSegment() == 0);
    CHECK(idx.recordsInCurrent() == 0);
    CHECK(idx.totalRecords() == 0);
    CHECK(idx.nextSequence() == 1);
    CHECK_FALSE(idx.currentExists());
    CHECK_FALSE(idx.needsRotation());
}

TEST_CASE("SegmentIndex: restoring an all-absent scan behaves like fresh") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    SegmentState states[4] = { absent(), absent(), absent(), absent() };
    idx.restore(states, 4);
    CHECK(idx.currentSegment() == 0);
    CHECK(idx.totalRecords() == 0);
    CHECK(idx.nextSequence() == 1);
    CHECK_FALSE(idx.currentExists());
}

TEST_CASE("SegmentIndex: the highest sequence becomes current") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    // Sequence, not position, decides. Segment 1 is newest here.
    SegmentState states[4] = {
        present(7, 100), present(9, 42), present(8, 100), absent()
    };
    idx.restore(states, 4);
    CHECK(idx.currentSegment() == 1);
    CHECK(idx.currentExists());
    CHECK(idx.recordsInCurrent() == 42);
    CHECK(idx.nextSequence() == 10);
}

TEST_CASE("SegmentIndex: total records sums every present segment") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    SegmentState states[4] = {
        present(1, 100), present(2, 100), present(3, 25), absent()
    };
    idx.restore(states, 4);
    CHECK(idx.totalRecords() == 225);
}

TEST_CASE("SegmentIndex: rotation is needed only when the segment is full") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    SegmentState states[4] = { present(1, 99), absent(), absent(), absent() };
    idx.restore(states, 4);
    CHECK_FALSE(idx.needsRotation());
    idx.recordAppended();
    CHECK(idx.recordsInCurrent() == 100);
    CHECK(idx.needsRotation());
}

TEST_CASE("SegmentIndex: appending advances both counters") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    SegmentState states[4] = { present(1, 10), present(2, 5), absent(), absent() };
    idx.restore(states, 4);
    CHECK(idx.totalRecords() == 15);
    idx.recordAppended();
    CHECK(idx.recordsInCurrent() == 6);
    CHECK(idx.totalRecords() == 16);
}

TEST_CASE("SegmentIndex: rotation prefers an absent segment") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    SegmentState states[4] = {
        present(1, 100), present(2, 100), absent(), present(3, 100)
    };
    idx.restore(states, 4);
    CHECK(idx.currentSegment() == 3);
    CHECK(idx.rotate() == 2);          // the empty slot, not the oldest
    CHECK(idx.currentSegment() == 2);
    CHECK(idx.currentExists());
    CHECK(idx.recordsInCurrent() == 0);
}

TEST_CASE("SegmentIndex: rotation evicts the lowest sequence when all are present") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    SegmentState states[4] = {
        present(9, 100), present(6, 100), present(8, 100), present(7, 100)
    };
    idx.restore(states, 4);
    CHECK(idx.currentSegment() == 0);   // sequence 9 is newest
    CHECK(idx.rotate() == 1);           // sequence 6 is oldest
    CHECK(idx.currentSegment() == 1);
}

TEST_CASE("SegmentIndex: evicting a full segment drops its records from the total") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    SegmentState states[4] = {
        present(9, 100), present(6, 100), present(8, 100), present(7, 100)
    };
    idx.restore(states, 4);
    CHECK(idx.totalRecords() == 400);
    idx.rotate();                       // evicts sequence 6, holding 100
    CHECK(idx.totalRecords() == 300);
}

TEST_CASE("SegmentIndex: each rotation stamps the next sequence") {
    SegmentIndex idx;
    idx.initialize(4, 100);
    SegmentState states[4] = { present(5, 100), absent(), absent(), absent() };
    idx.restore(states, 4);
    CHECK(idx.nextSequence() == 6);
    idx.rotate();
    CHECK(idx.currentSequence() == 6);
    CHECK(idx.nextSequence() == 7);
    idx.rotate();
    CHECK(idx.currentSequence() == 7);
    CHECK(idx.nextSequence() == 8);
}

TEST_CASE("SegmentIndex: rotating from a fresh index creates segment 0") {
    SegmentIndex idx;
    idx.initialize(8, 4000);
    CHECK_FALSE(idx.currentExists());
    CHECK(idx.rotate() == 0);
    CHECK(idx.currentSegment() == 0);
    CHECK(idx.currentExists());
    CHECK(idx.currentSequence() == 1);
    CHECK(idx.nextSequence() == 2);
}
