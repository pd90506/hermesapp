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

## Markdown renderer (Electron desktop app)

The renderer bundles **streamdown** and **@streamdown/math** (Apache-2.0, Copyright
Vercel, Inc.), **shiki** (MIT, Copyright Pine Wu and Anthony Fu) and **KaTeX** with its
fonts (MIT, Copyright Khan Academy and other contributors); the full license texts are in
each package's LICENSE file. `features/markdown/highlight.ts` takes its Shiki themes and the light
comment colour fix from the official Hermes Desktop's `shiki-config.ts` (hermes-agent,
MIT, see above).

## System notifications (Electron desktop app)

`Apps/Desktop/electron/src/main/ipc/notifications.ts` adapts the official Hermes Desktop's
`electron/notification-ipc.ts` and `notification-registry.ts` (hermes-agent, commit
`caafe5389a`, MIT, see above): holding each notification until it is clicked or 10 minutes
pass, the one-second de-duplication, and flashing the window's taskbar entry until it is
focused.

## Widgets in replies (Electron desktop app)

`Apps/Desktop/electron/src/renderer/features/chat/blocks/media/widget-frame.ts` and
`Embeds.tsx` adapt the official Hermes Desktop's `inline-preview-directive.tsx`, and
`Packages/hermes-core/src/media/directives.ts` its `transcript-directives.ts` (hermes-agent,
commit `3b1ce49a`, MIT, see above): the `::preview` frame's theme prelude, size report,
`hermes.send` script and limits, and how directives are read. The widget page's content
policy in `src/main/ipc/embeds.ts` is the one in `hermes_cli/webapp_previews.py`.

## Lucide icons (Electron desktop app)

`Apps/Desktop/electron/src/renderer/ui/Icon.tsx` draws its `settings` and `sidebar` icons with
the paths of Lucide's `settings` and `panel-left` (lucide-static 0.577.0, the version official
Hermes Desktop pins as lucide-react), under the ISC license:

```
ISC License

Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2026 as part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors 2026.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
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
