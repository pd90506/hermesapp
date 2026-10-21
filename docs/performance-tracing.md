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
| Text apply | interval | a message's text view takes new text or style (`MarkdownSelectionTextView.apply`); unchanged updates mark nothing |
| Text measure | interval | a message's text laid out for its height (`fittingHeight`), when the width or text changed |
| Text draw | interval | Mac only: a message's text view drawing (`draw(_:)`), e.g. as it scrolls into view |

HermesKit stays Foundation-only: it names its spans through `Tracing` (`WorkTracer`),
and the apps install the tracer that turns them into signposts (`AppSignposts`).

## Recording on the Mac

1. Open Instruments (Xcode ▸ Open Developer Tool ▸ Instruments) and pick **SwiftUI**: it
   has the SwiftUI instrument (long body updates, representable updates such as a
   message's text view), Time Profiler, Hangs and Hitches in one. Add **Points of
   Interest** from the library (+) for the signposts. **Time Profiler** alone also has
   the Points of Interest track; for freezes only, **Hangs**.
2. Choose Hermes as the target (attach to the running app), record, reproduce the
   slowdown, stop.
3. Read the Points of Interest track against the hitches, hangs and the main thread's
   samples: a long Markdown parse or Snapshot rebuild under a hang is the cause; a hang
   with no signpost in it points at layout or something not yet marked.

For a stuttering scroll: open a long chat, scroll it up and down for 10 to 20 seconds,
then look at the Hitches track. Under each hitch, the SwiftUI track says which views
updated and the Points of Interest track whether a message's text was rebuilt (Text
apply), laid out (Text measure) or drawn (Text draw). Text apply while only scrolling
means something re-ran the rows' bodies; many Text draw as rows come on screen points
at drawing.

From the command line, for 20 seconds of the running app:

```sh
xcrun xctrace record --template SwiftUI --instrument 'Points of Interest' --attach Hermes --time-limit 20s --output ~/Desktop/hermes-scroll.trace
open ~/Desktop/hermes-scroll.trace
```

A Debug build (what Xcode's Run makes) runs only the app's own code unoptimised; SwiftUI,
AppKit and the rest are the system's, the same in either. A trace whose time is mostly in
them reads the same from a Debug build (the stuttering scroll of 2026-10-21: the app's
own code was under 2% of the main thread).

## Recording on the iPhone

The iPhone's build is a development build, which Instruments can attach to. Connect
the paired iPhone (or have it on the same network), pick it and Hermes as the target in
Instruments, then record as on the Mac.
