# Performance tracing

The apps mark their heavy work with signposts (`OSSignposter`, the Points of Interest
category), so Instruments shows when it ran and for how long, beside the stalls and
the call stacks it records. Nothing is collected while nothing records: a signpost then
costs one check. Nothing leaves the device but what you record yourself.

## The signposts

| Name | Kind | Where |
|---|---|---|
| Markdown parse | interval | `MarkdownDocument(parsing:)`: a reply's Markdown, also each streamed delta |
| Transcript grouping | interval | `TranscriptGrouping.blocks`: the rows into turns and their work |
| History page | interval | `Transcript.installLatestPage`, `prependOlderPage`, `installRereadPage` |
| Snapshot rebuild | interval | `ChatSession` building its transcript from a session's snapshot |
| Math typeset | interval | `MathRenderer`: a formula typeset by SwiftMath (cached afterwards) |
| Chat selected | event | the sidebar's selection changes: where a chat switch starts |

HermesKit stays Foundation-only: it names its spans through `Tracing` (`WorkTracer`),
and the apps install the tracer that turns them into signposts (`AppSignposts`).

## Recording on the Mac

1. Open Instruments (Xcode ▸ Open Developer Tool ▸ Instruments) and pick **Time
   Profiler**; it has the Points of Interest track. For scrolling, **Animation
   Hitches**; for freezes, **Hangs**. Add the **os_signpost** instrument to any of
   them, or use the Points of Interest track it already has.
2. Choose Hermes as the target (attach to the running app), record, reproduce the
   slowdown, stop.
3. Read the Points of Interest track against the hitches, hangs and the main thread's
   samples: a long Markdown parse or Snapshot rebuild under a hang is the cause; a hang
   with no signpost in it points at layout or something not yet marked.

From the command line, for 30 seconds of the running app:

```sh
xcrun xctrace record --template 'Time Profiler' --attach Hermes --time-limit 30s --output hermes.trace
open hermes.trace
```

## Recording on the iPhone

The iPhone's build is a development build, which Instruments can attach to. Connect
the paired iPhone (or have it on the same network), pick it and Hermes as the target in
Instruments, then record as on the Mac.
