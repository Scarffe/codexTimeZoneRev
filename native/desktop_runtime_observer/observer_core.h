#pragma once
#include "observer_api.h"
#include <charconv>
#include <cstring>
#include <system_error>

constexpr char kMethod[] = "account/chatgptAuthTokens/refresh";
constexpr std::size_t kIdLimit = 64;
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
  char nonce[40];  // Legacy IPC field: explicit owner generation in hex, not an environment token.
  volatile LONG state, enabled, head, tail, drops, lines, rejects, duplicateRejects;
  volatile LONG immediate, pending, gor, gorAborted, zeroReads, apiInvariant;
  volatile LONG coalesced, fragmented, iatRestored, protectionRestored;
  Event events[16];
};
static_assert(sizeof(Event) == 88 && offsetof(Shared, events) == 144 && sizeof(Shared) == 1552, "x64 IPC layout");
struct Queue {
  Shared* shared = nullptr;
  bool push(const Event& event) {
    const LONG h = InterlockedCompareExchange(&shared->head, 0, 0);
    const LONG t = InterlockedCompareExchange(&shared->tail, 0, 0);
    if (h - t >= 16) return false;
    shared->events[static_cast<unsigned>(h) % 16] = event;
    InterlockedExchange(&shared->head, h + 1); return true;
  }
};
struct Stats {
  unsigned lines = 0, valid = 0, duplicateRejected = 0, rejected = 0, events = 0, drops = 0;
  unsigned immediate = 0, pending = 0, gorCompleted = 0;
  bool coalesced = false, fragmented = false, immutable = true;
};

// Constant storage independent of chunk/frame/string length. Unknown values have no output.
// This projects normal JSONL traffic; selected root identifiers are conservative ASCII.
struct Parser {
  enum class Mode : unsigned char { None, String, Number, Literal };
  enum class Capture : unsigned char { None, RootKey, MethodValue, IdString, IdNumber };
  enum class Field : unsigned char { Other, Method, Id };
  enum class State : unsigned char { KeyOrEnd, KeyOnly, Colon, Value, CommaOrEnd, ArrayValueOrEnd, ArrayValueOnly, ArrayCommaOrEnd };
  struct Context { bool object; State state; Field field; } stack[32]{};
  unsigned depth = 0;
  Mode mode = Mode::None;
  Capture capture = Capture::None;
  bool started = false, done = false, invalid = false, duplicate = false, spans = false;
  bool keyString = false, escape = false, methodMatches = false, typedId = false;
  unsigned unicodeLeft = 0, unicodeValue = 0, tokenLength = 0, keyCount = 0;
  char token[64]{}, keys[16][64]{};
  unsigned numberState = 0, literalAt = 0, literalLength = 0;
  bool numberIntegral = true;
  const char* literal = nullptr;
  Event projected{};

  static bool whitespace(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
  static int hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  }
  void append(unsigned c) {
    if (capture == Capture::None) return;
    if (c == 0 || c > 127 || tokenLength + 1 >= sizeof token) { invalid = true; return; }
    token[tokenLength++] = static_cast<char>(c);
  }
  void valueDone() {
    if (!depth) { invalid = true; return; }
    auto& current = stack[depth - 1];
    if (current.object && current.state == State::Value) current.state = State::CommaOrEnd;
    else if (!current.object && (current.state == State::ArrayValueOrEnd || current.state == State::ArrayValueOnly)) current.state = State::ArrayCommaOrEnd;
    else invalid = true;
  }
  void close() {
    if (!depth) { invalid = true; return; }
    --depth;
    if (!depth) done = true; else valueDone();
  }
  void push(bool object) {
    if (depth == 32) { invalid = true; return; }
    stack[depth++] = {object, object ? State::KeyOrEnd : State::ArrayValueOrEnd, Field::Other};
  }
  void startString(bool key, Capture selected) {
    mode = Mode::String; capture = selected; keyString = key;
    tokenLength = 0; escape = false; unicodeLeft = 0; unicodeValue = 0;
  }
  void stringDone() {
    token[tokenLength] = 0;
    if (keyString) {
      if (depth == 1) {
        if (keyCount == 16) { invalid = true; return; }
        for (unsigned i = 0; i < keyCount; ++i) if (!std::strcmp(keys[i], token)) { duplicate = true; invalid = true; return; }
        std::memcpy(keys[keyCount++], token, tokenLength + 1);
        stack[0].field = !std::strcmp(token, "method") ? Field::Method : !std::strcmp(token, "id") ? Field::Id : Field::Other;
      }
      stack[depth - 1].state = State::Colon;
    } else {
      if (capture == Capture::MethodValue) methodMatches = tokenLength == sizeof(kMethod) - 1 && !std::memcmp(token, kMethod, tokenLength);
      else if (capture == Capture::IdString) {
        projected.kind = IdKind::String; projected.length = tokenLength;
        std::memcpy(projected.text, token, tokenLength + 1); typedId = true;
      }
      valueDone();
    }
    mode = Mode::None; capture = Capture::None;
    SecureZeroMemory(token, sizeof token); tokenLength = 0;
  }
  void stringByte(char c) {
    if (unicodeLeft) {
      const int h = hex(c); if (h < 0) { invalid = true; return; }
      unicodeValue = unicodeValue * 16 + static_cast<unsigned>(h);
      if (!--unicodeLeft) append(unicodeValue);
      return;
    }
    if (escape) {
      escape = false;
      switch (c) {
        case 'u': unicodeLeft = 4; unicodeValue = 0; return;
        case '"': append('"'); return; case '\\': append('\\'); return; case '/': append('/'); return;
        case 'b': append('\b'); return; case 'f': append('\f'); return;
        case 'n': append('\n'); return; case 'r': append('\r'); return; case 't': append('\t'); return;
        default: invalid = true; return;
      }
    }
    const auto byte = static_cast<unsigned char>(c);
    if (c == '\\') escape = true;
    else if (c == '"') stringDone();
    else if (byte < 32) invalid = true;
    else append(byte);
  }
  bool numberByte(char c) {
    const bool digit = c >= '0' && c <= '9';
    switch (numberState) {
      case 1: if (!digit) { invalid = true; return true; } numberState = c == '0' ? 2u : 3u; break;
      case 2: if (c == '.') { numberState = 4; numberIntegral = false; } else if (c == 'e' || c == 'E') { numberState = 6; numberIntegral = false; } else return false; break;
      case 3: if (digit) {} else if (c == '.') { numberState = 4; numberIntegral = false; } else if (c == 'e' || c == 'E') { numberState = 6; numberIntegral = false; } else return false; break;
      case 4: if (!digit) { invalid = true; return true; } numberState = 5; break;
      case 5: if (digit) {} else if (c == 'e' || c == 'E') { numberState = 6; numberIntegral = false; } else return false; break;
      case 6: if (c == '+' || c == '-') numberState = 7; else if (digit) numberState = 8; else invalid = true; break;
      case 7: if (!digit) invalid = true; else numberState = 8; break;
      case 8: if (!digit) return false; break;
      default: invalid = true; break;
    }
    append(static_cast<unsigned char>(c)); return true;
  }
  void numberDone() {
    if (numberState != 2 && numberState != 3 && numberState != 5 && numberState != 8) { invalid = true; return; }
    if (capture == Capture::IdNumber && numberIntegral) {
      const auto parsed = std::from_chars(token, token + tokenLength, projected.number);
      if (parsed.ec == std::errc{} && parsed.ptr == token + tokenLength) { projected.kind = IdKind::Number; typedId = true; }
    }
    mode = Mode::None; capture = Capture::None;
    SecureZeroMemory(token, sizeof token); tokenLength = 0; valueDone();
  }
  void startValue(char c) {
    const Field field = depth == 1 && stack[0].object ? stack[0].field : Field::Other;
    if (c == '"') { startString(false, field == Field::Method ? Capture::MethodValue : field == Field::Id ? Capture::IdString : Capture::None); return; }
    if (c == '{') { push(true); return; }
    if (c == '[') { push(false); return; }
    if (c == '-' || (c >= '0' && c <= '9')) {
      mode = Mode::Number; capture = field == Field::Id ? Capture::IdNumber : Capture::None;
      tokenLength = 0; numberIntegral = true; numberState = c == '-' ? 1u : c == '0' ? 2u : 3u; append(static_cast<unsigned char>(c)); return;
    }
    literal = c == 't' ? "true" : c == 'f' ? "false" : c == 'n' ? "null" : nullptr;
    if (!literal) { invalid = true; return; }
    mode = Mode::Literal; literalAt = 1; literalLength = static_cast<unsigned>(std::strlen(literal)); capture = Capture::None;
  }
  void byte(char c) {
    if (invalid) return;
    if (mode == Mode::String) { stringByte(c); return; }
    if (mode == Mode::Literal) {
      if (c != literal[literalAt++]) { invalid = true; return; }
      if (literalAt == literalLength) { mode = Mode::None; valueDone(); }
      return;
    }
    if (mode == Mode::Number) { if (numberByte(c)) return; numberDone(); if (invalid) return; }
    if (whitespace(c)) return;
    if (done) { invalid = true; return; }
    if (!started) { if (c != '{') { invalid = true; return; } started = true; push(true); return; }
    if (!depth) { invalid = true; return; }
    auto& current = stack[depth - 1];
    switch (current.state) {
      case State::KeyOrEnd: if (c == '}') { close(); return; } [[fallthrough]];
      case State::KeyOnly: if (c == '"') startString(true, depth == 1 ? Capture::RootKey : Capture::None); else invalid = true; return;
      case State::Colon: if (c == ':') current.state = State::Value; else invalid = true; return;
      case State::Value: startValue(c); return;
      case State::CommaOrEnd: if (c == '}') close(); else if (c == ',') current.state = State::KeyOnly; else invalid = true; return;
      case State::ArrayValueOrEnd: if (c == ']') { close(); return; } [[fallthrough]];
      case State::ArrayValueOnly: startValue(c); return;
      case State::ArrayCommaOrEnd: if (c == ']') close(); else if (c == ',') current.state = State::ArrayValueOnly; else invalid = true; return;
    }
  }
  void feed(const char* input, std::size_t count, Queue& queue, Stats& stats) {
    if (started || mode != Mode::None) spans = true;
    unsigned completed = 0;
    for (std::size_t i = 0; i < count; ++i) {
      const char c = input[i];
      if (c != '\n') { byte(c); continue; }
      byte(c);
      ++stats.lines; ++completed;
      if (!invalid && started && done && depth == 0 && mode == Mode::None) {
        ++stats.valid;
        if (methodMatches && typedId) { if (queue.push(projected)) ++stats.events; else ++stats.drops; }
      } else { ++stats.rejected; if (duplicate) ++stats.duplicateRejected; }
      if (spans) stats.fragmented = true;
      *this = Parser{};  // Only fixed grammar/key/id storage is reset; no frame buffer exists.
    }
    if (completed > 1) stats.coalesced = true;
  }
};
static_assert(sizeof(Parser) < 2048, "projection storage is constant and bounded");
