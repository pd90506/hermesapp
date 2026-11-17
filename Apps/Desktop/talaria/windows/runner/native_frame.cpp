#include "native_frame.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

namespace native_frame {

namespace {

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
// DWMSBT_MAINWINDOW: Mica, the backdrop of Windows 11's own app windows.
constexpr int kMica = 2;

Theme g_theme = Theme::kSystem;

bool SystemUsesDarkMode() {
  DWORD light = 1;
  DWORD size = sizeof(light);
  RegGetValue(HKEY_CURRENT_USER,
              L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
              L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
  return light == 0;
}

double ScaleOf(HWND window) { return GetDpiForWindow(window) / 96.0; }

// The resize border's thickness, which a maximized window hangs off the screen by.
int FrameThickness(HWND window) {
  const UINT dpi = GetDpiForWindow(window);
  return GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

LRESULT CALLBACK FlutterViewProc(HWND view, UINT message, WPARAM wparam,
                                 LPARAM lparam, UINT_PTR, DWORD_PTR) {
  if (message == WM_NCHITTEST) {
    POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(view, &point);
    const double scale = ScaleOf(view);
    if (point.y < kTitleBandHeight * scale &&
        point.x >= kTitleBandLeadingControls * scale) {
      // The top-level window answers: a caption button, the top resize edge,
      // or the caption (drag, double-click to maximize, the system menu).
      return HTTRANSPARENT;
    }
  }
  return DefSubclassProc(view, message, wparam, lparam);
}

}  // namespace

void Apply(HWND window) {
  MARGINS margins = {-1, -1, -1, -1};
  DwmExtendFrameIntoClientArea(window, &margins);
  int backdrop = kMica;
  DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop,
                        sizeof(backdrop));
  UpdateTheme(window);
  // Recompute the frame now that WM_NCCALCSIZE drops the caption.
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER);
}

void SetTheme(HWND window, Theme theme) {
  g_theme = theme;
  UpdateTheme(window);
}

void UpdateTheme(HWND window) {
  BOOL dark = g_theme == Theme::kDark ||
              (g_theme == Theme::kSystem && SystemUsesDarkMode());
  DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark,
                        sizeof(dark));
}

std::optional<LRESULT> HandleMessage(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
  // The caption buttons DWM draws: their hover, press and hit-testing. Only the
  // non-client mouse messages go to DWM: given WM_ACTIVATE too, it answers it, and the
  // runner never moves the keyboard focus to the Flutter view.
  const bool caption_mouse =
      message == WM_NCHITTEST || message == WM_NCMOUSEMOVE ||
      message == WM_NCMOUSEHOVER || message == WM_NCMOUSELEAVE ||
      (message >= WM_NCLBUTTONDOWN && message <= WM_NCMBUTTONDBLCLK);
  LRESULT result = 0;
  if (caption_mouse && DwmDefWindowProc(window, message, wparam, lparam, &result)) {
    return result;
  }
  switch (message) {
    case WM_NCCALCSIZE: {
      if (!wparam) break;
      auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      const LONG top = params->rgrc[0].top;
      // The side and bottom resize borders, as Windows computes them.
      DefWindowProc(window, message, wparam, lparam);
      // No caption: the client area starts at the window's top, except when
      // maximized, where the window hangs off the screen by its border.
      params->rgrc[0].top = top + (IsZoomed(window) ? FrameThickness(window) : 0);
      return 0;
    }
    case WM_NCHITTEST: {
      const LRESULT hit = DefWindowProc(window, message, wparam, lparam);
      if (hit != HTCLIENT) return hit;
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(window, &point);
      const double scale = ScaleOf(window);
      if (!IsZoomed(window) && point.y < FrameThickness(window)) return HTTOP;
      if (point.y < kTitleBandHeight * scale) return HTCAPTION;
      return HTCLIENT;
    }
  }
  return std::nullopt;
}

void PassTitleBandThrough(HWND flutter_view) {
  SetWindowSubclass(flutter_view, FlutterViewProc, 1, 0);
}

}  // namespace native_frame
