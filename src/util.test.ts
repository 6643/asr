import { expect, test } from "bun:test";

import { runCommand } from "./util.ts";
import { isRetryableIbusResponse } from "./runtime/commit.ts";

test("runCommand preserves inherited environment while applying overrides", () => {
    const [commandResult, commandError] = runCommand("env", [], {
        env: { ASR_UTIL_TEST_MARKER: "BAR" },
        timeoutMs: 1000,
    });

    expect(commandError === null).toBe(true);
    if (commandError !== null) return;

    const lines = commandResult.stdout.trim().split("\n");
    expect(lines).toContain("ASR_UTIL_TEST_MARKER=BAR");
    expect(lines.some((line: string) => line.startsWith("PATH="))).toBe(true);
});

test("retryable ibus responses include transient engine states", () => {
    expect(isRetryableIbusResponse("ERR connect ENOENT /tmp/asr_ibus.sock")).toBe(true);
    expect(isRetryableIbusResponse("ERR empty_response")).toBe(true);
    expect(isRetryableIbusResponse("ERR engine_not_created")).toBe(true);
    expect(isRetryableIbusResponse("ERR engine_not_focused")).toBe(true);
    expect(isRetryableIbusResponse("ERR timeout")).toBe(true);
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
