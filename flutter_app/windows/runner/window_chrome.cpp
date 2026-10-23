#include "window_chrome.h"
#include "resource.h"
#include <dwmapi.h>
#include <propkey.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <map>
#include <sstream>

namespace window_chrome {
namespace {
// Numeric attributes retain compatibility with older Windows SDK headers.
// Windows 11 build 22000+ documents the three explicit COLORREF attributes.
constexpr DWORD kDarkMode=20, kBorderColor=34, kCaptionColor=35, kTextColor=36;
struct WindowRecord {
  AppearanceController appearance;
  IdentityResult identity;
};
// The runner and monitor callbacks share one UI thread; no worker owns HWNDs.
std::map<HWND,WindowRecord> windows;
HRESULT process_identity = E_PENDING;

std::wstring ExecutablePath() {
  wchar_t path[32768]{};
  const DWORD size=GetModuleFileNameW(nullptr,path,static_cast<DWORD>(std::size(path)));
  if (!size || size>=std::size(path)) return {};
  return std::wstring(path,size);
}

HRESULT SetProperty(HWND hwnd,const PROPERTYKEY& key,const wchar_t* text) {
  IPropertyStore* store=nullptr;
  const HRESULT opened=SHGetPropertyStoreForWindow(hwnd,IID_PPV_ARGS(&store));
  if (FAILED(opened)) return opened;
  PROPVARIANT value{};
  if (text) {
    value.vt=VT_LPWSTR;
    // SetValue copies immediately. This is a borrowed pointer, not CoTaskMem.
    value.pwszVal=const_cast<wchar_t*>(text);
  }
  const HRESULT result=store->SetValue(key,value);
  // Window stores apply immediately; Commit is neither needed nor effective.
  store->Release();
  return result;
}

std::wstring ReadProperty(HWND hwnd,const PROPERTYKEY& key) {
  IPropertyStore* store=nullptr;
  if (FAILED(SHGetPropertyStoreForWindow(hwnd,IID_PPV_ARGS(&store)))) return {};
  PROPVARIANT value{};
  std::wstring result;
  if (SUCCEEDED(store->GetValue(key,&value)) && value.vt==VT_LPWSTR && value.pwszVal)
    result=value.pwszVal;
  PropVariantClear(&value);
  store->Release();
  return result;
}

bool Owned(HWND hwnd) {
  DWORD pid=0;
  return hwnd && IsWindow(hwnd) && GetWindowThreadProcessId(hwnd,&pid) && pid==GetCurrentProcessId();
}

const char* JsonBool(bool value) { return value ? "true" : "false"; }
}  // namespace

bool Appearance::operator==(const Appearance& other) const {
  return dark==other.dark && caption_argb==other.caption_argb &&
      text_argb==other.text_argb && border_argb==other.border_argb;
}

std::string AppearanceResult::Status() const {
  const int supported=static_cast<int>(SUCCEEDED(dark))+static_cast<int>(SUCCEEDED(caption))+
      static_cast<int>(SUCCEEDED(text))+static_cast<int>(SUCCEEDED(border));
  if (supported==4) return "applied";
  if (supported>0) return "partial";
  const auto unsupported=[](HRESULT result) {
    return result==E_INVALIDARG || result==E_NOTIMPL || result==HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
  };
  return unsupported(dark) && unsupported(caption) && unsupported(text) && unsupported(border)
      ? "unsupported" : "failed";
}

AppearanceController::AppearanceController(DwmSetter setter):setter_(std::move(setter)) {
  if (!setter_) setter_=[](HWND hwnd,DWORD attribute,const void* value,DWORD size) {
    return DwmSetWindowAttribute(hwnd,attribute,value,size);
  };
}

AppearanceResult AppearanceController::Apply(HWND hwnd,const Appearance& appearance) {
  if (!appearance_ || !(*appearance_==appearance)) {
    appearance_=appearance;
    Reapply(hwnd);
  }
  return result_;
}

bool AppearanceController::Reapply(HWND hwnd) {
  if (!appearance_) return false;
  const auto& palette=*appearance_;
  const BOOL dark=palette.dark ? TRUE : FALSE;
  const COLORREF caption=ArgbToColorRef(palette.caption_argb);
  const COLORREF text=ArgbToColorRef(palette.text_argb);
  const COLORREF border=ArgbToColorRef(palette.border_argb);
  // Independent calls: one unsupported attribute must not suppress the others.
  result_.dark=setter_(hwnd,kDarkMode,&dark,sizeof(dark));
  result_.caption=setter_(hwnd,kCaptionColor,&caption,sizeof(caption));
  result_.text=setter_(hwnd,kTextColor,&text,sizeof(text));
  result_.border=setter_(hwnd,kBorderColor,&border,sizeof(border));
  return true;
}

COLORREF ArgbToColorRef(std::uint32_t argb) {
  return RGB((argb>>16)&0xff,(argb>>8)&0xff,argb&0xff);
}

RelaunchMetadata BuildRelaunchMetadata(const std::wstring& executable) {
  // Construct exclusively from GetModuleFileNameW, never GetCommandLineW.
  // Quotes/control characters cannot be part of a valid own EXE resource path.
  if (executable.empty() || executable.find_first_of(L"\"\r\n")!=std::wstring::npos ||
      executable.find(L'\0')!=std::wstring::npos) return {};
  return {L"\""+executable+L"\"",L"@"+executable+L",-"+std::to_wstring(IDS_APP_NAME),
          executable+L",-"+std::to_wstring(IDI_APP_ICON)};
}

IdentityResult WriteWindowIdentity(HWND hwnd,const RelaunchMetadata& metadata,PropertySetter setter) {
  if (!setter) setter=SetProperty;
  if (metadata.command.empty() || metadata.display_resource.empty() || metadata.icon_resource.empty())
    return {E_INVALIDARG,E_INVALIDARG,E_INVALIDARG,E_INVALIDARG};
  IdentityResult result;
  // Shell requires relaunch command/display together; set all before AppID.
  result.command=setter(hwnd,PKEY_AppUserModel_RelaunchCommand,metadata.command.c_str());
  result.display=setter(hwnd,PKEY_AppUserModel_RelaunchDisplayNameResource,metadata.display_resource.c_str());
  result.icon=setter(hwnd,PKEY_AppUserModel_RelaunchIconResource,metadata.icon_resource.c_str());
  result.id=setter(hwnd,PKEY_AppUserModel_ID,kAppUserModelId);
  return result;
}

IdentityResult ClearWindowIdentity(HWND hwnd,PropertySetter setter) {
  if (!setter) setter=SetProperty;
  // nullptr means VT_EMPTY, removing only properties explicitly owned by us.
  return {setter(hwnd,PKEY_AppUserModel_RelaunchCommand,nullptr),
          setter(hwnd,PKEY_AppUserModel_RelaunchDisplayNameResource,nullptr),
          setter(hwnd,PKEY_AppUserModel_RelaunchIconResource,nullptr),
          setter(hwnd,PKEY_AppUserModel_ID,nullptr)};
}

HRESULT InitializeProcessIdentity() {
  process_identity=SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);
  return process_identity;
}

IdentityResult SetOwnWindowIdentity(HWND hwnd) {
  if (!Owned(hwnd)) return {E_HANDLE,E_HANDLE,E_HANDLE,E_HANDLE};
  auto result=WriteWindowIdentity(hwnd,BuildRelaunchMetadata(ExecutablePath()));
  windows[hwnd].identity=result;
  return result;
}

AppearanceResult ApplyAppearance(HWND hwnd,const Appearance& appearance) {
  if (!Owned(hwnd)) return {E_HANDLE,E_HANDLE,E_HANDLE,E_HANDLE};
  return windows[hwnd].appearance.Apply(hwnd,appearance);
}

bool ReapplyAppearance(HWND hwnd) {
  const auto found=windows.find(hwnd);
  return found!=windows.end() && found->second.appearance.Reapply(hwnd);
}

void ReleaseWindow(HWND hwnd) {
  if (Owned(hwnd) && windows.find(hwnd)!=windows.end()) ClearWindowIdentity(hwnd);
  windows.erase(hwnd);
}

std::string DescribeWindow(HWND hwnd) {
  if (!Owned(hwnd)) return "{\"owned\":false}";
  PWSTR process_id=nullptr;
  const auto process_read=GetCurrentProcessExplicitAppUserModelID(&process_id);
  const bool process_match=SUCCEEDED(process_read) && process_id && std::wstring(process_id)==kAppUserModelId;
  CoTaskMemFree(process_id);
  const auto metadata=BuildRelaunchMetadata(ExecutablePath());
  const auto found=windows.find(hwnd);
  const WindowRecord* record=found==windows.end()?nullptr:&found->second;
  const auto expected=record?record->appearance.appearance():std::optional<Appearance>{};
  COLORREF caption=0xffffffff,text=0xffffffff,border=0xffffffff;
  const auto caption_read=DwmGetWindowAttribute(hwnd,kCaptionColor,&caption,sizeof(caption));
  const auto text_read=DwmGetWindowAttribute(hwnd,kTextColor,&text,sizeof(text));
  const auto border_read=DwmGetWindowAttribute(hwnd,kBorderColor,&border,sizeof(border));
  const auto applied=record?record->appearance.result():AppearanceResult{};
  const auto identity=record?record->identity:IdentityResult{};
  std::ostringstream out;
  out << "{\"owned\":true,\"appId\":\"Scarffe.CodexTimeZone.Launcher\""
      << ",\"processIdHresult\":" << process_identity << ",\"processReadHresult\":" << process_read
      << ",\"processIdMatches\":" << JsonBool(process_match)
      << ",\"windowIdMatches\":" << JsonBool(ReadProperty(hwnd,PKEY_AppUserModel_ID)==kAppUserModelId)
      << ",\"windowIdHresult\":" << identity.id
      << ",\"relaunchCommandHresult\":" << identity.command << ",\"relaunchDisplayHresult\":" << identity.display
      << ",\"relaunchIconHresult\":" << identity.icon
      << ",\"relaunchCommandSanitized\":" << JsonBool(!metadata.command.empty() && ReadProperty(hwnd,PKEY_AppUserModel_RelaunchCommand)==metadata.command)
      << ",\"relaunchDisplayOwned\":" << JsonBool(ReadProperty(hwnd,PKEY_AppUserModel_RelaunchDisplayNameResource)==metadata.display_resource)
      << ",\"relaunchIconOwned\":" << JsonBool(ReadProperty(hwnd,PKEY_AppUserModel_RelaunchIconResource)==metadata.icon_resource)
      << ",\"appIconResource\":" << IDI_APP_ICON
      << ",\"largeWindowIcon\":" << JsonBool(SendMessageW(hwnd,WM_GETICON,ICON_BIG,0)!=0)
      << ",\"smallWindowIcon\":" << JsonBool(SendMessageW(hwnd,WM_GETICON,ICON_SMALL,0)!=0)
      << ",\"appearanceRequested\":" << JsonBool(expected.has_value())
      << ",\"status\":\"" << (expected?applied.Status():"uninitialized") << "\""
      << ",\"darkHresult\":" << applied.dark << ",\"captionHresult\":" << applied.caption
      << ",\"textHresult\":" << applied.text << ",\"borderHresult\":" << applied.border
      // These attributes are documented as Set-only. A failed getter is unknown,
      // never a fabricated actual color; retain its HRESULT for the report.
      << ",\"captionColorRef\":" << (SUCCEEDED(caption_read)?std::to_string(caption):"null")
      << ",\"textColorRef\":" << (SUCCEEDED(text_read)?std::to_string(text):"null")
      << ",\"borderColorRef\":" << (SUCCEEDED(border_read)?std::to_string(border):"null")
      << ",\"captionReadHresult\":" << caption_read << ",\"textReadHresult\":" << text_read << ",\"borderReadHresult\":" << border_read;
  if (expected) out << ",\"dark\":" << JsonBool(expected->dark)
      << ",\"requestedCaptionArgb\":" << expected->caption_argb
      << ",\"requestedTextArgb\":" << expected->text_argb
      << ",\"requestedBorderArgb\":" << expected->border_argb
      << ",\"requestedCaptionColorRef\":" << ArgbToColorRef(expected->caption_argb)
      << ",\"requestedTextColorRef\":" << ArgbToColorRef(expected->text_argb)
      << ",\"requestedBorderColorRef\":" << ArgbToColorRef(expected->border_argb);
  out << '}';
  return out.str();
}
}  // namespace window_chrome
