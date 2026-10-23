#include <windows.h>

#include <cstdlib>
#include <ctime>
#include <iostream>
#include <sstream>

#include "../local_clock_environment.h"

namespace {
bool TimeZoneOverrideRemoved() {
  char* narrow = nullptr;
  wchar_t* wide = nullptr;
  size_t narrow_size = 0;
  size_t wide_size = 0;
  const auto narrow_error = _dupenv_s(&narrow, &narrow_size, "TZ");
  const auto wide_error = _wdupenv_s(&wide, &wide_size, L"TZ");
  const bool crt_removed = narrow_error == 0 && wide_error == 0 &&
                           narrow_size == 0 && wide_size == 0;
  free(narrow);
  free(wide);
  wchar_t value[2]{};
  SetLastError(ERROR_SUCCESS);
  const DWORD length = GetEnvironmentVariableW(L"TZ", value, 2);
  return crt_removed && length == 0 && GetLastError() == ERROR_ENVVAR_NOT_FOUND;
}

long long FileTimeTicks(const SYSTEMTIME& value) {
  FILETIME file_time{};
  if (!SystemTimeToFileTime(&value, &file_time)) return -1;
  ULARGE_INTEGER ticks{};
  ticks.LowPart = file_time.dwLowDateTime;
  ticks.HighPart = file_time.dwHighDateTime;
  return static_cast<long long>(ticks.QuadPart);
}

void WriteFields(std::ostream& output, const SYSTEMTIME& value,
                 long long offset_seconds) {
  output << "{\"year\":" << value.wYear << ",\"month\":" << value.wMonth
         << ",\"day\":" << value.wDay << ",\"hour\":" << value.wHour
         << ",\"minute\":" << value.wMinute << ",\"second\":" << value.wSecond
         << ",\"weekday\":" << value.wDayOfWeek
         << ",\"offsetSeconds\":" << offset_seconds << '}';
}

bool CheckInstant(const DYNAMIC_TIME_ZONE_INFORMATION& zone, int month,
                  std::ostream& output) {
  SYSTEMTIME utc{};
  utc.wYear = 2026;
  utc.wMonth = static_cast<WORD>(month);
  utc.wDay = 1;
  utc.wHour = 20;
  utc.wMinute = 15;
  utc.wSecond = 30;
  SYSTEMTIME expected{};
  if (!SystemTimeToTzSpecificLocalTimeEx(&zone, &utc, &expected)) {
    std::cerr << "Windows timezone conversion failed: " << GetLastError() << '\n';
    exit(2);
  }
  tm utc_fields{};
  utc_fields.tm_year = 126;
  utc_fields.tm_mon = month - 1;
  utc_fields.tm_mday = 1;
  utc_fields.tm_hour = 20;
  utc_fields.tm_min = 15;
  utc_fields.tm_sec = 30;
  const __time64_t instant = _mkgmtime64(&utc_fields);
  tm local{};
  if (instant == -1 || _localtime64_s(&local, &instant) != 0) {
    std::cerr << "CRT localtime conversion failed\n";
    exit(2);
  }
  SYSTEMTIME actual{};
  actual.wYear = static_cast<WORD>(local.tm_year + 1900);
  actual.wMonth = static_cast<WORD>(local.tm_mon + 1);
  actual.wDay = static_cast<WORD>(local.tm_mday);
  actual.wHour = static_cast<WORD>(local.tm_hour);
  actual.wMinute = static_cast<WORD>(local.tm_min);
  actual.wSecond = static_cast<WORD>(local.tm_sec);
  actual.wDayOfWeek = static_cast<WORD>(local.tm_wday);
  const long long actual_offset = _mkgmtime64(&local) - instant;
  const long long expected_offset =
      (FileTimeTicks(expected) - FileTimeTicks(utc)) / 10000000;
  const bool matches = actual.wYear == expected.wYear &&
      actual.wMonth == expected.wMonth && actual.wDay == expected.wDay &&
      actual.wHour == expected.wHour && actual.wMinute == expected.wMinute &&
      actual.wSecond == expected.wSecond &&
      actual.wDayOfWeek == expected.wDayOfWeek && actual_offset == expected_offset;
  output << "{\"utc\":\"2026-" << (month == 1 ? "01" : "06")
         << "-01T20:15:30Z\",\"crt\":";
  WriteFields(output, actual, actual_offset);
  output << ",\"windows\":";
  WriteFields(output, expected, expected_offset);
  output << ",\"matches\":" << (matches ? "true" : "false") << '}';
  return matches;
}
}  // namespace

int main() {
  // Prime the inherited CRT cache before the startup normalization under test.
  _tzset();
  if (!launcher_clock::UseSystemTimeZone()) {
    std::cerr << "Launcher timezone normalization failed\n";
    return 2;
  }
  DYNAMIC_TIME_ZONE_INFORMATION zone{};
  if (GetDynamicTimeZoneInformation(&zone) == TIME_ZONE_ID_INVALID) return 2;
  const bool removed = TimeZoneOverrideRemoved();
  std::ostringstream samples;
  const bool winter = CheckInstant(zone, 1, samples);
  samples << ',';
  const bool summer = CheckInstant(zone, 6, samples);
  const bool passed = removed && winter && summer;
  std::cout << "{\"tzRemoved\":" << (removed ? "true" : "false")
            << ",\"passed\":" << (passed ? "true" : "false")
            << ",\"samples\":[" << samples.str() << "]}\n";
  return passed ? 0 : 1;
}
