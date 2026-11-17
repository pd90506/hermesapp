#ifndef RUNNER_NATIVE_FILES_H_
#define RUNNER_NATIVE_FILES_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

// Files into the composer, the Windows way: the system's Open dialog, a drag from
// Explorer (OLE drag and drop), and what Copy put on the clipboard. Paths are UTF-8.
namespace native_files {

// The Open dialog (IFileOpenDialog), several files at a time. Empty when cancelled.
std::vector<std::string> PickFiles(HWND owner);

// What the clipboard holds, as the composer's paste decides on it (HermesKit's
// ClipboardPolicy): its formats as uniform type identifiers, its text, its files.
struct ClipboardContents {
  std::vector<std::string> types;
  std::optional<std::string> text;
  std::vector<std::string> files;
};
ClipboardContents ReadClipboard(HWND owner);

// The clipboard's image in `type` ("public.png", "public.jpeg", "com.compuserve.gif"
// or "com.microsoft.bmp", a BMP file built from the DIB). Empty when it has none.
std::vector<uint8_t> ReadClipboardImage(HWND owner, const std::string& type);

// Drags of files over the window: `on_drag` with true as one enters and false as it
// leaves or drops, `on_drop` with the dropped paths. Needs OLE (OleInitialize).
class DropTarget;
DropTarget* RegisterDropTarget(HWND window, std::function<void(bool)> on_drag,
                               std::function<void(std::vector<std::string>)> on_drop);
void RevokeDropTarget(HWND window, DropTarget* target);

}  // namespace native_files

#endif  // RUNNER_NATIVE_FILES_H_
