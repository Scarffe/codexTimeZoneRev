#ifndef RUNNER_WINDOW_CHROME_H_
#define RUNNER_WINDOW_CHROME_H_
#include <windows.h>
#include <propsys.h>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

namespace window_chrome {
inline constexpr wchar_t kAppUserModelId[] = L"Scarffe.CodexTimeZone.Launcher";
struct Appearance {
  bool dark;
  std::uint32_t caption_argb, text_argb, border_argb;
  bool operator==(const Appearance& other) const;
};
struct AppearanceResult {
  HRESULT dark = E_NOTIMPL, caption = E_NOTIMPL, text = E_NOTIMPL, border = E_NOTIMPL;
  std::string Status() const;
};
using DwmSetter = std::function<HRESULT(HWND,DWORD,const void*,DWORD)>;
class AppearanceController {
 public:
  explicit AppearanceController(DwmSetter setter = {});
  AppearanceResult Apply(HWND hwnd, const Appearance& appearance);
  bool Reapply(HWND hwnd);
  const std::optional<Appearance>& appearance() const { return appearance_; }
  const AppearanceResult& result() const { return result_; }
 private:
  DwmSetter setter_;
  std::optional<Appearance> appearance_;
  AppearanceResult result_;
};
COLORREF ArgbToColorRef(std::uint32_t argb);
struct RelaunchMetadata { std::wstring command, display_resource, icon_resource; };
struct IdentityResult { HRESULT command=E_NOTIMPL, display=E_NOTIMPL, icon=E_NOTIMPL, id=E_NOTIMPL; };
using PropertySetter = std::function<HRESULT(HWND,const PROPERTYKEY&,const wchar_t*)>;
RelaunchMetadata BuildRelaunchMetadata(const std::wstring& executable);
IdentityResult WriteWindowIdentity(HWND hwnd, const RelaunchMetadata& metadata, PropertySetter setter = {});
IdentityResult ClearWindowIdentity(HWND hwnd, PropertySetter setter = {});
HRESULT InitializeProcessIdentity();
IdentityResult SetOwnWindowIdentity(HWND hwnd);
AppearanceResult ApplyAppearance(HWND hwnd, const Appearance& appearance);
bool ReapplyAppearance(HWND hwnd);
void ReleaseWindow(HWND hwnd);
// Explicit-report diagnostics: only own HWND statuses, colors and stable AppID.
std::string DescribeWindow(HWND hwnd);
}  // namespace window_chrome
#endif
