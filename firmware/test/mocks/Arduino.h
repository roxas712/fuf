// Minimal Arduino.h mock for host-side unit tests.
// Provides only what the testable production headers actually use.
#ifndef ARDUINO_H_MOCK
#define ARDUINO_H_MOCK

#include <stdint.h>
#include <stddef.h>
#include <climits>
#include <cstdio>
#include <cstring>
#include <functional>

// On Linux, strcasestr needs _GNU_SOURCE (already available on macOS).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <strings.h>

// constrain macro (matches Arduino)
#ifndef constrain
#define constrain(x, low, high) \
    ((x) < (low) ? (low) : ((x) > (high) ? (high) : (x)))
#endif

// Test-controllable millis() — defined in eventbus_impl.cpp
extern uint32_t mock_millis_value;
inline uint32_t millis() { return mock_millis_value; }

// Minimal Serial stand-in so code in common/ can log without #ifdef guards.
// Silent by default -- set mock_serial_echo to see the output in a test run.
#include <cstdio>
#include <cstdarg>
extern bool mock_serial_echo;
struct MockSerial {
    void printf(const char* fmt, ...) {
        if (!mock_serial_echo) return;
        va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    }
    void println(const char* s = "") { if (mock_serial_echo) ::printf("%s\n", s); }
    void print(const char* s)        { if (mock_serial_echo) ::printf("%s", s); }
};
extern MockSerial Serial;

#endif // ARDUINO_H_MOCK
