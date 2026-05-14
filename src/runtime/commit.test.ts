import { expect, test } from "bun:test";

import { getIbusCommitRetryPlan, isRetryableIbusResponse } from "./commit.ts";

test("retryable ibus responses cover transient dbus states", () => {
    expect(isRetryableIbusResponse("ERR empty_response")).toBe(true);
    expect(isRetryableIbusResponse("ERR engine_not_active")).toBe(true);
    expect(isRetryableIbusResponse("ERR engine_not_enabled")).toBe(true);
    expect(isRetryableIbusResponse("ERR engine_not_focused")).toBe(true);
    expect(isRetryableIbusResponse("ERR timeout")).toBe(true);
    expect(isRetryableIbusResponse("ERR ERR timeout")).toBe(true);
    expect(isRetryableIbusResponse("ERR service_unavailable")).toBe(true);
    expect(isRetryableIbusResponse("ERR commit_rejected")).toBe(false);
});

test("commit keeps engine_not_focused visible instead of collapsing to service_unavailable", async () => {
    const source = await Bun.file(new URL("./commit.ts", import.meta.url)).text();

    expect(source).not.toContain('return { ok: false, response: "ERR service_unavailable" }');
    expect(source).toContain("return err(new Error(status.value))");
});

test("ibus commit retry plan stays bounded", () => {
    const plan = getIbusCommitRetryPlan();
    expect(plan.maxAttempts).toBeLessThanOrEqual(5);
    expect(plan.timeoutMs).toBeLessThanOrEqual(1500);
    expect(plan.delayMs).toBeLessThanOrEqual(250);
});

test("commit path delegates ibus rpc to worker boundary", async () => {
    const source = await Bun.file(new URL("./commit.ts", import.meta.url)).text();

    expect(source).toContain("callIbusServiceStringMethodInWorker");
    expect(source).not.toContain("invokeIbusCommitText");
    expect(source).not.toContain("withTimeout(");
});

test("commit path no longer carries daemon restart flow", async () => {
    const source = await Bun.file(new URL("./commit.ts", import.meta.url)).text();

    expect(source).not.toContain("restartDaemonAndCheckReady");
    expect(source).not.toContain("tryRestartDaemon");
});
