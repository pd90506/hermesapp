# Third-party notices

## Hermes Desktop app icon

`Apps/Shared/AppIcon.icon` is adapted from `apps/desktop/assets/icon.icon` in
[hermes-agent](https://github.com/NousResearch/hermes-agent) (commit `c0ef5af520`), under its MIT license. Changed: the dark-mode art and fill are used in every appearance. The Electron app's
`Apps/Desktop/electron/resources/icon.ico` and `icon.png` are rendered from the same art
(`scripts/make-icons.py`).

```
MIT License

Copyright (c) 2025 Nous Research

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## SwiftMath

See AGENTS.md, "Dependencies" (MIT, used by the app targets).

## Hermes gateway contract types

`Packages/hermes-core/src/protocol/contract.generated.ts` is generated from
`apps/shared/src/gateway-contract.openrpc.json` in
[hermes-agent](https://github.com/NousResearch/hermes-agent) (commit `31ce88f`), under the MIT
license quoted above for the app icon (Copyright (c) 2025 Nous Research).

## deepseek-harness

The Electron app's structure follows patterns from
[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness): platform differences kept
in the shell, frame geometry as CSS variables, design tokens with a stylesheet scan. No code,
fonts or brand assets are copied from it. It is under the MIT license, Copyright (c) 2026
DeepSeek.

## Electron app dependencies

See AGENTS.md, "Dependencies" (the Electron desktop app's npm packages).
