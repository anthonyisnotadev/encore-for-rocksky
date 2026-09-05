#include "flutter_window.h"

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "spotify_smtc.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

// Converts a wide string to a UTF-8 std::string for use with Flutter.
static std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                 static_cast<int>(wide.size()),
                                 nullptr, 0, nullptr, nullptr);
  if (size == 0) return {};
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

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

  // Register the Spotify SMTC platform channel.
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "encore/spotify_smtc",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "getCurrentTrack") {
          auto track = GetSpotifyCurrentTrack();
          if (track.has_value()) {
            flutter::EncodableMap map;
            map[flutter::EncodableValue("title")] =
                flutter::EncodableValue(WideToUtf8(track->title));
            map[flutter::EncodableValue("artist")] =
                flutter::EncodableValue(WideToUtf8(track->artist));
            map[flutter::EncodableValue("album")] =
                flutter::EncodableValue(WideToUtf8(track->album));
            map[flutter::EncodableValue("is_playing")] =
                flutter::EncodableValue(track->is_playing);
            map[flutter::EncodableValue("position_ms")] =
                flutter::EncodableValue(track->position_ms);
            map[flutter::EncodableValue("duration_ms")] =
                flutter::EncodableValue(track->duration_ms);
            if (!track->art.empty()) {
              map[flutter::EncodableValue("art")] =
                  flutter::EncodableValue(track->art);
            }
            result->Success(flutter::EncodableValue(map));
          } else {
            result->Success(flutter::EncodableValue());  // null → nothing playing
          }
        } else if (call.method_name() == "controlPlayback") {
          auto* args = call.arguments();
          if (args != nullptr &&
              std::holds_alternative<std::string>(*args)) {
            bool ok = SpotifyControl(std::get<std::string>(*args));
            result->Success(flutter::EncodableValue(ok));
          } else {
            result->Error("bad_args", "Expected string action");
          }
        } else {
          result->NotImplemented();
        }
      });
  // Keep channel alive for the lifetime of the window.
  smtc_channel_ = std::move(channel);

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
