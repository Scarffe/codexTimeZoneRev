#include "metadata_protocol.h"
#include <winternl.h>
#include <array>
#include <cwchar>
#include <cstring>

using NtQueryObjectFn = LONG(NTAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);
using NtQueryFileFn = LONG(NTAPI*)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, ULONG);

// Private short-lived metadata worker. It never reads/writes pipe payload and
// never changes a target process. The creator bounds its lifetime, because some
// synchronous name queries can wait behind an existing original I/O request.
int wmain(int argc, wchar_t** argv) {
  if (argc != 5) return 10;
  wchar_t* end = nullptr;
  const auto pidValue = std::wcstoull(argv[1], &end, 10);
  if (!end || *end || !pidValue || pidValue > MAXDWORD) return 10;
  const auto creation = std::wcstoull(argv[2], &end, 10);
  if (!end || *end || !creation) return 10;
  const auto handleValue = std::wcstoull(argv[3], &end, 10);
  if (!end || *end || !handleValue) return 10;
  const auto relatedPid = std::wcstoull(argv[4], &end, 10);
  if (!end || *end || relatedPid > MAXDWORD) return 10;
  CtzPipeMetadata result{}; result.magic = kMetadataMagic; result.bytes = sizeof result;
  HANDLE target = OpenProcess(PROCESS_DUP_HANDLE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, static_cast<DWORD>(pidValue));
  if (!target) return 11;
  FILETIME c{}, e{}, k{}, u{};
  const bool identity = GetProcessTimes(target, &c, &e, &k, &u)
    && ((static_cast<std::uint64_t>(c.dwHighDateTime) << 32) | c.dwLowDateTime) == creation;
  HANDLE file = nullptr;
  if (identity) result.identityMatched = 1;
  if (!identity || !DuplicateHandle(target, reinterpret_cast<HANDLE>(handleValue), GetCurrentProcess(), &file, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
    CloseHandle(target); return 12;
  }
  const auto nt = GetModuleHandleW(L"ntdll.dll");
  const auto queryObject = reinterpret_cast<NtQueryObjectFn>(GetProcAddress(nt, "NtQueryObject"));
  const auto queryFile = reinterpret_cast<NtQueryFileFn>(GetProcAddress(nt, "NtQueryInformationFile"));
  if (!queryObject || !queryFile) { CloseHandle(file); CloseHandle(target); return 13; }
  alignas(void*) std::array<unsigned char, 65536> buffer{};
  IO_STATUS_BLOCK io{};
  SetLastError(ERROR_SUCCESS);
  result.fileType = GetFileType(file); result.fileTypeError = GetLastError();
  if (result.fileType == FILE_TYPE_PIPE) result.localStatus = queryFile(file, &io, buffer.data(), static_cast<ULONG>(buffer.size()), 24);
  if (result.fileType == FILE_TYPE_PIPE && result.localStatus == 0) {
    result.localOk = 1;
    std::memcpy(result.fields, buffer.data(), sizeof result.fields);
    result.usersStatus = queryFile(file, &io, buffer.data(), static_cast<ULONG>(buffer.size()), 47);
    if (result.usersStatus == 0) {
      const auto count = *reinterpret_cast<const ULONG*>(buffer.data());
      if (count <= 128 && 8ull + count * sizeof(std::uint64_t) <= io.Information) {
        result.usersOk = 1; result.userCount = count;
        std::memcpy(result.users, buffer.data() + 8, count * sizeof(std::uint64_t));
      }
    }
    bool related = !relatedPid;
    for (unsigned i = 0; i < result.userCount; ++i) if (result.users[i] == relatedPid) related = true;
    // An unrelated pipe has already been classified by its process membership;
    // do not issue a potentially blocking name query for it.
    if (result.usersOk && related) {
      ULONG required = 0;
      result.nameStatus = queryObject(file, 1, buffer.data(), static_cast<ULONG>(buffer.size()), &required);
      if (result.nameStatus == 0) {
        const auto* name = reinterpret_cast<const UNICODE_STRING*>(buffer.data());
        const auto count = static_cast<std::uint32_t>(name->Length / sizeof(wchar_t));
        if (name->Buffer && count < 2048) {
          result.nameOk = 1; result.nameChars = count;
          std::memcpy(result.name, name->Buffer, name->Length);
        }
      }
    }
  }
  CloseHandle(file); CloseHandle(target);
  DWORD written = 0;
  return WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), &result, sizeof result, &written, nullptr) && written == sizeof result ? 0 : 14;
}
