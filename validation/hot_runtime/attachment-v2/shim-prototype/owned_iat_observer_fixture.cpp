#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>

// Owned executable only. No DLL, remote process, process discovery, or credentials.
static_assert(sizeof(void*) == 8 && sizeof(HANDLE) == sizeof(std::uintptr_t), "Build x64");
constexpr char kMethod[] = "account/chatgptAuthTokens/refresh";
constexpr char kSentinel[] = "SYNTHETIC_PRIVATE_VALUE_6d3f1a";
constexpr std::size_t kChunkLimit = 4096, kLineLimit = 4096, kIdLimit = 64;
using ReadFn = BOOL(WINAPI*)(HANDLE, LPVOID, DWORD, LPDWORD, LPOVERLAPPED);
using GorFn = BOOL(WINAPI*)(HANDLE, LPOVERLAPPED, LPDWORD, BOOL);
ReadFn gReadOriginal = nullptr;
GorFn gGorOriginal = nullptr;

struct Handle {
  HANDLE h = nullptr;
  Handle() = default;
  explicit Handle(HANDLE value) : h(value) {}
  ~Handle() { reset(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  void reset(HANDLE value = nullptr) {
    if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h);
    h = value;
  }
  bool good() const { return h && h != INVALID_HANDLE_VALUE; }
};

enum class Method : unsigned { Refresh = 1 };
enum class IdKind : unsigned { Number = 1, String = 2 };
struct Event {
  Method method = Method::Refresh;
  IdKind kind = IdKind::Number;
  std::int64_t number = 0;
  unsigned length = 0;
  char text[kIdLimit]{};
};
struct Queue {
  std::array<Event, 16> slots{};
  std::atomic<unsigned> head{0}, tail{0};
  bool push(const Event& event) {
    const unsigned h = head.load(std::memory_order_relaxed);
    if (h - tail.load(std::memory_order_acquire) == slots.size()) return false;
    slots[h % slots.size()] = event;
    head.store(h + 1, std::memory_order_release);
    return true;
  }
  bool pop(Event& event) {
    const unsigned t = tail.load(std::memory_order_relaxed);
    if (t == head.load(std::memory_order_acquire)) return false;
    event = slots[t % slots.size()];
    tail.store(t + 1, std::memory_order_release);
    return true;
  }
  bool empty() const { return head.load(std::memory_order_acquire) == tail.load(std::memory_order_acquire); }
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

struct Context {
  HANDLE reader = nullptr, writer = nullptr;
  DWORD readerThread = 0;
  Queue queue;
  Parser parser;
  Stats stats;
  std::atomic<bool> stop{false}, workerGood{true}, sentinelAbsent{true};
  std::atomic<unsigned> replies{0}, numberIds{0}, stringIds{0};
  struct Pending { HANDLE handle = nullptr; OVERLAPPED* overlapped = nullptr; void* buffer = nullptr; DWORD capacity = 0; bool used = false; } pending;
  BOOL lastReadResult = FALSE, lastGorResult = FALSE;
  DWORD lastReadError = 0, lastGorError = 0;
};
std::atomic<Context*> gContext{nullptr};
std::atomic<bool> gEnabled{false};

std::uint64_t hashBytes(const void* buffer, std::size_t count) {
  const auto* p = static_cast<const unsigned char*>(buffer);
  std::uint64_t h = 1469598103934665603ull;
  for (std::size_t i = 0; i < count; ++i) { h ^= p[i]; h *= 1099511628211ull; }
  return h;
}
void observe(Context& context, void* buffer, DWORD count, OVERLAPPED* overlapped) {
  if (count > kChunkLimit) { ++context.stats.drops; return; }
  const auto before = hashBytes(buffer, count);
  OVERLAPPED snapshot{}; if (overlapped) snapshot = *overlapped;
  context.parser.feed(static_cast<const char*>(buffer), count, context.queue, context.stats);
  if (before != hashBytes(buffer, count) || (overlapped && std::memcmp(&snapshot, overlapped, sizeof snapshot) != 0)) context.stats.immutable = false;
}
BOOL WINAPI ReadHook(HANDLE handle, LPVOID buffer, DWORD capacity, LPDWORD transferred, LPOVERLAPPED overlapped) {
  const BOOL result = gReadOriginal(handle, buffer, capacity, transferred, overlapped);
  const DWORD error = GetLastError();
  Context* context = gContext.load(std::memory_order_acquire);
  if (gEnabled.load(std::memory_order_acquire) && context && handle == context->reader) {
    ++context->stats.submissions; context->lastReadResult = result; context->lastReadError = error;
    if (GetCurrentThreadId() != context->readerThread) context->stats.onlyReader = false;
    else if (result && transferred && *transferred <= capacity) { ++context->stats.immediate; observe(*context, buffer, *transferred, overlapped); }
    else if (!result && error == ERROR_IO_PENDING && overlapped && capacity) {
      ++context->stats.pending;
      if (context->pending.used) ++context->stats.drops;
      else context->pending = {handle, overlapped, buffer, capacity, true};
    }
  }
  SetLastError(error); return result;
}
BOOL WINAPI GorHook(HANDLE handle, LPOVERLAPPED overlapped, LPDWORD transferred, BOOL wait) {
  const BOOL result = gGorOriginal(handle, overlapped, transferred, wait);
  const DWORD error = GetLastError();
  Context* context = gContext.load(std::memory_order_acquire);
  if (gEnabled.load(std::memory_order_acquire) && context && handle == context->reader) {
    context->lastGorResult = result; context->lastGorError = error;
    auto& pending = context->pending;
    if (GetCurrentThreadId() != context->readerThread) context->stats.onlyReader = false;
    else if (pending.used && pending.handle == handle && pending.overlapped == overlapped) {
      if (result && transferred && *transferred <= pending.capacity) {
        ++context->stats.gorCompleted; observe(*context, pending.buffer, *transferred, overlapped);
      }
      if (result || (error != ERROR_IO_INCOMPLETE && error != ERROR_IO_PENDING)) pending = {};
    }
  }
  SetLastError(error); return result;
}

struct Patch {
  PVOID volatile* slot = nullptr;
  PVOID original = nullptr, replacement = nullptr;
  bool installed = false, protectionRestored = true;
};
PVOID volatile* findImport(const char* wanted) {
  auto* base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || nt->Signature != IMAGE_NT_SIGNATURE) return nullptr;
  const DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
  if (!rva) return nullptr;
  for (auto* desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + rva); desc->Name; ++desc) {
    if (!desc->OriginalFirstThunk) continue;
    auto* names = reinterpret_cast<IMAGE_THUNK_DATA64*>(base + desc->OriginalFirstThunk);
    auto* slots = reinterpret_cast<IMAGE_THUNK_DATA64*>(base + desc->FirstThunk);
    for (; names->u1.AddressOfData; ++names, ++slots) {
      if (IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal)) continue;
      auto* name = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData);
      if (std::strcmp(reinterpret_cast<const char*>(name->Name), wanted) == 0) return reinterpret_cast<PVOID volatile*>(&slots->u1.Function);
    }
  }
  return nullptr;
}
bool exchange(Patch& patch, bool install) {
  MEMORY_BASIC_INFORMATION before{}, after{};
  if (!VirtualQuery(const_cast<PVOID*>(patch.slot), &before, sizeof before)) return false;
  DWORD old = 0, ignored = 0;
  if (!VirtualProtect(const_cast<PVOID*>(patch.slot), sizeof(PVOID), PAGE_READWRITE, &old)) return false;
  const PVOID expected = install ? patch.original : patch.replacement;
  const PVOID replacement = install ? patch.replacement : patch.original;
  const PVOID previous = InterlockedCompareExchangePointer(patch.slot, replacement, expected);
  const BOOL restored = VirtualProtect(const_cast<PVOID*>(patch.slot), sizeof(PVOID), old, &ignored);
  const bool queried = VirtualQuery(const_cast<PVOID*>(patch.slot), &after, sizeof after) != 0;
  patch.protectionRestored = patch.protectionRestored && restored && queried && before.Protect == after.Protect;
  if (previous == expected) patch.installed = install;
  return previous == expected && patch.protectionRestored;
}

bool containsSentinel(const void* buffer, std::size_t length) {
  const auto* b = static_cast<const char*>(buffer);
  return length >= sizeof(kSentinel) - 1 && std::search(b, b + length, kSentinel, kSentinel + sizeof(kSentinel) - 1) != b + length;
}
bool writeAll(HANDLE handle, const std::string& value) {
  std::size_t offset = 0;
  while (offset < value.size()) {
    DWORD n = 0; const DWORD request = static_cast<DWORD>(value.size() - offset);
    if (!WriteFile(handle, value.data() + offset, request, &n, nullptr) || n == 0) return false;
    offset += n;
  }
  return true;
}
std::string reply(const Event& event) {
  std::string id;
  if (event.kind == IdKind::Number) id = std::to_string(event.number);
  else {
    id = "\"";
    for (unsigned i = 0; i < event.length; ++i) {
      const unsigned c = static_cast<unsigned char>(event.text[i]);
      if (c == '"' || c == '\\') { id += '\\'; id += static_cast<char>(c); }
      else if (c < 0x20) { char escape[7]{}; std::snprintf(escape, sizeof escape, "\\u%04x", c); id += escape; }
      else id += static_cast<char>(c);
    }
    id += '"';
  }
  return "{\"id\":" + id + ",\"result\":{\"fixtureAck\":true}}\n";
}
Event numericId() { Event e{}; e.number = 101; return e; }
Event stringId() { Event e{}; e.kind = IdKind::String; const char s[] = "owned-string-2"; e.length = sizeof(s) - 1; std::memcpy(e.text, s, sizeof(s)); return e; }
bool rejectNulAliases() {
  const char* cases[] = {
    "{\"id\":1,\"method\":\"account/chatgptAuthTokens/refresh\\u0000suffix\"}",
    "{\"id\":1,\"method\\u0000suffix\":\"account/chatgptAuthTokens/refresh\"}"
  };
  for (const char* input : cases) {
    Event event{}; bool refresh = false; Json json{input, input + std::strlen(input)};
    if (json.root(event, refresh) || refresh) return false;
  }
  return true;
}
DWORD WINAPI observerWorker(void* opaque) {
  auto& context = *static_cast<Context*>(opaque);
  while (!context.stop.load(std::memory_order_acquire) || !context.queue.empty()) {
    Event event{};
    if (!context.queue.pop(event)) { Sleep(1); continue; }
    if (containsSentinel(&event, sizeof event)) context.sentinelAbsent.store(false);
    const bool number = event.kind == IdKind::Number && event.number == 101;
    const Event expectedString = stringId();
    const bool string = event.kind == IdKind::String && event.length == expectedString.length && std::memcmp(event.text, expectedString.text, event.length) == 0;
    if (event.method != Method::Refresh || (!number && !string)) { context.workerGood.store(false); continue; }
    if (number) ++context.numberIds; else ++context.stringIds;
    const auto response = reply(event);
    if (containsSentinel(response.data(), response.size())) context.sentinelAbsent.store(false);
    if (!writeAll(context.writer, response)) context.workerGood.store(false); else ++context.replies;
  }
  return 0;
}

std::string lastInitialFrame() {
  return "{\"params\":{\"authToken\":\"" + std::string(kSentinel) + "\",\"ignored\":\"split \\u0061 escape\"},\"method\":\"" + kMethod + "\",\"id\":\"owned-\\u0073tring-2\"}\n";
}
std::string initialFrames() {
  const std::string secret = kSentinel;
  return "{\"method\":\"fixture/ready\"}\n"
    "{\"method\":\"fixture/nested\",\"params\":{\"method\":\"" + std::string(kMethod) + "\",\"id\":\"nested-only\",\"authToken\":\"" + secret + "\"}}\n"
    "{\"id\":\"duplicate-method\",\"method\":\"" + kMethod + "\",\"method\":\"" + kMethod + "\"}\n"
    "{\"id\":\"duplicate-id\",\"id\":77,\"method\":\"" + kMethod + "\"}\n"
    "{\"id\":900,\"result\":{\"authToken\":\"" + secret + "\"}}\n"
    "{\"params\":{\"authToken\":\"" + secret + "\",\"nested\":{\"method\":\"" + kMethod + "\",\"id\":999}},\"id\":101,\"method\":\"" + kMethod + "\"}\n" + lastInitialFrame();
}
std::string finalFrames() { return "{\"method\":\"fixture/continued\",\"params\":{\"count\":2}}\n{\"method\":\"fixture/done\"}\n"; }
bool readLine(HANDLE handle, std::string& line) {
  line.clear();
  for (unsigned i = 0; i < 1024; ++i) { char c = 0; DWORD n = 0; if (!ReadFile(handle, &c, 1, &n, nullptr) || n != 1) return false; line += c; if (c == '\n') return true; }
  return false;
}
int serverMain(HANDLE ready, HANDLE finished) {
  const HANDLE input = GetStdHandle(STD_INPUT_HANDLE), output = GetStdHandle(STD_OUTPUT_HANDLE);
  std::string line;
  if (!readLine(input, line) || line != "go\n") return 31;
  if (!writeAll(output, initialFrames()) || !SetEvent(ready)) return 32;
  bool gotNumber = false, gotString = false;
  for (unsigned i = 0; i < 2; ++i) {
    if (!readLine(input, line)) return 33;
    if (line == reply(numericId()) && !gotNumber) gotNumber = true;
    else if (line == reply(stringId()) && !gotString) gotString = true;
    else return 34;
  }
  if (!gotNumber || !gotString || !writeAll(output, finalFrames()) || !SetEvent(finished)) return 35;
  return 0;
}

struct Result {
  bool setup = false, pass = false, originalEqual = false, childContinued = false;
  bool immediateSeen = false, pendingSeen = false, gorSeen = false, fragmented = false, coalesced = false;
  bool duplicatesRejected = false, nestedIgnored = false, sentinelAbsent = false, apiInvariant = false, onlyReader = false;
  unsigned bytes = 0, frames = 0, events = 0, replies = 0, numberIds = 0, stringIds = 0, drops = 0;
};
Result runScenario(bool pendingScenario) {
  Result result;
  SECURITY_ATTRIBUTES inherit{sizeof inherit, nullptr, TRUE};
  Handle ready(CreateEventW(&inherit, TRUE, FALSE, nullptr)), finished(CreateEventW(&inherit, TRUE, FALSE, nullptr));
  const auto name = L"\\\\.\\pipe\\OwnedIatObserver-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()) + (pendingScenario ? L"-p" : L"-i");
  Handle readPipe(CreateNamedPipeW(name.c_str(), PIPE_ACCESS_INBOUND | (pendingScenario ? FILE_FLAG_OVERLAPPED : 0), PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 65536, 65536, 0, nullptr));
  Handle childOutput(CreateFileW(name.c_str(), GENERIC_WRITE, 0, &inherit, OPEN_EXISTING, 0, nullptr));
  Handle connectEvent(CreateEventW(nullptr, TRUE, FALSE, nullptr)); OVERLAPPED connection{}; connection.hEvent = connectEvent.h;
  if (!ready.good() || !finished.good() || !readPipe.good() || !childOutput.good() || !connectEvent.good()) return result;
  if (!ConnectNamedPipe(readPipe.h, pendingScenario ? &connection : nullptr)) {
    const DWORD error = GetLastError();
    if (error != ERROR_PIPE_CONNECTED) {
      if (error != ERROR_IO_PENDING || WaitForSingleObject(connectEvent.h, 5000) != WAIT_OBJECT_0) return result;
      DWORD ignored = 0; if (!gGorOriginal(readPipe.h, &connection, &ignored, TRUE)) return result;
    }
  }
  HANDLE rawInput = nullptr, rawWriter = nullptr;
  if (!CreatePipe(&rawInput, &rawWriter, &inherit, 4096)) return result;
  Handle childInput(rawInput), writer(rawWriter), nullError(CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, nullptr));
  if (!nullError.good() || !SetHandleInformation(writer.h, HANDLE_FLAG_INHERIT, 0)) return result;
  std::array<wchar_t, 32768> executable{};
  if (!GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size()))) return result;
  std::wstring command = L"\"" + std::wstring(executable.data()) + L"\" --server " + std::to_wstring(reinterpret_cast<std::uintptr_t>(ready.h)) + L" " + std::to_wstring(reinterpret_cast<std::uintptr_t>(finished.h));
  STARTUPINFOW startup{}; startup.cb = sizeof startup; startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = childInput.h; startup.hStdOutput = childOutput.h; startup.hStdError = nullError.h;
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) return result;
  Handle child(process.hProcess), childThread(process.hThread); childInput.reset(); childOutput.reset(); nullError.reset();
  Context context; context.reader = readPipe.h; context.writer = writer.h; context.readerThread = GetCurrentThreadId();
  Handle worker(CreateThread(nullptr, 0, observerWorker, &context, 0, nullptr));
  if (!worker.good()) { TerminateProcess(child.h, 40); WaitForSingleObject(child.h, 5000); return result; }
  result.setup = true; gContext.store(&context, std::memory_order_release); gEnabled.store(true, std::memory_order_release);
  const auto initial = initialFrames(), final = finalFrames(), expected = initial + final;
  const std::size_t prefix = initial.size() - lastInitialFrame().size();
  std::string received; received.reserve(expected.size()); bool good = true, sentGo = false;
  Handle readEvent(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (!readEvent.good()) good = false;
  if (!pendingScenario && good) { sentGo = writeAll(writer.h, "go\n"); good = sentGo && WaitForSingleObject(ready.h, 5000) == WAIT_OBJECT_0; }
  unsigned readCalls = 0, fragmentIndex = 0;
  const DWORD pieces[] = {1, 2, 3, 5, 7, 11};
  auto readSome = [&](DWORD capacity) {
    char buffer[kChunkLimit]{}; DWORD n = 0; OVERLAPPED overlap{}; overlap.hEvent = readEvent.h;
    ResetEvent(readEvent.h);
    const BOOL ok = ReadFile(readPipe.h, buffer, capacity, &n, pendingScenario ? &overlap : nullptr);
    const DWORD error = GetLastError(); ++readCalls;
    if (ok != context.lastReadResult || error != context.lastReadError) context.stats.lastErrorPreserved = false;
    if (!sentGo) {
      if (ok || error != ERROR_IO_PENDING) return false;  // Controlled pending case must be genuinely pending.
      sentGo = writeAll(writer.h, "go\n"); if (!sentGo) return false;
    }
    if (!ok) {
      if (error != ERROR_IO_PENDING) return false;
      if (WaitForSingleObject(readEvent.h, 5000) != WAIT_OBJECT_0) {
        CancelIoEx(readPipe.h, &overlap); DWORD ignored = 0; GetOverlappedResult(readPipe.h, &overlap, &ignored, TRUE); return false;
      }
      const BOOL completed = GetOverlappedResult(readPipe.h, &overlap, &n, TRUE);
      const DWORD completedError = GetLastError();
      if (completed != context.lastGorResult || completedError != context.lastGorError) context.stats.lastErrorPreserved = false;
      if (!completed) return false;
    }
    if (n == 0 || n > capacity) return false;
    received.append(buffer, n); return true;
  };
  if (good) good = readSome(static_cast<DWORD>(prefix));
  while (good && received.size() < initial.size()) {
    const auto n = std::min<std::size_t>(pieces[fragmentIndex++ % (sizeof pieces / sizeof pieces[0])], initial.size() - received.size());
    good = readSome(static_cast<DWORD>(n));
  }
  if (good) good = WaitForSingleObject(finished.h, 5000) == WAIT_OBJECT_0;
  while (good && received.size() < expected.size()) good = readSome(static_cast<DWORD>(std::min<std::size_t>(kChunkLimit, expected.size() - received.size())));
  if (!good) TerminateProcess(child.h, 41);
  const bool childExited = WaitForSingleObject(child.h, 5000) == WAIT_OBJECT_0;
  DWORD childCode = 99; if (childExited) GetExitCodeProcess(child.h, &childCode);
  if (!childExited) { TerminateProcess(child.h, 42); WaitForSingleObject(child.h, 5000); }
  context.stop.store(true, std::memory_order_release);
  if (WaitForSingleObject(worker.h, 5000) != WAIT_OBJECT_0) ExitProcess(90);  // Do not destroy a live worker's context.
  gEnabled.store(false, std::memory_order_release); gContext.store(nullptr, std::memory_order_release);
  result.originalEqual = received == expected;
  result.childContinued = childExited && childCode == 0;
  result.bytes = static_cast<unsigned>(received.size()); result.frames = context.stats.lines;
  result.events = context.stats.events; result.replies = context.replies.load(); result.numberIds = context.numberIds.load(); result.stringIds = context.stringIds.load(); result.drops = context.stats.drops;
  result.immediateSeen = context.stats.immediate > 0; result.pendingSeen = context.stats.pending > 0; result.gorSeen = context.stats.gorCompleted > 0;
  result.fragmented = context.stats.fragmented; result.coalesced = context.stats.coalesced;
  result.duplicatesRejected = context.stats.duplicateRejected == 2 && context.stats.rejected == 2;
  result.nestedIgnored = result.events == 2 && context.workerGood.load();
  result.sentinelAbsent = context.sentinelAbsent.load(); result.apiInvariant = context.stats.immutable && context.stats.lastErrorPreserved;
  result.onlyReader = context.stats.onlyReader && context.stats.submissions == readCalls;
  result.pass = good && result.originalEqual && result.childContinued && result.frames == 9 && result.events == 2 && result.replies == 2 && result.numberIds == 1 && result.stringIds == 1 && result.drops == 0 && result.fragmented && result.coalesced && result.duplicatesRejected && result.nestedIgnored && result.sentinelAbsent && result.apiInvariant && result.onlyReader && (pendingScenario ? result.pendingSeen && result.gorSeen : result.immediateSeen);
  return result;
}

std::string boolean(bool value) { return value ? "true" : "false"; }
std::string resultJson(const Result& r) {
  return "{\"pass\":" + boolean(r.pass) + ",\"setup\":" + boolean(r.setup) + ",\"original_bytes_equal\":" + boolean(r.originalEqual) + ",\"continued\":" + boolean(r.childContinued) + ",\"bytes\":" + std::to_string(r.bytes) + ",\"frames\":" + std::to_string(r.frames) + ",\"events\":" + std::to_string(r.events) + ",\"replies\":" + std::to_string(r.replies) + ",\"number_ids\":" + std::to_string(r.numberIds) + ",\"string_ids\":" + std::to_string(r.stringIds) + ",\"drops\":" + std::to_string(r.drops) + ",\"immediate_seen\":" + boolean(r.immediateSeen) + ",\"pending_seen\":" + boolean(r.pendingSeen) + ",\"gor_seen\":" + boolean(r.gorSeen) + ",\"fragmented\":" + boolean(r.fragmented) + ",\"coalesced\":" + boolean(r.coalesced) + ",\"duplicates_rejected\":" + boolean(r.duplicatesRejected) + ",\"nested_fake_ignored\":" + boolean(r.nestedIgnored) + ",\"sentinel_absent_from_observer\":" + boolean(r.sentinelAbsent) + ",\"api_invariant\":" + boolean(r.apiInvariant) + ",\"only_original_reader\":" + boolean(r.onlyReader) + "}";
}
int wmain(int argc, wchar_t** argv) {
  if (argc == 4 && std::wcscmp(argv[1], L"--server") == 0) {
    return serverMain(reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(_wcstoui64(argv[2], nullptr, 10))), reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(_wcstoui64(argv[3], nullptr, 10))));
  }
  if (argc != 3 || std::wcscmp(argv[1], L"--receipt") != 0) return 2;
  Patch read, gor;
  read.slot = findImport("ReadFile"); gor.slot = findImport("GetOverlappedResult");
  bool installed = read.slot && gor.slot;
  if (installed) {
    read.original = *read.slot; gor.original = *gor.slot;
    read.replacement = reinterpret_cast<PVOID>(&ReadHook); gor.replacement = reinterpret_cast<PVOID>(&GorHook);
    gReadOriginal = reinterpret_cast<ReadFn>(read.original); gGorOriginal = reinterpret_cast<GorFn>(gor.original);
    installed = exchange(gor, true) && exchange(read, true);
  }
  Result immediate, pending;
  if (installed) { immediate = runScenario(false); pending = runScenario(true); }
  gEnabled.store(false, std::memory_order_release);
  bool restored = true;
  if (read.installed) restored = exchange(read, false) && restored;
  if (gor.installed) restored = exchange(gor, false) && restored;
  restored = restored && read.slot && gor.slot && *read.slot == read.original && *gor.slot == gor.original;
  const bool protection = read.protectionRestored && gor.protectionRestored;
  const bool nulAliasesRejected = rejectNulAliases();
  const bool pass = installed && restored && protection && immediate.pass && pending.pass && nulAliasesRejected;
  std::string receipt = "{\"pass\":" + boolean(pass) + ",\"iat_installed\":" + boolean(installed) + ",\"iat_restored\":" + boolean(restored) + ",\"protection_restored\":" + boolean(protection) + ",\"nul_aliases_rejected\":" + boolean(nulAliasesRejected) + ",\"real_process_attachment_run\":false,\"node_electron_equivalence_run\":false,\"credentials_read\":false,\"immediate\":" + resultJson(immediate) + ",\"pending\":" + resultJson(pending);
  const bool receiptClean = !containsSentinel(receipt.data(), receipt.size());
  receipt += ",\"receipt_sentinel_absent\":" + boolean(receiptClean) + "}\n";
  Handle receiptFile(CreateFileW(argv[2], GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
  const bool written = receiptFile.good() && writeAll(receiptFile.h, receipt);
  std::fwrite(receipt.data(), 1, receipt.size(), stdout);
  return pass && receiptClean && written ? 0 : 1;
}
