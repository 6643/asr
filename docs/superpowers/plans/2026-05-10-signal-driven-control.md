# Signal Driven Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make hotkeys emit control signals only, then let one controller drive session start/stop, while keeping mic warm and preserving immediate IBus commit on `final`.

**Architecture:** The keyboard layer only produces `start` and `stop` signals. A small controller owns the active session state, starts and stops recognition sessions, and never lets hotkey handling talk directly to mic or IBus. The mic becomes a shared warm source with a short pre-roll buffer, so a new session can consume cached audio first and then live audio without re-spawning `arecord`.

**Tech Stack:** Bun, TypeScript, existing runtime/session/engine modules, current test suite under `src/runtime/*.test.ts` and `src/engines/doubao/*.test.ts`.

---

### Task 1: Add a signal controller for hotkey events

**Files:**
- Create: `src/runtime/control.ts`
- Modify: `src/runtime/app.ts`
- Test: `src/runtime/control.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";
import { createControlLoop } from "./control.ts";

test("control loop ignores duplicate start while active and ignores stop when idle", async () => {
    const events: string[] = [];
    const controller = createControlLoop({
        startSession: async () => {
            events.push("startSession");
            return {
                stop: async () => events.push("stopSession"),
            };
        },
    });

    await controller.signal("start");
    await controller.signal("start");
    await controller.signal("stop");
    await controller.signal("stop");

    expect(events).toEqual(["startSession", "stopSession"]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/runtime/control.test.ts -v`
Expected: FAIL because `createControlLoop` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```ts
export type ControlSignal = "start" | "stop" | "shutdown";

export interface ActiveSessionHandle {
    stop: () => Promise<void>;
}

export const createControlLoop = (deps: {
    startSession: () => Promise<ActiveSessionHandle>;
}) => {
    let active: ActiveSessionHandle | null = null;
    let starting = false;

    const signal = async (event: ControlSignal): Promise<void> => {
        if (event === "shutdown") {
            if (active !== null) {
                await active.stop();
                active = null;
            }
            return;
        }

        if (event === "start") {
            if (active !== null || starting) return;
            starting = true;
            try {
                active = await deps.startSession();
            } finally {
                starting = false;
            }
            return;
        }

        if (active !== null) {
            await active.stop();
            active = null;
        }
    };

    return { signal };
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/runtime/control.test.ts -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/control.ts src/runtime/control.test.ts src/runtime/app.ts
git commit -m "feat: add hotkey signal controller"
```

### Task 2: Keep mic warm and expose pre-roll audio to sessions

**Files:**
- Modify: `src/runtime/mic.ts`
- Create: `src/runtime/mic.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";
import { createAudioBuffer } from "./audio-buffer.ts";

test("audio buffer replays recent frames before live frames", async () => {
    const buffer = createAudioBuffer(2);
    buffer.push(new Uint8Array([1]));
    buffer.push(new Uint8Array([2]));
    buffer.push(new Uint8Array([3]));

    const seen: number[] = [];
    for await (const chunk of buffer.stream()) {
        seen.push(chunk[0]!);
        if (seen.length === 3) break;
    }

    expect(seen).toEqual([2, 3, 3]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/runtime/mic.test.ts -v`
Expected: FAIL until the shared mic buffer contract is finalized.

- [ ] **Step 3: Write minimal implementation**

```ts
export const primeSharedMic = (options?: { sampleRate?: number; channels?: number }): Promise<void>;
export const getSharedMicStream = (options?: { sampleRate?: number; channels?: number }): {
    stream: AsyncGenerator<Uint8Array>;
    stop: () => void;
    started: Promise<void>;
};
```

Keep `arecord` in a shared singleton. Keep the pre-roll buffer in `src/runtime/audio-buffer.ts`. Do not reintroduce per-session mic startup.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/runtime/mic.test.ts src/runtime/session-runner.test.ts -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/mic.ts src/runtime/audio-buffer.ts src/runtime/mic.test.ts
git commit -m "feat: keep mic warm across sessions"
```

### Task 3: Wire the controller into runtime startup

**Files:**
- Modify: `src/runtime/app.ts`
- Modify: `src/runtime/session-runner.ts`
- Modify: `src/runtime/output.ts`
- Test: `src/runtime/app.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";
import { scheduleSessionAbort } from "./app.ts";

test("release schedules delayed stop instead of stopping immediately", async () => {
    const controller = new AbortController();
    const timer = scheduleSessionAbort(controller, null, 20);
    expect(controller.signal.aborted).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(controller.signal.aborted).toBe(true);
    clearTimeout(timer);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/runtime/app.test.ts -v`
Expected: FAIL if the controller is not wired, or if release still stops immediately.

- [ ] **Step 3: Write minimal implementation**

```ts
const control = createControlLoop({
    startSession: async () => {
        const abort = new AbortController();
        const task = runRecognitionSession(engine, client, abort.signal, options);
        return {
            stop: async () => abort.abort(),
        };
    },
});
```

Hotkey `press` should call `control.signal("start")`. Hotkey `release` should call `control.signal("stop")`. `runRecognitionSession` should consume the shared mic stream and keep the existing `final -> commitText()` behavior unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/runtime/app.test.ts src/runtime/session-runner.test.ts -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/app.ts src/runtime/session-runner.ts src/runtime/output.ts src/runtime/app.test.ts
git commit -m "feat: route hotkeys through a control loop"
```

### Task 4: Update documentation and verify the full runtime path

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-05-10-signal-driven-control-design.md` if any scope drift is discovered

- [ ] **Step 1: Write the failing check**

Document the new runtime behavior:
- hotkey emits signals only
- mic is warm across sessions
- sessions consume pre-roll audio
- `final` commits immediately

- [ ] **Step 2: Run verification**

Run:
```bash
bun tsc --noEmit
bun test src/runtime/control.test.ts src/runtime/mic.test.ts src/runtime/app.test.ts src/runtime/session-runner.test.ts src/runtime/commit.test.ts src/runtime/ibus.test.ts src/runtime/ibus-select.test.ts src/runtime/key.test.ts src/runtime/key-grab.test.ts src/util.test.ts
```
Expected: PASS.

- [ ] **Step 3: Update README**

Add the new behavior summary and remove any stale text that implies the mic is session-cold or that hotkeys directly own ASR lifecycle.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-05-10-signal-driven-control-design.md
git commit -m "docs: describe signal driven control runtime"
```

## Spec Coverage Check
- Hotkey emits control signals only: Task 1, Task 3.
- One controller owns session lifecycle: Task 1, Task 3.
- Mic stays warm and carries pre-roll: Task 2, Task 3.
- `final` still commits immediately: Task 3.
- Error paths remain explicit: Task 1, Task 3.
- Tests added for new behavior: Tasks 1-4.
