// Minimal public-ABI host for local-rollout acceptance. No process attachment.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <iostream>
#include <string>

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  HMODULE library = LoadLibraryW(argv[1]);
  if (!library) return 3;
  auto call = reinterpret_cast<char* (*)(const char*)>(GetProcAddress(library, "launcher_call"));
  auto release = reinterpret_cast<void (*)(char*)>(GetProcAddress(library, "launcher_free"));
  auto version = reinterpret_cast<unsigned (*)()>(GetProcAddress(library, "launcher_abi_version"));
  if (!call || !release || !version || version() != 1) return 4;
  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.size() > 1024 * 1024) return 5;
    char* result = call(line.c_str());
    if (!result) return 6;
    std::cout << result << '\n' << std::flush;
    release(result);
  }
  FreeLibrary(library);
  return 0;
}
