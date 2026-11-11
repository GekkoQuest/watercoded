# 0016: Give expanded tool text a stable viewport

**Status:** Accepted · 2026-11-11

## Evidence
The 09:19 Watercoded 0.15.1 hang report records 43.17 seconds of unresponsiveness and an
839.02 MB footprint. The main thread is doing SwiftUI graph updates, lazy-stack size
estimation and nested layout measurement. The user had expanded a shell tool card.
The matching output has 40 lines and 2,759 characters: huge output is not required.
The screenshot also shows output extending below its pane into the working indicator.

The old code pane is a selectable SwiftUI `Text` inside a vertical `ScrollView`, with only
`frame(maxHeight: 320)` bounding it. Its containing tool card animates expansion inside
the lazy transcript. Text wrapping, scroll-view sizing, lazy height estimates and animated
intermediate sizes therefore participate in the same layout negotiation. The earlier
scroll-following mitigation did not remove that structure.

## Decision
- Use a read-only, selectable TextKit 2 `NSTextView` inside an `NSScrollView` for tool text.
- Give SwiftUI an explicit, bounded viewport height based on hard lines. Never query the
  native document's fitting or intrinsic size to choose the transcript row's size.
- Let TextKit measure and scroll wrapped text within the native clip view. Resizing the
  window changes text wrapping without changing the pane's requested height.
- Make expansion discrete and suppress inherited animations on the card. Do not animate
  intermediate viewport sizes inside a lazy transcript.
- Keep expanded call IDs in transcript-owned observable state, rather than row-local state,
  so virtualizing a row cannot reset its disclosure state.
- Keep the existing display limit, Show all and full-text Copy behavior. Preserve selection
  and scroll position when output updates.

## Verification
The regression drives the same expansion action as the tool-card button in an 840-row
mixed transcript. It covers following output and inspecting an older row, repeated expansion
and collapse, streaming updates and width changes. It verifies that both inner scroll panes
are actually mounted. A separate check covers viewport bounds, selection across Unicode text,
output updates and scrolling to the end.

Run this suite only in an isolated environment. CI gives it its own process and external
watchdog; a layout deadlock must produce diagnostics and fail the job, not hang a release.
