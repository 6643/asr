# Retry and IBus Readiness Fix Implementation Plan

> This plan is historical and superseded by the DBus transport refactor. The socket readiness items below are no longer accurate for the current codebase.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Doubao session retries real, and make IBus readiness checks use actual service availability instead of stale file presence.

**Architecture:** Keep the current single-entry runtime. Fix the Doubao session retry path so a retry creates a fresh session attempt instead of reusing a broken one. The IBus transport now uses DBus directly, so readiness should be described in terms of DBus service availability rather than Unix socket files.

**Tech Stack:** Bun, TypeScript, bun:test, existing runtime and engine modules.

---

### Task 1: Make Doubao session retry real

**Files:**
- Modify: `src/engines/doubao/session.ts`
- Modify: `src/engines/doubao/client.ts`
- Test: `src/engines/doubao/session.test.ts` (new)

- [ ] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";
import { createDoubaoSession } from "./session.ts";

// This test should assert that a retryable startup error does not end the whole session immediately.
// The first attempt fails with ERR timeout, the second attempt succeeds and yields a session object.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/engines/doubao/session.test.ts -v`
Expected: FAIL because the current retry loop does not rebuild the session cleanly.

- [ ] **Step 3: Write minimal implementation**

Update `retryableTranscribeRealtime` so each retry attempt builds a fresh session stream from a fresh session initializer instead of reusing a partially consumed stream. Keep the retryable error list the same.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/engines/doubao/session.test.ts -v`
Expected: PASS.

- [ ] **Step 5: Verify related tests still pass**

Run: `bun test src/runtime/ibus.test.ts src/runtime/ibus-select.test.ts src/runtime/key.test.ts src/runtime/key-grab.test.ts src/util.test.ts`
Expected: PASS.

### Task 2: Tighten IBus readiness probing

> Deprecated. The implementation now uses DBus service calls instead of Unix socket probing. Keep this section only as historical context.

**Files:**
- Modify: `src/runtime/ibus.ts`
- Modify: `src/runtime/ibus-select.test.ts`

- [x] **Step 1: Write the failing test**

```ts
import { expect, test } from "bun:test";
import fs from "fs";
import { isIbusSocketReady } from "./ibus.ts";

test("ibus socket readiness rejects stale socket files", async () => {
  const socketPath = "/tmp/asr_ibus.sock";
  try { fs.unlinkSync(socketPath); } catch {}
  fs.writeFileSync(socketPath, "stale", "utf8");
  await expect(isIbusSocketReady()).resolves.toBe(false);
  try { fs.unlinkSync(socketPath); } catch {}
});
```

- [x] **Step 2: Run test to verify it fails**

Run: `bun test src/runtime/ibus-select.test.ts -v`
Expected: FAIL if the probe still accepts stale files or throws on connect.

- [x] **Step 3: Write minimal implementation**

Keep `isIbusSocketReady()` and `waitForIbusRuntimeReady()` using actual socket connect probes, and make sure the probe listens for connect/error before calling `connect()`.

- [x] **Step 4: Run test to verify it passes**

Run: `bun test src/runtime/ibus-select.test.ts -v`
Expected: PASS.

- [x] **Step 5: Verify related tests still pass**

Run: `bun tsc --noEmit && bun test src/runtime/ibus.test.ts src/runtime/ibus-select.test.ts src/runtime/key.test.ts src/runtime/key-grab.test.ts src/util.test.ts`
Expected: PASS.
