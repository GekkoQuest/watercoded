# 0015: Bound the changes inspector's rendered content

**Status:** Accepted · 2026-11-11

## Context
macOS recorded a Watercoded 0.15.0 hang with footprint growth from 17.87 GB to 26.76 GB.
The main thread was in AppKit/SwiftUI layout and native view removal, ending in Auto Layout
constraint removal (`NSISEngine removeConstraintWithMarker:`). An earlier CPU report recorded
16.67 GB and 70% average CPU usage over 129 seconds.

The changes inspector automatically expanded files. A lazy outer list held eager stacks of hunks,
each containing a selectable view for every line. A generated zone JSON in the investigated session
had 15,349 added lines. Virtualizing files did not virtualize the contents of that one file.

An isolated reproduction used a read-only copy of that patch and an offscreen window on the same
Mac. No provider was started. A background watchdog terminated the test above 700,000,000 bytes,
with a separate 40-second process timeout. The old renderer grew from about 92 MB to 729 MB before
completing its first resize/render cycle and was stopped by the watchdog. The replacement stayed
around 102 MB, with 78 native views, through 100 resize/update cycles on the identical input.
Short transcript-only streaming and image-browsing runs remained below about 211 MB. These tests
identify a reproducible eager-allocation defect; they do not establish whether an additional
object-retention leak contributed to the original 27 GB incident.

## Decision
- Each expanded file has a bounded, vertically scrollable preview.
- Flatten hunk headers and individual lines into stable row identities inside one `LazyVStack`.
  Do not place an eager per-hunk stack behind an otherwise lazy file row.
- Retain all patch data, line selection, hunk comments, questions and revert actions. Provide
  **Copy change** on hunk headers for copying an entire hunk across virtualized rows.
- Do not replace inspector state when polling returns an unchanged diff.
- Keep a synthetic 20,000-line UI regression that checks native view counts before and after
  resizing and scrolling to the end. Its watchdog also stops future accidental eager allocation
  while the main thread is blocked.

## Related recovery issue
The same incident exposed false **Needs You** entries. Idle background agents that had already
finished their turns were treated as failed tasks when they exited. Session exit now requests
attention only when it interrupts work. A narrow migration repairs historical exit errors when
saved history ends with a completed assistant response and a completed turn snapshot; unfinished
turns and other errors retain their failure status. The original diagnostic text is kept as an
informational transcript notice.

## Consequences
Large generated files remain fully readable without mounting thousands of native text views.
Users scroll within a file's preview; full-hunk copying uses the header's context menu. The UI
bound does not truncate or alter patches used for revert operations.

## Subsequent new-session crash
The 0.15.1 crash at 04:21 on November 11 was a separate AppKit constraint-update failure.
The system log says the window requested more constraint-update passes than it had views;
the backtrace includes `LazyLayoutViewCache.invalidateSize` during `NSHostingView.layout`.
The user had started another session shortly beforehand. The preceding observation measured
roughly 210–256 MB, with a 296 MB peak, and found all 69 checked completed tool calls persisted.
Those observations do not establish that every memory or recovery issue is resolved.

The transcript's content-size observer scheduled another bottom scroll on every lazy height
refinement, alongside automatic bottom anchoring for size changes and short-content alignment.
Remove those competing adjustments: short content uses top alignment, and geometry requests a
correction only when the viewport leaves the bottom. Explicit content and width changes still
schedule following, while user scrolling and question navigation retain their opt-out.

This is a mitigation for the layout feedback path, not a confirmed reproduction of the recorded
crash. A new-session streaming test passed before the mitigation; the final UI change has not
been executed alongside the user's live app. Future verification must use an isolated environment.

The separate macOS disk-write report attributes about 2.15 GB over 1,005 seconds to the Codex
agent process, with SQLite in its sampled stacks. It does not establish a Watercoded persistence
loop or swap writes. No provider settings or user databases were changed for that finding.
