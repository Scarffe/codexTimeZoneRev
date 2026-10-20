#ifndef RUNNER_DESKTOP_PROTOTYPE_H_
#define RUNNER_DESKTOP_PROTOTYPE_H_
#include <string>
#include <vector>
#include <functional>
#include <cstdint>
#include <windows.h>

namespace desktop_prototype {
bool Requested(const std::vector<std::wstring>& arguments);
// Opt-in, native-only Stage A surface. Never reads credentials or launches Codex.
int Run(const std::vector<std::wstring>& arguments);
// Stage B: shares the Flutter engine's UI thread and receives normalized state.
bool ClaimMonitorInstance(bool request_exit = false);
bool AttachMonitor(HWND main_window, std::function<void(const std::string&)> action);
void PublishMonitor(const std::wstring& text, double remaining, bool stale,
                    bool paused, int64_t revision, int64_t attempts, int64_t failures,
                    const std::wstring& detail, const std::wstring& alert, int64_t alert_serial);
void DetachMonitor();
// Available only with the explicit --monitor-test-controls launch flag.
bool TriggerTestAlert();
}
#endif
