#include "window_chrome.h"
#include "resource.h"
#include <propkey.h>
#include <propsys.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <dwmapi.h>
#include <iostream>
#include <vector>

namespace {
int checks = 0, failures = 0;
void Check(bool value, const char* name) {
  ++checks;
  if (!value) { ++failures; std::cerr << "FAIL: " << name << '\n'; }
}
std::wstring Property(HWND hwnd, const PROPERTYKEY& key, VARTYPE* type = nullptr) {
  IPropertyStore* store = nullptr;
  if (FAILED(SHGetPropertyStoreForWindow(hwnd, IID_PPV_ARGS(&store)))) return L"";
  PROPVARIANT value{};
  const auto hr = store->GetValue(key, &value);
  std::wstring text;
  if (SUCCEEDED(hr) && value.vt == VT_LPWSTR && value.pwszVal) text = value.pwszVal;
  if (type) *type = value.vt;
  PropVariantClear(&value);
  store->Release();
  return text;
}
}  // namespace

int main() {
  using namespace window_chrome;
  Check(ArgbToColorRef(0xff123456) == RGB(0x12, 0x34, 0x56), "ARGB red/blue channel conversion");
  Check(ArgbToColorRef(0x07123456) == RGB(0x12, 0x34, 0x56), "alpha never becomes COLORREF channel");
  const Appearance light{false, 0xfff5f6f8, 0xff202833, 0xffdce1e7};
  const Appearance dark{true, 0xff14171c, 0xffe4e9f0, 0xff353c47};
  struct Call { DWORD attribute; DWORD value; };
  std::vector<Call> calls;
  AppearanceController controller([&](HWND, DWORD attribute, const void* value, DWORD size) {
    Check(size == sizeof(DWORD), "native DWM argument has DWORD size");
    calls.push_back({attribute, *static_cast<const DWORD*>(value)});
    return attribute == 35 ? E_INVALIDARG : S_OK;
  });
  Check(!controller.Reapply(nullptr), "no explicit palette permits system fallback");
  const auto result = controller.Apply(nullptr, light);
  Check(calls.size() == 4, "all independent attributes attempted despite unsupported caption");
  Check(result.dark == S_OK && result.caption == E_INVALIDARG && result.text == S_OK && result.border == S_OK,
        "checked partial HRESULTs preserved");
  if (calls.size() == 4) {
    Check(calls[0].attribute == 20 && calls[0].value == FALSE, "light dark-mode BOOL");
    Check(calls[1].attribute == 35 && calls[1].value == RGB(245,246,248), "caption uses palette RGB");
    Check(calls[2].attribute == 36 && calls[2].value == RGB(32,40,51), "text uses palette RGB");
    Check(calls[3].attribute == 34 && calls[3].value == RGB(220,225,231), "border uses palette RGB");
  }
  controller.Apply(nullptr, light);
  Check(calls.size() == 4, "identical explicit palette deduplicated");
  Check(controller.Reapply(nullptr) && calls.size() == 8, "DWM colorization forces cached explicit palette");
  controller.Apply(nullptr, dark);
  Check(calls.size() == 12 && calls[8].value == TRUE, "explicit dark supersedes system fallback");
  AppearanceController unsupported([](HWND,DWORD,const void*,DWORD){return E_INVALIDARG;});
  Check(unsupported.Apply(nullptr, dark).Status() == "unsupported", "unsupported DWM safely reported");

  const auto metadata = BuildRelaunchMetadata(L"C:\\Owned App\\launcher.exe");
  Check(metadata.command == L"\"C:\\Owned App\\launcher.exe\"", "relaunch quotes only own EXE with no inherited arguments");
  Check(metadata.display_resource == L"@C:\\Owned App\\launcher.exe,-103", "display uses owned indirect string resource");
  Check(metadata.icon_resource == L"C:\\Owned App\\launcher.exe,-101", "icon uses owned resource without @");
  Check(BuildRelaunchMetadata(L"bad\"path.exe").command.empty(), "invalid quote rejected rather than shell injected");
  std::vector<DWORD> written;
  bool empty_cleanup = true;
  const auto fixture = reinterpret_cast<HWND>(static_cast<INT_PTR>(123));
  const auto identity = WriteWindowIdentity(fixture, metadata,
      [&](HWND hwnd, const PROPERTYKEY& key, const wchar_t* value) {
        Check(hwnd == fixture, "identity writer receives exact supplied HWND");
        written.push_back(key.pid);
        Check(value != nullptr, "identity values present");
        return key.pid == 3 ? E_ACCESSDENIED : S_OK;
      });
  Check(written == std::vector<DWORD>({2,4,3,5}), "relaunch metadata precedes window AppID");
  Check(identity.icon == E_ACCESSDENIED && identity.id == S_OK, "identity reports per-property failure");
  written.clear();
  ClearWindowIdentity(fixture, [&](HWND hwnd, const PROPERTYKEY& key, const wchar_t* value) {
    empty_cleanup = empty_cleanup && hwnd == fixture && value == nullptr;
    written.push_back(key.pid); return S_OK;
  });
  Check(empty_cleanup && written.size() == 4, "cleanup clears all four owned properties on real supplied handle");

  // Match runner startup: process Shell identity is set before COM/UI setup.
  Check(SUCCEEDED(InitializeProcessIdentity()), "own test process explicit AppID initialized");
  const auto com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  PWSTR app_id = nullptr;
  const auto process_read = GetCurrentProcessExplicitAppUserModelID(&app_id);
  Check(SUCCEEDED(process_read) && app_id && std::wstring(app_id) == kAppUserModelId, "process own identity readback");
  CoTaskMemFree(app_id);
  const auto hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"Owned hidden chrome fixture", WS_POPUP,
                                    0,0,1,1,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  Check(hwnd != nullptr && !IsWindowVisible(hwnd), "fixture HWND exists and is never shown");
  if (hwnd) {
    const auto own = SetOwnWindowIdentity(hwnd);
    Check(SUCCEEDED(own.id), "own HWND AppID accepted");
    Check(Property(hwnd,PKEY_AppUserModel_ID) == kAppUserModelId, "window owns stable AppID");
    const auto command = Property(hwnd,PKEY_AppUserModel_RelaunchCommand);
    Check(command.size()>2 && command.front() == L'"' && command.back() == L'"', "actual HWND relaunch command quotes only executable");
    Check(command.find(L"bootstrap") == std::wstring::npos, "no transient bootstrap arguments in actual relaunch command");
    const auto diagnostic = DescribeWindow(hwnd);
    Check(diagnostic.find("\"processIdMatches\":true") != std::string::npos &&
          diagnostic.find("\"windowIdMatches\":true") != std::string::npos, "bounded own-window identity diagnostics");
    Check(diagnostic.find("C:\\") == std::string::npos, "diagnostics omit private executable paths");
    const auto actual=ApplyAppearance(hwnd,dark);
    Check(actual.Status()!="failed", "actual DWM applies or gracefully reports unsupported support");
    for (const auto& probe : std::vector<std::pair<DWORD,std::pair<HRESULT,COLORREF>>>{
        {35,{actual.caption,ArgbToColorRef(dark.caption_argb)}},
        {36,{actual.text,ArgbToColorRef(dark.text_argb)}},
        {34,{actual.border,ArgbToColorRef(dark.border_argb)}}}) {
      if (SUCCEEDED(probe.second.first)) {
        COLORREF value=0;
        const auto read=DwmGetWindowAttribute(hwnd,probe.first,&value,sizeof(value));
        std::cout << "DWM attribute " << probe.first << " set=" << probe.second.first << " read=" << read
                  << " value=" << value << " expected=" << probe.second.second << '\n';
        Check(SUCCEEDED(read) ? value==probe.second.second :
              (read==E_INVALIDARG || read==E_NOTIMPL || read==HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED)),
              "Set-only DWM color readback is exact when supported and safely unsupported otherwise");
        if (FAILED(read) && probe.first==35) {
          Check(DescribeWindow(hwnd).find("\"captionColorRef\":null")!=std::string::npos,
                "unsupported DWM getter reports null actual color instead of fabricated zero");
        }
      }
    }
    ReleaseWindow(hwnd);
    Check(!ReapplyAppearance(hwnd), "window cache removed before HWND reuse");
    for (const auto* key : {&PKEY_AppUserModel_ID,&PKEY_AppUserModel_RelaunchCommand,
                            &PKEY_AppUserModel_RelaunchDisplayNameResource,&PKEY_AppUserModel_RelaunchIconResource}) {
      VARTYPE type = VT_LPWSTR;
      Property(hwnd,*key,&type);
      Check(type == VT_EMPTY, "owned Shell property cleared before actual HWND destruction");
    }
    Check(IsWindow(hwnd), "cleanup operated on live HWND before destruction");
    DestroyWindow(hwnd);
  }
  Check(ApplyAppearance(nullptr,light).dark==E_HANDLE,"invalid HWND safely rejected");
  for (const auto resource : {IDI_APP_ICON,IDI_TRAY_ICON}) {
    for (const auto size : {16,20,32,256}) {
      const auto icon=reinterpret_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr),MAKEINTRESOURCEW(resource),IMAGE_ICON,size,size,0));
      Check(icon!=nullptr,"original app/tray icon resource loads at small and large sizes");
      if (icon) DestroyIcon(icon);
    }
  }
  wchar_t display[64]{};
  Check(LoadStringW(GetModuleHandleW(nullptr),IDS_APP_NAME,display,64)>0 && std::wstring(display)==L"Codex 时区启动器",
        "relaunch display resolves owned string resource");
  if (SUCCEEDED(com)) CoUninitialize();
  std::cout << checks << " checks, " << failures << " failures\n";
  return failures ? 1 : 0;
}
