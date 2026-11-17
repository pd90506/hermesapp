#include "native_files.h"

#include <ole2.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <cstring>

#include "utils.h"

namespace native_files {

namespace {

// Releases a COM pointer when it goes out of scope.
template <typename T>
struct ComPtr {
  T* p = nullptr;
  ~ComPtr() {
    if (p) p->Release();
  }
  T** operator&() { return &p; }
  T* operator->() { return p; }
};

std::vector<std::string> PathsOf(HDROP drop) {
  std::vector<std::string> paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT length = DragQueryFileW(drop, i, nullptr, 0);
    std::wstring path(length + 1, L'\0');
    DragQueryFileW(drop, i, path.data(), length + 1);
    path.resize(length);
    paths.push_back(Utf8FromUtf16(path.c_str()));
  }
  return paths;
}

// The clipboard, open for one read; closed however the read ends.
struct OpenClipboardScope {
  bool open;
  explicit OpenClipboardScope(HWND owner) : open(OpenClipboard(owner) != 0) {}
  ~OpenClipboardScope() {
    if (open) CloseClipboard();
  }
};

std::vector<uint8_t> GlobalBytes(HANDLE handle) {
  std::vector<uint8_t> bytes;
  if (!handle) return bytes;
  const SIZE_T size = GlobalSize(handle);
  const void* data = GlobalLock(handle);
  if (data && size > 0) bytes.assign(static_cast<const uint8_t*>(data), static_cast<const uint8_t*>(data) + size);
  if (data) GlobalUnlock(handle);
  return bytes;
}

// A DIB (CF_DIB) as a .bmp file: the file header in front, its pixels' offset after
// the info header, the colour masks and the colour table.
std::vector<uint8_t> BmpFromDib(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return {};
  BITMAPINFOHEADER info;
  std::memcpy(&info, dib.data(), sizeof(info));
  DWORD offset = info.biSize;
  if (info.biSize == sizeof(BITMAPINFOHEADER) && info.biCompression == BI_BITFIELDS) offset += 3 * sizeof(DWORD);
  if (info.biBitCount <= 8) offset += (info.biClrUsed ? info.biClrUsed : (1u << info.biBitCount)) * sizeof(RGBQUAD);
  BITMAPFILEHEADER file = {};
  file.bfType = 0x4D42;  // "BM"
  file.bfSize = static_cast<DWORD>(sizeof(file) + dib.size());
  file.bfOffBits = static_cast<DWORD>(sizeof(file) + offset);
  std::vector<uint8_t> bmp(sizeof(file));
  std::memcpy(bmp.data(), &file, sizeof(file));
  bmp.insert(bmp.end(), dib.begin(), dib.end());
  return bmp;
}

UINT Format(const wchar_t* name) { return RegisterClipboardFormatW(name); }

}  // namespace

std::vector<std::string> PickFiles(HWND owner) {
  std::vector<std::string> paths;
  ComPtr<IFileOpenDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
    return paths;
  }
  FILEOPENDIALOGOPTIONS options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST | FOS_FORCEFILESYSTEM);
  dialog->SetTitle(L"Attach files");
  if (FAILED(dialog->Show(owner))) return paths;  // Cancelled.
  ComPtr<IShellItemArray> items;
  if (FAILED(dialog->GetResults(&items))) return paths;
  DWORD count = 0;
  items->GetCount(&count);
  for (DWORD i = 0; i < count; ++i) {
    ComPtr<IShellItem> item;
    if (FAILED(items->GetItemAt(i, &item))) continue;
    PWSTR path = nullptr;
    if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
      paths.push_back(Utf8FromUtf16(path));
      CoTaskMemFree(path);
    }
  }
  return paths;
}

ClipboardContents ReadClipboard(HWND owner) {
  ClipboardContents contents;
  OpenClipboardScope clipboard(owner);
  if (!clipboard.open) return contents;
  if (IsClipboardFormatAvailable(CF_HDROP)) {
    contents.types.push_back("public.file-url");
    if (HANDLE handle = GetClipboardData(CF_HDROP)) contents.files = PathsOf(static_cast<HDROP>(handle));
  }
  if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    contents.types.push_back("public.utf8-plain-text");
    if (HANDLE handle = GetClipboardData(CF_UNICODETEXT)) {
      if (const auto* text = static_cast<const wchar_t*>(GlobalLock(handle))) {
        contents.text = Utf8FromUtf16(text);
        GlobalUnlock(handle);
      }
    }
  }
  if (IsClipboardFormatAvailable(Format(L"HTML Format"))) contents.types.push_back("public.html");
  if (IsClipboardFormatAvailable(Format(L"PNG"))) contents.types.push_back("public.png");
  if (IsClipboardFormatAvailable(Format(L"JFIF"))) contents.types.push_back("public.jpeg");
  if (IsClipboardFormatAvailable(Format(L"GIF"))) contents.types.push_back("com.compuserve.gif");
  if (IsClipboardFormatAvailable(CF_DIB)) contents.types.push_back("com.microsoft.bmp");
  return contents;
}

std::vector<uint8_t> ReadClipboardImage(HWND owner, const std::string& type) {
  OpenClipboardScope clipboard(owner);
  if (!clipboard.open) return {};
  if (type == "com.microsoft.bmp") return BmpFromDib(GlobalBytes(GetClipboardData(CF_DIB)));
  const wchar_t* name = type == "public.png"           ? L"PNG"
                        : type == "public.jpeg"        ? L"JFIF"
                        : type == "com.compuserve.gif" ? L"GIF"
                                                       : nullptr;
  if (!name) return {};
  return GlobalBytes(GetClipboardData(Format(name)));
}

// --- Drag and drop -------------------------------------------------------------------

class DropTarget : public IDropTarget {
 public:
  DropTarget(std::function<void(bool)> on_drag, std::function<void(std::vector<std::string>)> on_drop)
      : on_drag_(std::move(on_drag)), on_drop_(std::move(on_drop)) {}

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *object = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG refs = InterlockedDecrement(&refs_);
    if (refs == 0) delete this;
    return refs;
  }

  // IDropTarget: only files (CF_HDROP), copied, never moved.
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL, DWORD* effect) override {
    has_files_ = HasFiles(data);
    *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    if (has_files_) on_drag_(true);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (has_files_) on_drag_(false);
    has_files_ = false;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL, DWORD* effect) override {
    *effect = DROPEFFECT_NONE;
    if (has_files_) on_drag_(false);
    has_files_ = false;
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium = {};
    if (FAILED(data->GetData(&format, &medium))) return S_OK;
    if (auto drop = static_cast<HDROP>(GlobalLock(medium.hGlobal))) {
      auto paths = PathsOf(drop);
      GlobalUnlock(medium.hGlobal);
      if (!paths.empty()) {
        *effect = DROPEFFECT_COPY;
        on_drop_(std::move(paths));
      }
    }
    ReleaseStgMedium(&medium);
    return S_OK;
  }

 private:
  static bool HasFiles(IDataObject* data) {
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    return data && data->QueryGetData(&format) == S_OK;
  }

  LONG refs_ = 1;
  bool has_files_ = false;
  std::function<void(bool)> on_drag_;
  std::function<void(std::vector<std::string>)> on_drop_;
};

DropTarget* RegisterDropTarget(HWND window, std::function<void(bool)> on_drag,
                               std::function<void(std::vector<std::string>)> on_drop) {
  auto* target = new DropTarget(std::move(on_drag), std::move(on_drop));
  if (FAILED(RegisterDragDrop(window, target))) {
    target->Release();
    return nullptr;
  }
  return target;
}

void RevokeDropTarget(HWND window, DropTarget* target) {
  if (!target) return;
  RevokeDragDrop(window);
  target->Release();
}

}  // namespace native_files
