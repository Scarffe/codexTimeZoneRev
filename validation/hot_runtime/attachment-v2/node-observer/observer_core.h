#pragma once
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <array>
#include <atomic>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <system_error>
constexpr char kMethod[] = "account/chatgptAuthTokens/refresh";
constexpr std::size_t kChunkLimit = 4096, kLineLimit = 4096, kIdLimit = 64;
enum class Method : unsigned { Refresh = 1 };
enum class IdKind : unsigned { Number = 1, String = 2 };
struct Event {
  Method method = Method::Refresh;
  IdKind kind = IdKind::Number;
  std::int64_t number = 0;
  unsigned length = 0;
  char text[kIdLimit]{};
};

struct Shared {
  unsigned magic, version, bytes, brokerPid, nodePid, childPid;
  std::uint64_t readerHandle;
  char nonce[40];
  volatile LONG state, enabled, head, tail, drops, lines, rejects, duplicateRejects;
  volatile LONG immediate, pending, gor, gorAborted, zeroReads, apiInvariant;
  volatile LONG coalesced, fragmented, iatRestored, protectionRestored;
  Event events[16];
};
static_assert(sizeof(void*) == 8 && sizeof(Event) == 88 && offsetof(Shared, events) == 144 && sizeof(Shared) == 1552, "x64 IPC layout");
struct Queue {
  Shared* shared = nullptr;
  bool push(const Event& event) {
    const LONG h = InterlockedCompareExchange(&shared->head, 0, 0);
    const LONG t = InterlockedCompareExchange(&shared->tail, 0, 0);
    if (h - t >= 16) return false;
    shared->events[static_cast<unsigned>(h) % 16] = event;
    InterlockedExchange(&shared->head, h + 1);
    return true;
  }
};
// A bounded, allocation-free JSON parser. Unknown values are traversed with no output.
// Only root keys, root method, and a typed root id have semantic storage.
struct Json {
  const char* p;
  const char* end;
  bool duplicate = false;
  void space() { while (p < end && (*p == ' ' || *p == '\t' || *p == '\r')) ++p; }
  bool take(char c) { space(); if (p < end && *p == c) { ++p; return true; } return false; }
  static int hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  }
  bool string(char* output = nullptr, std::size_t capacity = 0, unsigned* length = nullptr) {
    space();
    if (p == end || *p++ != '"') return false;
    unsigned n = 0;
    while (p < end) {
      unsigned c = static_cast<unsigned char>(*p++);
      if (c == '"') {
        if (output) { if (n >= capacity) return false; output[n] = 0; }
        if (length) *length = n;
        return true;
      }
      if (c < 0x20) return false;
      if (c == '\\') {
        if (p == end) return false;
        const char e = *p++;
        switch (e) {
          case '"': c = '"'; break; case '\\': c = '\\'; break; case '/': c = '/'; break;
          case 'b': c = '\b'; break; case 'f': c = '\f'; break;
          case 'n': c = '\n'; break; case 'r': c = '\r'; break; case 't': c = '\t'; break;
          case 'u': {
            if (end - p < 4) return false;
            c = 0;
            for (int i = 0; i < 4; ++i) { const int h = hex(*p++); if (h < 0) return false; c = c * 16 + static_cast<unsigned>(h); }
            break;
          }
          default: return false;
        }
      }
      // Selected identifiers are ASCII-only in this finite fixture. Other strings are skipped.
      if (output) { if (c == 0 || c > 0x7f || n + 1 >= capacity) return false; output[n++] = static_cast<char>(c); }
    }
    return false;
  }
  bool number(std::int64_t* integer = nullptr) {
    space(); const char* first = p;
    if (p < end && *p == '-') ++p;
    if (p == end) return false;
    if (*p == '0') ++p;
    else { if (*p < '1' || *p > '9') return false; while (p < end && *p >= '0' && *p <= '9') ++p; }
    bool integral = true;
    if (p < end && *p == '.') {
      integral = false; ++p; const char* digits = p;
      while (p < end && *p >= '0' && *p <= '9') ++p;
      if (digits == p) return false;
    }
    if (p < end && (*p == 'e' || *p == 'E')) {
      integral = false; ++p; if (p < end && (*p == '+' || *p == '-')) ++p;
      const char* digits = p; while (p < end && *p >= '0' && *p <= '9') ++p;
      if (digits == p) return false;
    }
    if (integer) {
      if (!integral) return false;
      const auto r = std::from_chars(first, p, *integer);
      if (r.ec != std::errc{} || r.ptr != p) return false;
    }
    return true;
  }
  bool value(unsigned depth = 0) {
    if (depth > 16) return false;
    space(); if (p == end) return false;
    if (*p == '"') return string();
    if (*p == '{') {
      ++p; if (take('}')) return true;
      do { if (!string() || !take(':') || !value(depth + 1)) return false; if (take('}')) return true; } while (take(','));
      return false;
    }
    if (*p == '[') {
      ++p; if (take(']')) return true;
      do { if (!value(depth + 1)) return false; if (take(']')) return true; } while (take(','));
      return false;
    }
    for (const char* literal : {"true", "false", "null"}) {
      const auto n = std::strlen(literal);
      if (static_cast<std::size_t>(end - p) >= n && std::memcmp(p, literal, n) == 0) { p += n; return true; }
    }
    return number();
  }
  bool root(Event& event, bool& refresh) {
    char keys[16][40]{}; unsigned keyCount = 0;
    char method[64]{}; bool hasMethod = false, hasId = false;
    refresh = false;
    if (!take('{')) return false;
    if (!take('}')) {
      do {
        if (keyCount == 16 || !string(keys[keyCount], sizeof keys[0])) return false;
        for (unsigned i = 0; i < keyCount; ++i) if (std::strcmp(keys[i], keys[keyCount]) == 0) { duplicate = true; return false; }
        const char* key = keys[keyCount++];
        if (!take(':')) return false;
        if (std::strcmp(key, "method") == 0) {
          hasMethod = true; if (!string(method, sizeof method)) return false;
        } else if (std::strcmp(key, "id") == 0) {
          hasId = true; space();
          if (p < end && *p == '"') { event.kind = IdKind::String; if (!string(event.text, sizeof event.text, &event.length)) return false; }
          else { event.kind = IdKind::Number; if (!number(&event.number)) return false; }
        } else if (!value()) return false;
        if (take('}')) break;
        if (!take(',')) return false;
      } while (true);
    }
    space(); if (p != end) return false;
    refresh = hasMethod && hasId && std::strcmp(method, kMethod) == 0;
    return true;
  }
};

struct Stats {
  unsigned lines = 0, valid = 0, duplicateRejected = 0, rejected = 0, events = 0, drops = 0;
  unsigned immediate = 0, pending = 0, gorCompleted = 0, submissions = 0;
  bool coalesced = false, fragmented = false, immutable = true, lastErrorPreserved = true, onlyReader = true;
};
struct Parser {
  char line[kLineLimit]{};
  std::size_t length = 0;
  bool discard = false, spans = false;
  void feed(const char* bytes, std::size_t count, Queue& queue, Stats& stats) {
    if (count > kChunkLimit) { discard = true; length = 0; ++stats.drops; return; }
    if (length != 0) spans = true;
    unsigned completed = 0;
    for (std::size_t i = 0; i < count; ++i) {
      if (bytes[i] == '\n') {
        ++stats.lines; ++completed;
        if (!discard) {
          Event event{}; bool refresh = false; Json json{line, line + length};
          if (json.root(event, refresh)) {
            ++stats.valid;
            if (refresh) { if (queue.push(event)) ++stats.events; else ++stats.drops; }
          } else { ++stats.rejected; if (json.duplicate) ++stats.duplicateRejected; }
          if (spans) stats.fragmented = true;
        }
        SecureZeroMemory(line, sizeof line); length = 0; discard = false; spans = false;
      } else if (!discard) {
        if (length == sizeof line) { discard = true; ++stats.drops; SecureZeroMemory(line, sizeof line); length = 0; }
        else line[length++] = bytes[i];
      }
    }
    if (completed > 1) stats.coalesced = true;
  }
};
