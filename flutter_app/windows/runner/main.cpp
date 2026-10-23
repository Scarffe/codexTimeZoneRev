#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"
#include "package_context.h"
#include "desktop_prototype.h"
#include "app_instance.h"
#include "local_clock_environment.h"
#include "window_chrome.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::vector<std::wstring> arguments;
  if (argv) {
    for (int i = 1; i < argc; ++i) arguments.emplace_back(argv[i]);
    LocalFree(argv);
  }
  int bootstrap = package_context::Prepare(arguments);
  if (bootstrap != -1) return bootstrap;
  // Own Shell grouping is independent of the package identity used to launch.
  // Apply after package handoff and before any launcher/prototype UI.
  window_chrome::InitializeProcessIdentity();
  if (desktop_prototype::Requested(arguments)) {
    return desktop_prototype::Run(arguments);
  }
  const bool monitor = std::find(arguments.begin(),arguments.end(),L"--desktop-monitor") != arguments.end();
  const bool monitor_exit = std::find(arguments.begin(),arguments.end(),L"--monitor-exit") != arguments.end();
  const int test_action=desktop_prototype::ForwardWorkspaceTestAction(arguments);
  if(test_action!=-1) return test_action;
  // The directory-scoped service lease belongs to every real app mode.
  // Exit requests reach this owner before any restore-to-foreground operation.
  if(!desktop_prototype::ClaimMonitorInstance(monitor_exit)) return 0;
  app_instance::Lease application;
  if(!monitor_exit) {
    app_instance::Options options; options.isolated=app_instance::Has(arguments,L"--isolated-instance");
    const auto decision=application.Claim(options);
    if(decision!=app_instance::Decision::start) return decision==app_instance::Decision::reused ? 0 : 1;
  }
  if (!launcher_clock::UseSystemTimeZone()) {
    MessageBoxW(nullptr, L"无法初始化系统本地时区，启动已停止。",
                L"Codex 时区启动器", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments;
  for (const auto& argument : arguments) {
    if (!package_context::IsInternalArgument(argument))
      command_line_arguments.push_back(Utf8FromUtf16(argument.c_str()));
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, monitor);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 900);
  if (!window.Create(L"Codex 时区启动器", origin, size)) {
    return EXIT_FAILURE;
  }
  app_instance::Mark(window.GetHandle(),app_instance::IsolatedProcess());
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
