# 172 — Timestamps in the chat transcript

## Problem

The transcript gives no sense of time. A user message, an assistant reply
and a tool call all render without a timestamp, so questions like "when did
I send this", "how long did the model take" and "when did this command
actually run" can only be answered on the PC.

Three facts make this more than a UI tweak:

- **The time already exists, the UI drops it.** Every persisted row has a
  `MessageRecord.ts`, but `toChatMessage()` never projects it, so the chat
  widgets receive nothing to render.
- **Two clocks are in play.** Live frames carry no time, so the app stamps
  arrival with the phone's clock. Replayed history uses the Pi's clock. With
  drift between the two, a reply can appear to precede the question.
- **A replayed tool call has the wrong time.** In history a `tool_request`
  event carries the LLM reply's timestamp, not the execution start. With
  parallel tool calls that run sequentially, the second call's shown time can
  be minutes before it actually ran.

The SDK already records what is needed: `ToolResultMessage.timestamp` (end)
plus `durationMs`, and `AssistantMessage.timestamp` (reply start). It may be
absent on legacy sessions, so every derivation needs a fallback.

## Decision (owner, 2026-11-24)

- **Tool card (expanded only)**: two lines under the command,
  `reply Tue 14:03:05` and `ran Tue 14:03:12 → 14:03:19 · 6.8s`.
  The collapsed row stays as it is. While running the second line reads
  `running since Tue 14:03:12 (6s)`, with a live elapsed counter.
- **Clock source**: the Pi stamps its live frames. The phone's clock is only
  the fallback for extensions that do not send a time.
- **Message stamps**: `14:03:12` with the day of week (`Tue 14:03:12`), under
  the user bubble and under the assistant reply.
- **Settings switch** "Show message timestamps", on by default. It hides the
  bubble stamps only; the timing inside an expanded tool card stays.

## Design

### Wire (pi-extension → app), all optional and backward compatible

| Frame | New fields | Meaning |
|---|---|---|
| `user_input` / `user_message` | `ts` | Pi clock when the input was accepted |
| `agent_chunk` | `ts` | Reply start: the SDK's assistant-message timestamp (same for every chunk of one LLM message) |
| `tool_request` | `ts`, `reply_ts` | `ts` = execution start. `reply_ts` = when the LLM reply that issued the call started |
| `tool_result` | `ts`, `duration_ms` | `ts` = execution end. `duration_ms` = wall time of `execute()` (monotonic), absent when the tool did not run |
| history `tool_result` | `duration_ms` | From `ToolResultMessage.durationMs`; absent on legacy sessions |

Unchanged on purpose:

- History `tool_request.ts` stays the assistant-message timestamp. The app
  already uses row `ts` for paging order and retention, so its meaning must
  not move.
- `agent_done` gets no `ts`. The reply end time is not displayed.

### App model

- `ChatMessage.ts` (`DateTime?`): when the row's event happened. Null only on
  synthetic messages (tests); persisted rows always carry one.
  - user: sent / accepted at. assistant: reply started at.
- `ToolEvent` gains `replyAt`, `startedAt`, `endedAt`, `durationMs` (nullable).
- `ToolEventData` persists them as `reply_at`, `started_at`, `ended_at`,
  `duration_ms`. Old rows decode with all four null.

### Derivation rules (live == replayed)

| Value | Live, new extension | Live, old extension | History |
|---|---|---|---|
| user `ts` | echo `ts` replaces the optimistic phone time | phone send time (kept) | `UserMessage.timestamp` |
| assistant `ts` | first chunk's `ts` | first chunk arrival | `AssistantMessage.timestamp` |
| tool `replyAt` | `reply_ts` | null | request event `ts` |
| tool `startedAt` | request `ts` | request arrival | `ts − duration_ms` when `duration_ms` exists, else null |
| tool `endedAt` | result `ts` | result arrival | result event `ts` |
| tool `durationMs` | `duration_ms` | `endedAt − startedAt` | `duration_ms` |

Why the echo overrides the optimistic time: one clock per transcript. The
optimistic row shows the phone's time only until the Pi confirms, so the
stamp can shift by the clock offset once, and then the whole transcript
agrees with itself.

Why `_mergeTool` never mixes sides: a live row and a replayed row for the same
tool call can be on different clocks (old extension). The merge takes the
timing set of whichever side is more complete, as a whole.

### Display

- `formatStamp`: last 7 days → `Tue 14:03:12`. Older → `Tue 24 Nov 14:03:12`
  (year added when it differs). Local time, English weekday abbreviations.
- `formatSpan`: `Tue 14:03:12 → 14:03:19`. The day is shown once when both
  ends share it.
- `formatDuration`: `412ms`, `6.8s`, `2m 05s`, `1h 03m`.
- Legacy tool rows (no timing fields) fall back to the plain row stamp.
- The card stacks its timing parts, one per line: with the weekday the two
  parts do not fit one line on a phone, and a soft wrap orphaned the
  duration.

## Implementation map

pi-extension:

- `extension-state.ts`: `assistantMsgTs`, `durationMs?` on `BufferMsg`.
- `index.ts`: `message_start` records the assistant-message timestamp before
  the peers gate (a later `tool_request` needs it).
- `main.ts`: `ts` on the input mirror and the echo; `ts` on `agent_chunk`
  (threaded through the coalescing window and the mid-run-attach head);
  `ts` + `reply_ts` on `tool_request`; `ts` + `duration_ms` on `tool_result`;
  `duration_ms` on replayed `tool_result` events.
- `protocol/types.ts`: field docs.
- Tests: frames carry the new fields; the history mapper emits `duration_ms`
  only when the SDK recorded one.

app:

- `protocol/protocol.dart`: parse the new optional fields.
- `domain/session_state.dart`: `ts`, tool timing fields, equality.
- `data/local/records/message_record.dart`: persist + project.
- `data/sync/sync_service.dart`: the derivation table above.
- `ui/chat/widgets/message_stamp.dart`: formatters (pure) + the stamp widget.
- `message_bubble.dart`, `tool_request_card.dart`: render.
- `chat_page.dart`: reads the preference and passes `showStamps` down.
- `data/preferences/preferences.dart`, `settings_page.dart`: the switch.
- Tests: formatters, bubbles, card, protocol parsing, record roundtrip, sync
  derivation (live with and without `ts`, replayed with and without
  `duration_ms`, echo override, merge without mixing).

## Steps with acceptance criteria

1. **Extension stamps live frames.** A `tool_request` carries `ts` and, when
   an assistant message is in flight, `reply_ts`; a `tool_result` carries `ts`
   and `duration_ms` when the SDK reported one.
2. **Extension replays `duration_ms`.** A session recorded by a current SDK
   yields `duration_ms` on `tool_result` history events; a legacy session
   yields none, and nothing else in the event changes.
3. **App parses and persists.** New fields decode when present and are null
   when absent. `ToolEventData` survives a JSON roundtrip with them.
4. **Sync derives timing per the table.** A live tool call seen with the new
   extension ends with start, end and duration on the Pi's clock. With an old
   extension the same call gets arrival-based times that are self-consistent.
   A replayed call gets `startedAt = ts − duration_ms`.
5. **Bubbles show stamps.** A user bubble and an assistant reply with a `ts`
   render `Tue 14:03:12` in muted text. A pending bubble keeps its label and
   adds the stamp. With the preference off, or `ts` null, nothing is added.
6. **Tool card shows timing only when expanded.** The collapsed row is
   byte-identical to today. The expanded card shows the timing under the
   command and above the outcome (invocation line, then run line), and ticks
   while running.
7. **Settings switch works.** Default on; toggling rebuilds the transcript
   without a restart; the value survives a restart.

## Limitations (accepted)

- Rows persisted before this release have no tool timing. They fall back to
  the plain stamp.
- With an old extension, live times come from the phone's clock and replayed
  times from the Pi's. The transcript is only guaranteed single-clock once
  the extension is updated.
- Agent image, file and compaction rows get no stamp in this plan. Their time
  is visible in the tool card that produced them.
- The elapsed counter of a running tool updates once per second while the
  card is expanded and mounted.

## DoD

1. `pnpm typecheck` and `pnpm test` pass in `pi-extension`.
2. `flutter analyze` reports 0 issues and `flutter test` passes in `app`.
3. New tests cover every row of the derivation table and both card states.
4. `PROTOCOL.md` documents the new fields and the compatibility matrix.
5. CHANGELOG entry under Unreleased in `app/assets/CHANGELOG.md` and the root
   `CHANGELOG.md`.

## Next plans

- Stamps on agent image, file and compaction rows, if wanted after using this.
- Reply duration under an assistant reply (`AssistantMessage.durationMs` is
  already on the wire for history).
- Day separators between messages of different days.

## Deployment

- **PC**: rebuild the extension. Sessions started before the rebuild keep
  sending unstamped live frames; the app falls back to arrival time.
- **App**: needs a release. The two sides are independently deployable.
