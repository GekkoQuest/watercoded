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
