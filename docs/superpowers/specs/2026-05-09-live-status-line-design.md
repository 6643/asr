# Live Status Line Design

## Goal
Replace multi-line session logs with a single live status line per voice session. The line starts with a microphone icon, updates in place while recognition is running, and switches to a check mark when IBus commit succeeds.

## Scope
- Show one live line for each session.
- Use a microphone icon at session start.
- Update the same line for interim and final ASR text.
- Replace the icon with a check mark after successful IBus commit.
- Show an error icon only when recognition or commit fails.
- Remove separate session-start, session-finished, and response-count log lines from the normal path.

## Non-goals
- Do not change ASR engine behavior.
- Do not change IBus transport behavior.
- Do not change hotkey handling.
- Do not change microphone capture or device discovery.

## Output Shape
Example flow:
`2026-05-09 03:30:14 🎤 语音实时识别`
`2026-05-09 03:30:18 🎤 你好, 测试一下`
`2026-05-09 03:30:22 ✅ 你好, 测试一下`

## Implementation Plan
- Add a shared runtime helper that renders a timestamped, single-line, overwriteable status row.
- Route `printInterim`, `printFinal`, commit success, and failure through that helper.
- Remove the separate session-start/session-finished/session-end prints from the runtime flow.
- Keep engine selection and keyboard device reporting as one-time startup lines.

## Verification
- `bun tsc --noEmit`
- `bun test src/runtime/ibus.test.ts src/runtime/ibus-select.test.ts src/runtime/key.test.ts src/runtime/key-grab.test.ts src/util.test.ts`
- Run `bun run index.ts` and confirm a single live session line updates in place.
