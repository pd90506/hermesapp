#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "native_frame.h"

namespace {

flutter::EncodableValue Strings(const std::vector<std::string>& strings) {
  flutter::EncodableList list;
  for (const auto& s : strings) list.emplace_back(s);
  return flutter::EncodableValue(list);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

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
  native_frame::PassTitleBandThrough(flutter_controller_->view()->GetNativeWindow());
  native_frame::Apply(GetHandle());

  // The app's light/dark choice reaches the frame (Mica and the caption buttons).
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "talaria/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const std::string& method = call.method_name();
        if (method == "setTheme") {
          const auto* name = std::get_if<std::string>(call.arguments());
          native_frame::Theme theme = native_frame::Theme::kSystem;
          if (name && *name == "light") theme = native_frame::Theme::kLight;
          if (name && *name == "dark") theme = native_frame::Theme::kDark;
          native_frame::SetTheme(GetHandle(), theme);
          result->Success();
        } else if (method == "pickFiles") {
          result->Success(Strings(native_files::PickFiles(GetHandle())));
        } else if (method == "readClipboard") {
          const auto contents = native_files::ReadClipboard(GetHandle());
          flutter::EncodableMap map;
          map[flutter::EncodableValue("types")] = Strings(contents.types);
          map[flutter::EncodableValue("files")] = Strings(contents.files);
          if (contents.text) map[flutter::EncodableValue("text")] = flutter::EncodableValue(*contents.text);
          result->Success(flutter::EncodableValue(map));
        } else if (method == "readClipboardImage") {
          const auto* type = std::get_if<std::string>(call.arguments());
          auto bytes = native_files::ReadClipboardImage(GetHandle(), type ? *type : std::string());
          if (bytes.empty()) {
            result->Success();
          } else {
            result->Success(flutter::EncodableValue(std::move(bytes)));
          }
        } else {
          result->NotImplemented();
        }
      });

  // Files dragged from Explorer onto the window: the app highlights the composer while
  // they are over it and attaches them when dropped.
  drop_target_ = native_files::RegisterDropTarget(
      flutter_controller_->view()->GetNativeWindow(),
      [this](bool entered) {
        if (window_channel_) {
          window_channel_->InvokeMethod("dragChanged", std::make_unique<flutter::EncodableValue>(entered));
        }
      },
      [this](std::vector<std::string> paths) {
        if (window_channel_) {
          window_channel_->InvokeMethod("filesDropped", std::make_unique<flutter::EncodableValue>(Strings(paths)));
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_ && flutter_controller_->view()) {
    native_files::RevokeDropTarget(flutter_controller_->view()->GetNativeWindow(), drop_target_);
  }
  drop_target_ = nullptr;
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
