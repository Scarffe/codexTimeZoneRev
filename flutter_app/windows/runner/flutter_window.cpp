#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "desktop_prototype.h"
#include <flutter/standard_method_codec.h>
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool monitor)
    : project_(project), monitor_(monitor) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  {
    monitor_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        flutter_controller_->engine()->messenger(), "codex_timezone/monitor",
        &flutter::StandardMethodCodec::GetInstance());
    if(!desktop_prototype::AttachMonitor(GetHandle(),[this](const std::string& action) {
      if(action=="exit" && !bridge_ready_) {
        exiting_=true; PostMessageW(GetHandle(),WM_CLOSE,0,0); return;
      }
      monitor_channel_->InvokeMethod(action,nullptr);
    },monitor_)) return false;
    monitor_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      if(call.method_name()=="roleEditor") { const auto* flag=std::get_if<bool>(call.arguments()); if(flag) desktop_prototype::SetRoleEditorOpen(*flag); result->Success(); return; }
      if(call.method_name()=="mainVisible") { desktop_prototype::ReportMonitorState(); result->Success(flutter::EncodableValue(IsWindowVisible(GetHandle()) && !IsIconic(GetHandle()))); return; }
      if(call.method_name()=="exit") {
        exiting_=true; result->Success(); PostMessageW(GetHandle(),WM_CLOSE,0,0); return;
      }
      if(call.method_name()=="hide") { close_pending_=false; desktop_prototype::HideMonitorMain(); result->Success(); return; }
      if(call.method_name()=="publish") {
        const auto* map=std::get_if<flutter::EncodableMap>(call.arguments());
        if(!map) { result->Error("invalid_snapshot","Expected map"); return; }
        const auto value=[&](const char* key)->flutter::EncodableValue {
          auto found=map->find(flutter::EncodableValue(key)); return found==map->end()?flutter::EncodableValue():found->second;
        };
        const auto number=[&](const char* key)->int64_t {
          auto v=value(key); if(auto p=std::get_if<int64_t>(&v)) return *p;
          if(auto p=std::get_if<int32_t>(&v)) return *p; return 0;
        };
        auto text=value("text"), remain=value("remaining"), stale=value("stale"), paused=value("paused");
        auto caption=std::get_if<std::string>(&text); auto percent=std::get_if<double>(&remain);
        auto old=std::get_if<bool>(&stale), stopped=std::get_if<bool>(&paused);
        if(!caption || !percent || !old || !stopped) { result->Error("invalid_snapshot","Missing fields"); return; }
        const int n=MultiByteToWideChar(CP_UTF8,0,caption->data(),static_cast<int>(caption->size()),nullptr,0);
        std::wstring wide(n,L'\0'); MultiByteToWideChar(CP_UTF8,0,caption->data(),static_cast<int>(caption->size()),wide.data(),n);
        const auto wideField=[&](const char* key) {
          auto v=value(key); auto p=std::get_if<std::string>(&v); if(!p) return std::wstring();
          int length=MultiByteToWideChar(CP_UTF8,0,p->data(),static_cast<int>(p->size()),nullptr,0);
          std::wstring w(length,L'\0'); MultiByteToWideChar(CP_UTF8,0,p->data(),static_cast<int>(p->size()),w.data(),length); return w;
        };
        auto sessionRate=value("sessionRate");
        const auto* rate=std::get_if<double>(&sessionRate);
        auto workspace=value("workspace");
        const auto* page=std::get_if<std::string>(&workspace);
        desktop_prototype::ConfigureWorkspace(value("keepAlive")==flutter::EncodableValue(true),page?*page:"launcher");
        bridge_ready_=true;
        desktop_prototype::ConfigureSessionSummary(wideField("sessionSummary"),rate ? *rate : -1.0, static_cast<int>(number("sessionStatus")));
        desktop_prototype::ConfigureRole(wideField("roleImage"),wideField("roleName"));
        auto visible=value("petVisible");
        if(auto flag=std::get_if<bool>(&visible)) desktop_prototype::ConfigureMonitor(
          static_cast<int>(number("petMode")),*flag,number("preferencesSerial"));
        desktop_prototype::PublishMonitor(wide,*percent,*old,*stopped,number("revision"),number("attempts"),number("failures"),wideField("detail"),wideField("alert"),number("alertSerial"),
          value("reducedMotion")==flutter::EncodableValue(true),static_cast<int>(number("animationState")));
        desktop_prototype::ConfigureSessionAlert(wideField("sessionAlert"),number("sessionAlertSerial"));
        result->Success(); return;
      }
      result->NotImplemented();
    });
  }

  // Set both icon sizes on the runner and Flutter's child HWND. Shell tools
  // and overlay utilities may inspect either window rather than the EXE icon.
  const auto instance = GetModuleHandle(nullptr);
  const auto large_icon = reinterpret_cast<HICON>(LoadImage(
      instance, MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_SHARED));
  const auto small_icon = reinterpret_cast<HICON>(LoadImage(
      instance, MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  for (HWND handle : {GetHandle(), flutter_controller_->view()->GetNativeWindow()}) {
    SendMessage(handle, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(large_icon));
    SendMessage(handle, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small_icon));
    SetClassLongPtr(handle, GCLP_HICON, reinterpret_cast<LONG_PTR>(large_icon));
    SetClassLongPtr(handle, GCLP_HICONSM, reinterpret_cast<LONG_PTR>(small_icon));
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if(!monitor_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Win32Window::Create calls Destroy before OnCreate. The instance lock must
  // survive that initial cleanup; only tear down an attached monitor channel.
  if(monitor_channel_) desktop_prototype::DetachMonitor();
  monitor_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if(monitor_channel_ && (message==WM_SHOWWINDOW || message==WM_SIZE)) {
    bool visible=IsWindowVisible(hwnd) && !IsIconic(hwnd);
    if(message==WM_SHOWWINDOW) visible=wparam!=0 && !IsIconic(hwnd);
    if(message==WM_SIZE && wparam==SIZE_MINIMIZED) visible=false;
    monitor_channel_->InvokeMethod(visible ? "mainShown" : "mainHidden",nullptr);
  }
  if(message==WM_CLOSE && monitor_channel_ && !exiting_ && bridge_ready_) {
    if(!close_pending_) {
      close_pending_=true; desktop_prototype::RecordCloseRequest();
      monitor_channel_->InvokeMethod("closeRequested",nullptr);
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
