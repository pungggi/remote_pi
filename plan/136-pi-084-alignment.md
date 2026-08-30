# Plan 136 — Pi 0.84.4 alignment bundle (small items)

## Context

Leftovers from reading the [0.84.4 release notes](https://pi.dev/news/releases/0.84.4)
that don't merit their own plans. Bundled because each is small and all are
"align with the host SDK" work. The installed SDK is already 0.84.4.

## Task A — Adopt `detectSupportedImageMimeTypeFromFile()`

0.84.4 exported it to the public library API ([#8600](https://github.com/earendil-works/pi/pull/8600),
`dist/index.d.ts:34`, from `utils/mime.ts`).

- `pi-extension/src/images/codec.ts` `mimeFromPathAndMagic` (~131) is our hand-rolled
  extension+magic-byte resolver with a jpeg/png/gif/webp whitelist; `pipeline.ts` uses
  it for the `show_image` outbound whitelist (~326).
- Swap to the SDK helper for the **outbound** path (what we're willing to broadcast +
  claim as supported), keeping our codec helpers for the **inbound** phone path
  (`decodeImagePayload`, dimension parsing) which the SDK helper doesn't cover.
- Check which formats the SDK helper accepts vs ours (e.g. BMP): if it whitelists more,
  `show_image` gains them for free — update the tool's error string ("use jpeg/png/
  webp/gif") and the parameter description accordingly. If it accepts something the
  phone viewer can't render, constrain back down and note why.
- Mirror the same helper in **pi-multimodal-proxy** (separate package) so routing
  decisions match the host's notion of "supported image" — own repo, own release.

**Acceptance:** `show_image` tests green (`show_image.test.ts`); new cases for any
format delta; `pnpm --dir pi-extension typecheck && test` green.

## Task B — Respect terminal capability overrides

0.84.4 added overrides ([#8665](https://github.com/earendil-works/pi/issues/8665)):
`PI_HYPERLINKS=1|0|auto`, `PI_IMAGE_PROTOCOL=kitty|iterm2|none|auto`,
`PI_TRUE_COLOR=1|0|auto` (+ `terminal.hyperlinks/images/trueColor` settings, which take
precedence).

- `registerReceivedImageRenderer` (`pi-extension/src/images/pipeline.ts` ~683) renders
  inline previews via pi-tui's `Image` with a metadata-only fallback. **Verify** pi-tui's
  `Image` already honors `PI_IMAGE_PROTOCOL=none` (expected — pi core uses the same
  component). If it does, add a regression test and stop; if not, check the override
  ourselves before constructing `Image` and render the fallback box.
- No OSC 8 emission exists in the extension today (`enrichToolArgs` emits diffs, not
  links) — nothing to gate. Note it here so nobody adds hyperlinks later without
  checking `PI_HYPERLINKS`.

**Acceptance:** with `PI_IMAGE_PROTOCOL=none`, a received-image message renders the
metadata fallback (test or documented verification).

## Task C — Regression coverage for two upstream fixes

- **#8537** (`triggerTurn:false` ordering): extension messages sent mid-tool-run used
  to be inserted between a tool call and its result, making providers reject replayed
  history. Our mesh `agent_send` deliveries are exactly this shape. Add a vitest case:
  message delivered while a tool result is pending lands **after** the tool result in
  the replayed order (guards against regressions when we bump SDK versions).
- **#8345** (JSONL trailing newline): resumed sessions no longer corrupt the next
  appended entry. Our readers (`session_sync` buffer, and pi-session-finder's parsing
  in its own repo) must tolerate files **with and without** a trailing newline
  regardless of which pi version wrote them. Add tolerance tests; audit for anywhere we
  assume a final `\n`.

**Acceptance:** both regression tests present and green.

## Task D — Follow-ups outside this repo (no code here)

- **pi-harness-model-proposer**: add `deepseek-v4-flash-vision-exp` (0.84.4's
  experimental vision model) to the proposal catalog for vision-capable harness work.
  One-line-ish change, own release per the packages AGENTS.md flow.
- **pi-schedule** (idea, low priority): skip or defer firing a scheduled prompt while a
  blocking `ctx.ui` prompt is open (`ui_prompt_start`/`end` from plan 134) — a prompt
  landing mid-dialog either queues behind it anyway or gets lost in the modal.
- pi-posh-git / pi-smart-terminal: nothing actionable in 0.84.4.

## DoD

- A–C landed with tests green across `pi-extension` (and the relay/app untouched).
- Task D issues opened in the respective package repos.

## Next plans

- 134 (waiting-for-input state) and 135 (stop-clears-queue) carry the actual feature
  weight of 0.84.4; this plan is the alignment tail.
