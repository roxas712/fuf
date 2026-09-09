#include "doctest.h"
#include "DeviceTable.h"

static void setMACIndex(uint8_t* dst, uint16_t index) {
    dst[0] = 0xB4; dst[1] = 0x1E; dst[2] = 0x52; dst[3] = 0x00;
    dst[4] = (uint8_t)(index >> 8);
    dst[5] = (uint8_t)(index & 0xFF);
}

TEST_CASE("DeviceTable: a new MAC is reported as new exactly once") {
    DeviceTable table;
    table.initialize();
    uint8_t mac[6];
    setMACIndex(mac, 1);
    CHECK(table.observe(mac));
    CHECK_FALSE(table.observe(mac));
    CHECK_FALSE(table.observe(mac));
}

TEST_CASE("DeviceTable: distinct MACs are each new") {
    DeviceTable table;
    table.initialize();
    uint8_t a[6], b[6];
    setMACIndex(a, 1);
    setMACIndex(b, 2);
    CHECK(table.observe(a));
    CHECK(table.observe(b));
    CHECK(table.size() == 2);
}

TEST_CASE("DeviceTable: size starts at zero") {
    DeviceTable table;
    table.initialize();
    CHECK(table.size() == 0);
    CHECK_FALSE(table.atCapacity());
}

TEST_CASE("DeviceTable: stops reporting new MACs at capacity") {
    DeviceTable table;
    table.initialize();
    for (uint16_t i = 0; i < DeviceTable::CAPACITY; i++) {
        uint8_t mac[6];
        setMACIndex(mac, i);
        CHECK(table.observe(mac));
    }
    CHECK(table.atCapacity());

    uint8_t overflow[6];
    setMACIndex(overflow, DeviceTable::CAPACITY + 1);
    // Full: identity cannot be recorded, so do not claim it is new.
    CHECK_FALSE(table.observe(overflow));
    CHECK(table.size() == DeviceTable::CAPACITY);
}

TEST_CASE("DeviceTable: known MACs still resolve when full") {
    DeviceTable table;
    table.initialize();
    for (uint16_t i = 0; i < DeviceTable::CAPACITY; i++) {
        uint8_t mac[6];
        setMACIndex(mac, i);
        table.observe(mac);
    }
    uint8_t known[6];
    setMACIndex(known, 0);
    CHECK_FALSE(table.observe(known));
}

TEST_CASE("DeviceTable: lookup works below capacity, independent of the full guard") {
    // The `used >= CAPACITY` early return masks the matching loop once the
    // table is full, so the "known MACs when full" test cannot tell a working
    // lookup from a broken one. This case stays well below capacity, so only
    // the matching loop can decide the outcome.
    DeviceTable table;
    table.initialize();

    uint8_t a[6];
    setMACIndex(a, 1);
    CHECK(table.observe(a));

    for (uint16_t i = 10; i < 20; i++) {
        uint8_t other[6];
        setMACIndex(other, i);
        CHECK(table.observe(other));
    }

    // Still remembered after ten intervening inserts.
    CHECK_FALSE(table.observe(a));

    // A genuinely new MAC is still admitted.
    uint8_t c[6];
    setMACIndex(c, 99);
    CHECK(table.observe(c));

    CHECK(table.size() == 12);
}

// A MAC is marked observed *before* its identifier is written to flash. If that
// write fails the entry must be rolled back, otherwise observe() returns false
// for the rest of the run and the identifier is lost permanently -- the device
// is remembered as recorded while nothing was ever persisted.
TEST_CASE("DeviceTable: forgetLast undoes the most recent observe") {
    DeviceTable table;
    table.initialize();
    uint8_t a[6], b[6];
    setMACIndex(a, 1);
    setMACIndex(b, 2);

    CHECK(table.observe(a));
    CHECK(table.observe(b));
    CHECK(table.size() == 2);

    table.forgetLast();                 // pretend b's write failed
    CHECK(table.size() == 1);
    CHECK(table.observe(b));            // retried on the next sighting
    CHECK(table.size() == 2);
    CHECK_FALSE(table.observe(a));      // a is untouched
}

TEST_CASE("DeviceTable: forgetLast on an empty table is harmless") {
    DeviceTable table;
    table.initialize();
    table.forgetLast();
    CHECK(table.size() == 0);
    uint8_t a[6];
    setMACIndex(a, 1);
    CHECK(table.observe(a));
}
