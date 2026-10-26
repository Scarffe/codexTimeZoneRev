#pragma once
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>

constexpr std::uint32_t kMetadataMagic = 0x43544d31;
struct CtzPipeMetadata {
  std::uint32_t magic, bytes;
  std::uint32_t identityMatched, nameOk, localOk, usersOk;
  std::uint32_t fileType, fileTypeError;
  std::int32_t nameStatus, localStatus, usersStatus;
  std::uint32_t fields[10];
  std::uint32_t nameChars, userCount;
  wchar_t name[2048];
  std::uint64_t users[128];
};
