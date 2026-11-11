# 0014: Durable session checkpoints and separate attachments

**Status:** Accepted · 2026-11-11

## Context
Long sessions accumulate large image attachments and relay logs. Saving metadata used to rewrite the
whole transcript, including base64 images. The relay's byte reader could also advance ahead of the
controller; persisting that position separately from the transcript could skip events after a quit
or crash.

## Decision
- Providers deliver the normalized events from one relay output record and that record's end offset
  as one batch. The controller applies both synchronously. Saves use this applied boundary, never
  the reader's potentially newer offset. Cancelling consumption on quit leaves queued records unread
  from the durable checkpoint's perspective.
- `current.json` remains the versioned session envelope. Optional `transcriptFile` and `streamingText`
  fields point to an immutable `transcript-<uuid>.json` and retain a partial assistant message.
  New transcript files and their attachments are written first, then an atomic manifest replacement
  publishes the transcript, session metadata and replay boundary together. The previous transcript
  is removed only after publication. Unpublished files from interrupted saves are ignored.
- Attachments live under each session's `attachments/<sha256>` and transcript entries retain their
  original image IDs, filenames and media types. Repeated saves reuse existing bytes. Missing image
  files fail transcript loading rather than silently dropping attachments.
- Existing `transcript.json` envelopes with embedded images remain readable and migrate on the next
  transcript save. Metadata-only saves retain the existing transcript reference. Domain transcript
  values still contain attachment bytes for branching, exports and replay recording.
- Transcript revisions drive writes; streaming and metadata saves reuse the immutable transcript.
  Progress is checkpointed at most every two seconds during a continuous stream, with the existing
  400 ms coalescing for explicit user actions and turn completion.
- Relay restoration streams only the saved prefix. An unread-byte check uses file size, avoiding a
  second full decode of the log.

## Consequences
A crash before manifest publication restores the previous complete checkpoint; a crash afterward
restores the new one. Orphaned unpublished transcripts and unreferenced attachments may remain after
an interrupted save until their session is deleted. Downgrading to a version that does not understand
`transcriptFile` requires restoring a pre-migration backup.

Regression tests cover queued output, partial messages, immutable transcript references, embedded-image
migration, image round trips, and replay limits across multi-byte UTF-8 and chunk boundaries.
