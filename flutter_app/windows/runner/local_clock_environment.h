#ifndef RUNNER_LOCAL_CLOCK_ENVIRONMENT_H_
#define RUNNER_LOCAL_CLOCK_ENVIRONMENT_H_

#include <cstdlib>
#include <ctime>

namespace launcher_clock {
// Call before Flutter initializes its local-time cache. This changes only the
// calling process; Codex's explicit child environment is built separately.
inline bool UseSystemTimeZone() {
  if (_wputenv_s(L"TZ", L"") != 0) return false;
  _tzset();
  return true;
}
}  // namespace launcher_clock

#endif  // RUNNER_LOCAL_CLOCK_ENVIRONMENT_H_
