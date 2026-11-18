#ifndef RUNNER_NATIVE_FRAME_H_
#define RUNNER_NATIVE_FRAME_H_

#include <windows.h>

#include <optional>
#include <vector>

// The window as Windows 11 apps that extend into the title bar draw it
// (WinUI's ExtendsContentIntoTitleBar): Mica behind the whole window, no caption
// bar of its own, the app's content from the top edge, and the caption buttons
// drawn by Windows itself (DWM), so they keep Snap Layouts and the system's look.
namespace native_frame {

// The app's title band, in logical pixels: empty space in it moves the window.
constexpr int kTitleBandHeight = 48;
// The band's leading controls (the pane toggle, Back), which take clicks.
constexpr int kTitleBandLeadingControls = 48;

// The app's light/dark choice; System follows Windows.
enum class Theme { kSystem, kLight, kDark };

// Mica, the frame extended over the client area, the caption dropped.
void Apply(HWND window);

// Applies the light/dark choice to the frame (Mica's tint and the caption buttons).
void SetTheme(HWND window, Theme theme);

// Re-applies the current choice; called when Windows' theme changes.
void UpdateTheme(HWND window);

// The top-level window's messages that make the frame: the caption buttons
// (DwmDefWindowProc), the client area (WM_NCCALCSIZE) and hit-testing.
std::optional<LRESULT> HandleMessage(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

// Lets the title band's empty space reach the top-level window: the Flutter view
// covers the client area and would otherwise take every click.
void PassTitleBandThrough(HWND flutter_view);

// The app's controls inside the title band past its leading ones (New chat), in
// logical pixels of the client area: they take clicks rather than move the window.
void SetBandControls(std::vector<RECT> rects);

}  // namespace native_frame

#endif  // RUNNER_NATIVE_FRAME_H_
