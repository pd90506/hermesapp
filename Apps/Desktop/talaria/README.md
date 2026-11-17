# Talaria for Windows

The Windows desktop app: a Flutter UI in Windows 11's look (Mica, Fluent controls, the
caption buttons Windows draws) over the shared Swift core, `HermesKit`, which it reaches
through `HermesBridge.dll` (`docs/desktop-bridge.md`).

- Build: `scripts/windows/Build-Desktop.ps1` from the repo root. It builds the bridge, the
  app, and puts the Swift and VC++ runtimes beside `talaria.exe`.
- Try it in the UI-test VM, never on the host's screen:
  `scripts/windows-test-vm/Invoke-AppInVM.ps1 -OutDir <dir>`.
- Layout: `lib/app` (state and settings, no views), `lib/platform` (the Win32 calls, through
  `dart:ffi`), `lib/ui` (views), `windows/runner/native_frame.cpp` (the window frame).

See AGENTS.md, "Windows host", for the rules.
