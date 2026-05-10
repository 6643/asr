# Live Status Line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse each voice session into one timestamped live status line that starts with a microphone icon, updates in place during recognition, and becomes a check-mark line after successful IBus commit.

**Architecture:** Keep ASR engine logic unchanged. Move all visible session rendering into `src/runtime/output.ts`, keep session lifecycle in `src/runtime/app.ts`, and leave IBus commit behavior in `src/runtime/commit.ts`. The runtime should print one startup banner, one live session line per voice session, and only print failure lines when a session or commit fails.

**Tech Stack:** Bun, TypeScript, `dbus-next`

---

### Task 1: Add a single-line timestamped status renderer

**Files:**
- Modify: `src/runtime/output.ts`
- Test: `src/runtime/ibus.test.ts` is not affected

- [ ] **Step 1: Define the single-line render helper**

```ts
const formatTime = (): string => {
    return new Date().toLocaleString("sv-SE", { hour12: false }).replace("T", " ");
};

const writeTimedStatus = (message: string, endWithNewline: boolean): void => {
    const suffix = endWithNewline ? "\n" : "";
    process.stdout.write(`\r${formatTime()} ${message}\x1b[K${suffix}`);
};
```

- [ ] **Step 2: Rewrite the public output functions to use the helper**

```ts
export const printSessionStart = (): void => {
    writeTimedStatus("🎤 语音实时识别", true);
};

export const printInterim = (text: string): void => {
    writeTimedStatus(`🎤 ${text || "…"}`, false);
};

export const printFinal = (text: string): void => {
    writeTimedStatus(`✅ ${text || "…"}`, true);
};

export const printIbusCommitSuccess = (): void => {
    writeTimedStatus("✅ ibus 成功", true);
};

export const printIbusCommitFailure = (message: string): void => {
    writeTimedStatus(`❌ ibus 失败: ${message}`, true);
};

export const printRecognitionError = (message: string): void => {
    console.error(`${formatTime()} ❌ 识别错误: ${message}`);
};
```

- [ ] **Step 3: Keep startup and device lines timestamped**

```ts
export const printStartupBanner = (): void => {
    console.log(`${formatTime()} ✅ 实时语音识别（按键触发模式）`);
    console.log(`${formatTime()} ✅ 按下 右Alt 键开始说话, 松开结束`);
    console.log("");
};

export const printKeyDevice = (device: string): void => {
    console.log(`${formatTime()} Keyboard device: ${device}`);
    console.log("");
};
```

- [ ] **Step 4: Verify the helper compiles**

Run:
```bash
bun tsc --noEmit
```

Expected:
`0` exit code, no TypeScript errors.

---

### Task 2: Make the session lifecycle produce one visible line

**Files:**
- Modify: `src/runtime/app.ts`
- Modify: `src/runtime/output.ts`

- [ ] **Step 1: Remove the separate session end counters from normal flow**

```ts
for await (const result of stream) {
    count++;

    if (!result.ok) {
        printRecognitionError(result.error.message);
        break;
    }

    sawAnyResult = true;
    const resp = result.value;
    switch (resp.type) {
        case "interim":
            printInterim(resp.text || "");
            break;
        case "final":
            printFinal(resp.text || "");
            if ((resp.text || "").length >= bestFinalText.length) {
                bestFinalText = resp.text || "";
            }
            break;
        case "error":
            printAsrError(resp.message || "Unknown error");
            break;
        case "vad":
            printVadStart();
            break;
        case "session_finished":
            await commitBestFinalText();
            break;
    }
}

await commitBestFinalText();
if (!sawAnyResult) {
    printRecognitionError("未收到识别结果");
}
printSessionFinished();
printSessionEnd(count);
```

- [ ] **Step 2: Keep the final result as the last update of the same line**

The last successful state update must be the final text line:

```ts
printFinal("你好, 进行语音实时识别。");
```

After that, commit success should update the same line into:

```ts
printIbusCommitSuccess();
```

- [ ] **Step 3: Ensure there is no separate per-session response dump**

Do not reintroduce these lines in the normal path:

```ts
printSessionFinished();
printSessionEnd(count);
```

The only visible output after a successful commit should be the final `✅` status line, not a separate session summary.

- [ ] **Step 4: Verify runtime output shape**

Run:
```bash
bun run index.ts
```

Expected:
- One startup banner.
- One `🎤` live session line that updates in place.
- One final `✅` line after commit.
- No `中间:` / `最终:` / `会话结束` / `结束 (共 N 条响应)` lines in the normal success path.

---

### Task 3: Keep IBus commit stable while the log format changes

**Files:**
- Modify: `src/runtime/commit.ts`
- Modify: `src/runtime/ibus.ts`

- [ ] **Step 1: Keep the commit path socket-only**

```ts
const commitViaIbus = async (text: string): Promise<{ ok: boolean; response: string }> => {
    if (!(await waitForSocket(DEFAULT_IBUS_SOCKET))) {
        return { ok: false, response: `ERR connect ENOENT ${DEFAULT_IBUS_SOCKET}` };
    }

    // connect, write text, and retry ENOENT only
};
```

- [ ] **Step 2: Keep service startup unchanged**

```ts
export const startIbusService = async (): Promise<void> => {
    const ibusAddress = await resolveIbusAddress();
    // keep existing bus, factory, and socket startup
};
```

- [ ] **Step 3: Verify this task does not change IBus behavior**

Run:
```bash
bun test src/runtime/ibus.test.ts src/runtime/ibus-select.test.ts src/util.test.ts
```

Expected:
All tests pass.

---

### Task 4: End-to-end verification

**Files:**
- None

- [ ] **Step 1: Run typecheck and tests**

Run:
```bash
bun tsc --noEmit
bun test src/runtime/ibus.test.ts src/runtime/ibus-select.test.ts src/runtime/key.test.ts src/runtime/key-grab.test.ts src/util.test.ts
```

Expected:
All commands exit `0`.

- [ ] **Step 2: Run the app and confirm the single-line status behavior**

Run:
```bash
bun run index.ts
```

Expected:
- The live recognition line uses `🎤` during interim updates.
- Final text replaces the same line.
- `✅ ibus 成功` appears once after a successful commit.
- No separate session counter or end-of-session log lines appear.

- [ ] **Step 3: Keep the plan reversible**

If the single-line rendering feels too quiet or hides useful failure context, revert only `src/runtime/output.ts` and the `src/runtime/app.ts` call sites. Do not change ASR or IBus behavior.
