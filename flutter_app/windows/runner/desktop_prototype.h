#ifndef RUNNER_DESKTOP_PROTOTYPE_H_
#define RUNNER_DESKTOP_PROTOTYPE_H_
#include <string>
#include <vector>

namespace desktop_prototype {
bool Requested(const std::vector<std::wstring>& arguments);
// Opt-in, native-only Stage A surface. Never reads credentials or launches Codex.
int Run(const std::vector<std::wstring>& arguments);
}
#endif
