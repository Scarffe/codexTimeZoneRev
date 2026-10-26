#include <windows.h>

#include <cctype>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "../app_instance.h"

namespace {
int failures = 0;
int children_started = 0, children_cleaned = 0, children_forced = 0;
void Check(bool condition, const char* description) {
  std::cout << (condition ? "PASS " : "FAIL ") << description << '\n';
  if (!condition) ++failures;
}
LRESULT CALLBACK HiddenProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  return DefWindowProcW(window, message, wp, lp);
}
int Fixture(int argc, wchar_t** argv) {
  if (argc != 6) { std::cout << "fixture argc=" << argc << std::endl; return 2; }
  WNDCLASSW cls{};
  cls.lpfnWndProc = HiddenProc;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = argv[2];
  if (!RegisterClassW(&cls)) { std::cout << "RegisterClass error=" << GetLastError() << std::endl; return 3; }
  HWND window = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
      cls.lpszClassName, argv[3], WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
      cls.hInstance, nullptr);
  if (!window) { std::cout << "CreateWindow error=" << GetLastError() << std::endl; return 4; }
  if (std::wstring(argv[4]) == L"marked")
    app_instance::Mark(window, std::wstring(argv[5]) == L"isolated");
  std::cout << reinterpret_cast<UINT_PTR>(window) << std::endl;
  char byte = 0;
  DWORD read = 0;
  ReadFile(GetStdHandle(STD_INPUT_HANDLE), &byte, 1, &read, nullptr);
  DestroyWindow(window);
  return 0;
}
struct Child {
  HANDLE process = nullptr, input = nullptr;
  HWND window = nullptr;
  DWORD pid = 0;
  bool stopped = false;
  Child(const std::wstring& executable, const std::wstring& cls,
        const std::wstring& title, bool marked, bool isolated) {
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    HANDLE child_input = nullptr, output = nullptr, child_output = nullptr;
    if (!CreatePipe(&child_input, &input, &security, 0) ||
        !CreatePipe(&output, &child_output, &security, 0)) return;
    SetHandleInformation(input, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = child_input;
    startup.hStdOutput = startup.hStdError = child_output;
    auto command = L"\"" + executable + L"\" --fixture \"" + cls + L"\" \"" + title +
        L"\" " + (marked ? L"marked" : L"legacy") +
        (isolated ? L" isolated" : L" normal");
    PROCESS_INFORMATION info{};
    const bool started = CreateProcessW(executable.c_str(), command.data(), nullptr,
        nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &info) != FALSE;
    if (!started) std::cerr << "owned child CreateProcess error=" << GetLastError() << '\n';
    CloseHandle(child_input);
    CloseHandle(child_output);
    if (started) {
      ++children_started;
      process = info.hProcess; pid = info.dwProcessId; CloseHandle(info.hThread);
      std::string line;
      char byte = 0;
      DWORD read = 0;
      while (ReadFile(output, &byte, 1, &read, nullptr) && read && byte != '\n')
        line += byte;
      if (!line.empty() && std::isdigit(static_cast<unsigned char>(line[0])))
        window = reinterpret_cast<HWND>(std::stoull(line));
      else {
        DWORD code = 0;
        WaitForSingleObject(process, 1000);
        GetExitCodeProcess(process, &code);
        std::cerr << "owned child metadata=" << line << " exit=" << code << '\n';
      }
    }
    CloseHandle(output);
  }
  ~Child() { Stop(); }
  void Stop() {
    if (stopped) return;
    stopped = true;
    if (input) { CloseHandle(input); input = nullptr; }
    if (process) {
      // Only the exact child handle created above is ever cleaned up.
      if (WaitForSingleObject(process, 5000) != WAIT_OBJECT_0) {
        ++children_forced;
        TerminateProcess(process, 9);
      }
      DWORD code = 0;
      if (WaitForSingleObject(process, 5000) == WAIT_OBJECT_0 &&
          GetExitCodeProcess(process, &code) && code == 0) ++children_cleaned;
      CloseHandle(process); process = nullptr;
    }
  }
};
}

int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--fixture") return Fixture(argc, argv);
  const auto executable = app_instance::ImagePath(GetCurrentProcess());
  const auto cls = L"CodexTimeZone.Owned.LanguageFixture." +
      std::to_wstring(GetCurrentProcessId());
  app_instance::Options options;
  options.windowClass = cls;
  options.executable = std::filesystem::path(executable).filename().wstring();
  const auto foreground = GetForegroundWindow();
  const auto search = [&](Child& child, bool isolated) {
    options.isolated = isolated;
    DWORD pid = 0;
    const auto found = app_instance::Existing(options, &pid);
    return found == child.window && pid == child.pid;
  };
  // Break caught: a display title comparison prevents a correctly marked
  // English (or user-renamed) window from participating in single-instance reuse.
  {
    Child child(executable, cls, L"Codex Time Zone Launcher", true, false);
    Check(child.window && search(child, false), "marked English display title is discoverable");
    Check(child.window && !IsWindowVisible(child.window), "candidate remains hidden");
  }
  {
    Child child(executable, cls, L"Display title is presentation", true, false);
    Check(child.window && search(child, false), "stable marker works independently of display title");
  }
  {
    Child child(executable, cls, L"Codex 时区启动器", false, false);
    Check(child.window && search(child, false), "legacy unmarked Chinese window remains compatible");
  }
  {
    Child child(executable, cls, L"Codex Time Zone Launcher", false, false);
    options.isolated = false;
    Check(child.window && !app_instance::Existing(options), "unmarked English lookalike is rejected");
  }
  {
    Child child(executable, cls, L"Codex Time Zone Launcher", true, true);
    Check(child.window && search(child, true), "isolated English marker remains discoverable");
    options.isolated = false;
    Check(!app_instance::Existing(options), "normal search excludes isolated marker");
  }
  {
    Child child(executable, cls, L"Codex 时区启动器", true, false);
    options.isolated = true;
    Check(child.window && !app_instance::Existing(options), "isolated search excludes normal primary");
  }
  const auto copy_dir = std::filesystem::path(executable).parent_path() / L"other-path";
  std::filesystem::create_directories(copy_dir);
  const auto copied = copy_dir / std::filesystem::path(executable).filename();
  CopyFileW(executable.c_str(), copied.c_str(), FALSE);
  {
    Child child(copied.wstring(), cls, L"Codex Time Zone Launcher", true, true);
    options.isolated = true;
    Check(child.window && !app_instance::Existing(options), "isolated same filename in another path is rejected");
  }
  {
    Child child(copied.wstring(), cls, L"Codex Time Zone Launcher", true, false);
    Check(child.window && search(child, false), "normal cross-path policy remains compatible");
  }
  {
    Child primary(executable, cls, L"Codex Time Zone Launcher", true, false);
    Sleep(25);
    Child legacy(executable, cls, L"Codex 时区启动器", false, false);
    Check(primary.window && legacy.window && search(primary, false), "elected primary wins over newer legacy candidate");
  }
  {
    Child older(executable, cls, L"Codex 时区启动器", false, false);
    Sleep(25);
    Child newer(executable, cls, L"Codex 时区启动器", false, false);
    Check(older.window && newer.window && search(newer, false), "newest legacy candidate retains election priority");
  }
  Check(GetForegroundWindow() == foreground, "discovery never changes foreground window");
  Check(!app_instance::Existing(options), "all owned fixture windows were destroyed");
  Check(children_started == 12 && children_cleaned == 12 && !children_forced,
        "all 12 owned child processes exited normally through stdin cleanup");
  std::cout << "failures=" << failures << '\n';
  return failures ? 1 : 0;
}
