#include "doctest.h"
#include "RateLimiter.h"

static void setMAC(uint8_t* dst, uint8_t last) {
    dst[0] = 0xB4; dst[1] = 0x1E; dst[2] = 0x52;
    dst[3] = 0x00; dst[4] = 0x00; dst[5] = last;
}

TEST_CASE("RateLimiter: first sighting of a MAC is always allowed") {
    RateLimiter limiter;
    limiter.initialize(100);
    uint8_t mac[6];
    setMAC(mac, 1);
    CHECK(limiter.allow(mac, 1000));
}

TEST_CASE("RateLimiter: a burst inside the interval is suppressed") {
    RateLimiter limiter;
    limiter.initialize(100);
    uint8_t mac[6];
    setMAC(mac, 1);
    CHECK(limiter.allow(mac, 1000));
    CHECK_FALSE(limiter.allow(mac, 1050));
    CHECK_FALSE(limiter.allow(mac, 1099));
}

TEST_CASE("RateLimiter: allowed again once the interval elapses") {
    RateLimiter limiter;
    limiter.initialize(100);
    uint8_t mac[6];
    setMAC(mac, 1);
    CHECK(limiter.allow(mac, 1000));
    CHECK(limiter.allow(mac, 1100));
    CHECK_FALSE(limiter.allow(mac, 1150));
    CHECK(limiter.allow(mac, 1200));
}

TEST_CASE("RateLimiter: limits are per-MAC, not global") {
    RateLimiter limiter;
    limiter.initialize(100);
    uint8_t a[6], b[6];
    setMAC(a, 1);
    setMAC(b, 2);
    CHECK(limiter.allow(a, 1000));
    CHECK(limiter.allow(b, 1000));      // different device, not throttled
    CHECK_FALSE(limiter.allow(a, 1010));
}

TEST_CASE("RateLimiter: more MACs than slots still admits new devices") {
    RateLimiter limiter;
    limiter.initialize(100);
    for (uint8_t i = 0; i < RateLimiter::SLOTS + 8; i++) {
        uint8_t mac[6];
        setMAC(mac, i);
        CHECK(limiter.allow(mac, 1000 + i));
    }
}

TEST_CASE("RateLimiter: a zero interval never suppresses") {
    RateLimiter limiter;
    limiter.initialize(0);
    uint8_t mac[6];
    setMAC(mac, 1);
    CHECK(limiter.allow(mac, 1000));
    CHECK(limiter.allow(mac, 1000));
}

TEST_CASE("RateLimiter: interval math survives the millis() rollover") {
    // Mutation-tested: rewriting the check as `nowMs < lastMs + minInterval`
    // passes every other test in this file but fails here.
    RateLimiter limiter;
    limiter.initialize(1000);
    uint8_t mac[6];
    setMAC(mac, 1);

    CHECK(limiter.allow(mac, 0xFFFFFF00));          // last seen just before wrap
    CHECK_FALSE(limiter.allow(mac, 0xFFFFFFF0));    // +240ms, still inside
    CHECK_FALSE(limiter.allow(mac, 0x00000200));    // +768ms across wrap, inside
    CHECK(limiter.allow(mac, 0x00000400));          // +1280ms, outside
}

TEST_CASE("RateLimiter: eviction removes the least-recently-seen device") {
    // Mutation-tested: replacing LRU with "always evict slot 0" passes every
    // other test in this file but fails here, because `keep` occupies slot 0.
    RateLimiter limiter;
    limiter.initialize(100);

    uint8_t keep[6], idle[6];
    setMAC(keep, 200);
    setMAC(idle, 201);

    CHECK(limiter.allow(keep, 1000));   // slot 0
    CHECK(limiter.allow(idle, 1001));   // slot 1

    for (uint8_t i = 0; i < RateLimiter::SLOTS - 2; i++) {
        uint8_t mac[6];
        setMAC(mac, i);
        CHECK(limiter.allow(mac, 1002 + i));
    }

    // Refresh `keep` so it becomes the most recently seen entry.
    uint32_t refreshAt = 1002 + (RateLimiter::SLOTS - 2) + 200;
    CHECK(limiter.allow(keep, refreshAt));

    // A new MAC now forces an eviction. LRU must drop `idle`, not `keep`.
    uint8_t intruder[6];
    setMAC(intruder, 202);
    CHECK(limiter.allow(intruder, refreshAt + 1));

    // `keep` survived, so it is still rate-limited rather than looking new.
    CHECK_FALSE(limiter.allow(keep, refreshAt + 2));
}
