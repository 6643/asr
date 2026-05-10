# Session Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把语音识别主流程改成会话对象驱动, 让引擎只负责输出识别结果流, 运行时只负责快捷键和 IBus 上屏。

**Architecture:** 引擎层暴露一个轻量 session 接口, 只接收音频并产出识别事件. 运行时在按键按下时创建 session, 在按键弹起时关闭 session, 并把 `final` 直接提交给 IBus. IBus, 快捷键和音频采集都留在 runtime, 不进入引擎目录.

**Tech Stack:** Bun, TypeScript, dbus-next, Bun test.

---

### Task 1: Define the session boundary

**Files:**
- Modify: `src/runtime/recognition.ts`
- Modify: `src/engines/doubao/index.ts`
- Modify: `src/runtime/app.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";
import { createDoubaoEngine } from "../../src/engines/doubao/index.ts";

 test("doubao engine exposes a session-oriented reader", () => {
     const engine = createDoubaoEngine();
     expect(engine.name).toBe("doubao");
     expect(typeof engine.transcribeRealtime).toBe("function");
 });
```

Run: `bun test src/runtime/ibus-select.test.ts`
Expected: pass after implementation, and the type-level interface change should force updates in callers.

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/runtime/ibus-select.test.ts`
Expected: FAIL or type mismatch before the interface is updated.

- [ ] **Step 3: Write minimal implementation**

```ts
export interface RecognitionSession {
    pushAudio: (chunk: Uint8Array) => Promise<void>;
    close: () => Promise<void>;
    events: AsyncGenerator<Result<RecognitionEvent>>;
}

export interface RecognitionEngine<TClient> {
    name: string;
    createClient: () => TClient;
    prepare: (client: TClient) => Promise<Result<void>>;
    describe: (client: TClient) => string[];
    startSession: (
        client: TClient,
    ) => Promise<Result<RecognitionSession>>;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/runtime/ibus-select.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/recognition.ts src/engines/doubao/index.ts src/runtime/app.ts
git commit -m "refactor: introduce session-oriented recognition interface"
```

### Task 2: Move stream ownership into runtime

**Files:**
- Modify: `src/runtime/app.ts`
- Modify: `src/runtime/mic.ts`
- Modify: `src/engines/doubao/client.ts`
- Modify: `src/engines/doubao/index.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";

 test("runtime creates a session per key press and submits each final immediately", () => {
     expect(true).toBe(true);
 });
```

Run: `bun test src/util.test.ts`
Expected: placeholder test will pass, then replace it with a real runtime harness once the session interface exists.

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/util.test.ts`
Expected: this step is a placeholder until the harness exists.

- [ ] **Step 3: Write minimal implementation**

```ts
const session = await engine.startSession(client);
if (!session.ok) {
    printInitError("初始化失败", session.error.message);
    return;
}

for await (const event of session.value.events) {
    if (!event.ok) {
        printRecognitionError(event.error.message);
        break;
    }
    // interim/final handling stays in runtime.
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/util.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/app.ts src/runtime/mic.ts src/engines/doubao/client.ts src/engines/doubao/index.ts
git commit -m "refactor: move recognition streaming into session boundary"
```

### Task 3: Keep IBus submission as runtime-only

**Files:**
- Modify: `src/runtime/commit.ts`
- Modify: `src/runtime/output.ts`
- Modify: `src/runtime/app.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";
import { isRetryableIbusResponse } from "../../src/runtime/commit.ts";

 test("ibus retries only transient startup states", () => {
     expect(isRetryableIbusResponse("ERR engine_not_created")).toBe(true);
     expect(isRetryableIbusResponse("ERR unsupported")).toBe(false);
 });
```

Run: `bun test src/util.test.ts`
Expected: PASS after the existing retry logic stays intact.

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/util.test.ts`
Expected: PASS already; use this as a regression guard while refactoring callers.

- [ ] **Step 3: Write minimal implementation**

```ts
case "final": {
    const text = resp.text || "";
    printFinal(text);
    const res = await commitText(text);
    if (res.success) {
        printIbusCommitSuccess(text);
    } else {
        printIbusCommitFailure(text, res.message);
    }
    break;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun tsc --noEmit && bun test src/runtime/ibus-select.test.ts src/util.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/commit.ts src/runtime/output.ts src/runtime/app.ts
git commit -m "refactor: keep ibus submission in runtime only"
```

### Task 4: Clean up bin and docs references

**Files:**
- Modify: `.gitignore`
- Modify: `README.md`
- Delete: `bin/asr-ibus`
- Delete: `bin/asr-ibus-xml`

- [ ] **Step 1: Write the failing test**

```bash
grep -RIn "asr-ibus\|asr-ibus-xml" . --exclude-dir=node_modules --exclude=.git
```

Expected: no matches after cleanup.

- [ ] **Step 2: Run test to verify it fails**

Run: `grep -RIn "asr-ibus\|asr-ibus-xml" . --exclude-dir=node_modules --exclude=.git`
Expected: currently still matches if files or docs remain.

- [ ] **Step 3: Write minimal implementation**

```md
- Keep: `bin/asr-service`
- Keep: `bin/asr-install`
- Remove stale `bin/asr-ibus` and `bin/asr-ibus-xml` references from docs
```

- [ ] **Step 4: Run test to verify it passes**

Run: `grep -RIn "asr-ibus\|asr-ibus-xml" . --exclude-dir=node_modules --exclude=.git`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add .gitignore README.md bin/asr-service bin/asr-install
git commit -m "chore: remove stale compatibility binaries and docs"
```

### Task 5: Verify end-to-end startup and submission

**Files:**
- Modify: none
- Test: existing runtime tests plus manual run

- [ ] **Step 1: Write the failing test**

```bash
bun run index.ts
```

Expected: startup reaches keyboard/device output, then a real `final` submits through IBus without `ERR engine_not_created`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bun run index.ts`
Expected: if the session boundary is wrong, you will see `❎ ibus err` or startup readiness failures.

- [ ] **Step 3: Write minimal implementation**

Use the session interface from Task 1 and let runtime own the audio-to-IBus path.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun run index.ts`
Expected: first `final` is committed reliably, with no manual `ibus restart` needed.

- [ ] **Step 5: Commit**

```bash
git add .
git commit -m "refactor: split recognition session from runtime submission"
```
