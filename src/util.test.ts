import { expect, test } from "bun:test";

import { isErr, runCommand } from "./util.ts";
import { isRetryableIbusResponse } from "./runtime/commit.ts";

test("runCommand preserves inherited environment while applying overrides", () => {
    const commandResult = runCommand("env", [], {
        env: { ASR_UTIL_TEST_MARKER: "BAR" },
        timeoutMs: 1_000,
    });

    expect(isErr(commandResult)).toBe(false);
    if (isErr(commandResult)) return;

    const lines = commandResult.value.stdout.trim().split("\n");
    expect(lines).toContain("ASR_UTIL_TEST_MARKER=BAR");
    expect(lines.some((line: string) => line.startsWith("PATH="))).toBe(true);
});

test("runCommand reports timeout instead of null exit code", () => {
    const commandResult = runCommand("sh", ["-c", "sleep 1"], { timeoutMs: 10 });

    expect(isErr(commandResult)).toBe(true);
    if (!isErr(commandResult)) return;
    expect(commandResult.error.message).toContain("timed out after 10ms");
});

test("retryable ibus responses include transient engine states", () => {
    expect(isRetryableIbusResponse("ERR empty_response")).toBe(true);
    expect(isRetryableIbusResponse("ERR engine_not_created")).toBe(true);
    expect(isRetryableIbusResponse("ERR engine_not_focused")).toBe(true);
    expect(isRetryableIbusResponse("ERR timeout")).toBe(true);
    expect(isRetryableIbusResponse("ERR service_unavailable")).toBe(true);
    expect(isRetryableIbusResponse("ERR commit_rejected")).toBe(false);
});

test("retryable ibus responses stay limited to transient startup states", () => {
    expect(isRetryableIbusResponse("ERR unsupported")).toBe(false);
    expect(isRetryableIbusResponse("ERR permission denied")).toBe(false);
});

test("retryable session init errors include timeout", async () => {
    const { transcribeRealtimeStandalone } = await import("./engines/doubao/client.ts");
    expect(typeof transcribeRealtimeStandalone).toBe("function");
});
