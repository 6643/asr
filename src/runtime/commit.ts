/**
 * Text commit: IBus only.
 */

import { err, isErr, ok, tryAsyncResult, type Result } from "../util.ts";
import { isIbusRuntimeStatusReady } from "./ibus.ts";
import { callIbusServiceStringMethodInWorker } from "./ibus-rpc-worker-client.ts";
import { logDebug } from "./output.ts";
import { isDebugEnabled } from "./config.ts";

export interface CommitResult {
    success: boolean;
    method: "ibus";
    message: string;
}

const RETRYABLE_IBUS_RESPONSES = new Set([
    "ERR empty_response",
    "ERR engine_not_active",
    "ERR engine_not_created",
    "ERR engine_not_enabled",
    "ERR engine_not_focused",
    "ERR timeout",
    "ERR service_unavailable",
]);

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));
const IBUS_COMMIT_RETRY_PLAN = {
    maxAttempts: 3,
    timeoutMs: 1500,
    delayMs: 200,
} as const;

export const getIbusCommitRetryPlan = (): typeof IBUS_COMMIT_RETRY_PLAN => IBUS_COMMIT_RETRY_PLAN;

const isCommitDebugEnabled = (): boolean => {
    return isDebugEnabled();
};

const normalizeIbusResponse = (response: string): string => {
    const trimmed = response.trim();
    if (!trimmed) return "ERR empty_response";
    return trimmed.replace(/^ERR\s+ERR\s+/, "ERR ");
};

const debugCommit = (message: string): void => {
    if (!isCommitDebugEnabled()) return;
    logDebug("ibus", message);
};

const readIbusStatusInWorker = (timeoutMs: number): Promise<Result<string>> => {
    return callIbusServiceStringMethodInWorker("GetStatus", [], timeoutMs);
};

const waitForIbusRuntimeReadyInWorker = async (timeoutMs: number): Promise<Result<void>> => {
    const status = await readIbusStatusInWorker(timeoutMs);
    if (isErr(status)) return err(status.error);
    if (isIbusRuntimeStatusReady(status.value)) return ok(undefined);
    return err(new Error(status.value));
};

const commitIbusTextInWorker = (text: string, timeoutMs: number): Promise<Result<string>> => {
    return callIbusServiceStringMethodInWorker("CommitText", [text], timeoutMs);
};

export const isRetryableIbusResponse = (response: string): boolean => {
    return RETRYABLE_IBUS_RESPONSES.has(normalizeIbusResponse(response));
};

const commitViaIbus = async (text: string): Promise<{ ok: boolean; response: string }> => {
    const result = await tryAsyncResult(() => commitViaIbusUnchecked(text));
    if (!isErr(result)) return result.value;
    const response = normalizeIbusResponse(`ERR ${result.error.message}`);
    debugCommit(`result ${response}`);
    return { ok: false, response };
};

const commitViaIbusUnchecked = async (text: string): Promise<{ ok: boolean; response: string }> => {
    const retryPlan = getIbusCommitRetryPlan();
    await debugIbusStatus(retryPlan.timeoutMs);
    const ready = await ensureIbusReadyForCommit(retryPlan.timeoutMs);
    if (isErr(ready)) return { ok: false, response: normalizeIbusResponse(`ERR ${ready.error.message}`) };
    const output = await runIbusCommitAttempts(text, retryPlan);
    const finalOutput = normalizeIbusResponse(output);
    debugCommit(`result ${finalOutput || "ERR empty_response"}`);
    return { ok: output.startsWith("OK "), response: finalOutput };
};

const debugIbusStatus = async (timeoutMs: number): Promise<void> => {
    if (!isCommitDebugEnabled()) return;
    const statusResult = await readIbusStatusInWorker(timeoutMs);
    debugCommit(formatIbusStatusResult(statusResult));
};

const formatIbusStatusResult = (statusResult: Result<string>): string => {
    if (isErr(statusResult)) return `status err: ${statusResult.error.message}`;
    return `status ${statusResult.value}`;
};

const ensureIbusReadyForCommit = async (timeoutMs: number): Promise<Result<void>> => {
    debugCommit("waitForReady start");
    const readyResult = await waitForIbusRuntimeReadyInWorker(timeoutMs);
    if (!isErr(readyResult)) {
        debugCommit("waitForReady ok");
        return ok(undefined);
    }
    debugCommit(`waitForReady err ${readyResult.error.message}`);
    return err(readyResult.error);
};

const runIbusCommitAttempts = async (
    text: string,
    retryPlan: typeof IBUS_COMMIT_RETRY_PLAN,
    attempt = 0,
    lastOutput = "",
): Promise<string> => {
    if (attempt >= retryPlan.maxAttempts) return lastOutput;
    const output = await runIbusCommitAttempt(text, retryPlan.timeoutMs, attempt);
    if (!isRetryableIbusResponse(output)) return output;
    await sleep(retryPlan.delayMs);
    return runIbusCommitAttempts(text, retryPlan, attempt + 1, output);
};

const runIbusCommitAttempt = async (text: string, timeoutMs: number, attempt: number): Promise<string> => {
    debugCommit(`commit rpc start attempt=${attempt + 1}`);
    const commitResult = await commitIbusTextInWorker(text, timeoutMs);
    const output = normalizeIbusResponse(isErr(commitResult) ? "ERR service_unavailable" : commitResult.value);
    debugCommit(`commit rpc end attempt=${attempt + 1} ${output}`);
    return output;
};

export const commitText = async (text: string): Promise<CommitResult> => {
    const ibusResult = await commitViaIbus(text);
    if (ibusResult.ok) {
        return { success: true, method: "ibus", message: "Committed via IBus engine" };
    }

    return { success: false, method: "ibus", message: ibusResult.response || "IBus commit failed" };
};
