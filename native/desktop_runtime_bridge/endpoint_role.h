#pragma once
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <cwchar>
#include <string_view>
#pragma comment(lib, "shell32.lib")

enum class EndpointRole { Unknown, Other, StdioAppServer };

// The fixed Desktop launcher uses -c/value before app-server, and may append
// additional -c/value pairs after it. Never search arbitrary values for a verb.
// Only the known stdio startup form is an endpoint for this adapter.
inline EndpointRole parsedEndpointRole(int count, wchar_t** args) {
  if (count < 2 || !args) return EndpointRole::Other;
  int index = 1;
  while (index < count) {
    const std::wstring_view arg(args[index]);
    if (arg == L"-c") { if (index + 1 >= count) return EndpointRole::Other; index += 2; }
    else if (arg == L"--no-daemon") ++index;
    else break;
  }
  if (index >= count || std::wstring_view(args[index++]) != L"app-server") return EndpointRole::Other;
  while (index < count) {
    const std::wstring_view arg(args[index++]);
    if (arg == L"-c") { if (index >= count) return EndpointRole::Other; ++index; }
    else if (arg == L"--analytics-default-enabled" || arg == L"--strict-config" || arg == L"--no-daemon") {}
    else if (arg == L"--listen") {
      if (index >= count || std::wstring_view(args[index++]) != L"stdio://") return EndpointRole::Other;
    } else if (arg == L"--listen=stdio://") {}
    else return EndpointRole::Other; // daemon/schema/exec/unknown transport is not this stdio endpoint.
  }
  return EndpointRole::StdioAppServer;
}

inline void freePrivateArgv(wchar_t** arguments) {
  if (!arguments) return;
  const auto bytes = LocalSize(arguments);
  if (bytes) SecureZeroMemory(arguments, bytes);
  LocalFree(arguments);
}
