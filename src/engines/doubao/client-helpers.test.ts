import { expect, test } from "bun:test";
import { ok, isErr, type Result } from "../../util.ts";
import { ResponseType, type ASRResponse } from "./types.ts";

import {
    buildWebSocketInit,
    consumeReadableResponses,
    createSessionRetryDelayMs,
    isRetryableSessionInitError,
    sliceOrPad,
    type ReadableResponseEvent,
} from "./client-helpers.ts";

test("websocket init carries doubao handshake headers", () => {
    const headers = {
        "User-Agent": "ua",
        "proto-version": "v2",
        "x-custom-keepalive": "true",
    };

    expect(buildWebSocketInit(headers)).toEqual({ headers });
});

test("quota errors are not retryable during session init", () => {
    expect(isRetryableSessionInitError("StartSession 失败: ExceededConcurrentQuota")).toBe(false);
    expect(isRetryableSessionInitError("StartSession 失败: ERR timeout")).toBe(true);
});

test("sliceOrPad pads short chunks", () => {
    const result = sliceOrPad(new Uint8Array([1, 2]), 0, 4);
    expect(Array.from(result)).toEqual([1, 2, 0, 0]);
});

test("retry delay scales with attempt", () => {
    expect(createSessionRetryDelayMs(2, 300)).toBe(600);
});

test("response consumer skips heartbeats and stops on session finished", async () => {
    const readable = new ReadableStream<Result<ASRResponse>>({
        start(controller) {
            controller.enqueue(ok({ type: ResponseType.HEARTBEAT }));
            controller.enqueue(ok({ type: ResponseType.INTERIM_RESULT, text: "a" }));
            controller.enqueue(ok({ type: ResponseType.SESSION_FINISHED }));
            controller.enqueue(ok({ type: ResponseType.FINAL_RESULT, text: "b" }));
            controller.close();
        },
    });

    const seen: Array<{ type: ResponseType; completed: boolean }> = [];
    for await (const responseResult of consumeReadableResponses(readable, { stopOnSessionFinished: true })) {
        pushReadableResponseEvent(seen, responseResult);
    }

    expect(seen).toEqual([
        { type: ResponseType.INTERIM_RESULT, completed: false },
        { type: ResponseType.SESSION_FINISHED, completed: true },
    ]);
});

test("response consumer stops on final result when requested", async () => {
    const readable = new ReadableStream<Result<ASRResponse>>({
        start(controller) {
            controller.enqueue(ok({ type: ResponseType.INTERIM_RESULT, text: "a" }));
            controller.enqueue(ok({ type: ResponseType.FINAL_RESULT, text: "b" }));
            controller.enqueue(ok({ type: ResponseType.SESSION_FINISHED }));
            controller.close();
        },
    });

    const seen: Array<{ type: ResponseType; completed: boolean }> = [];
    for await (const responseResult of consumeReadableResponses(readable, { stopOnFinal: true })) {
        pushReadableResponseEvent(seen, responseResult);
    }

    expect(seen).toEqual([
        { type: ResponseType.INTERIM_RESULT, completed: false },
        { type: ResponseType.FINAL_RESULT, completed: true },
    ]);
});

const pushReadableResponseEvent = (
    seen: Array<{ type: ResponseType; completed: boolean }>,
    responseResult: Result<ReadableResponseEvent>,
): void => {
    expect(isErr(responseResult)).toBe(false);
    if (isErr(responseResult)) return;
    seen.push({
        type: responseResult.value.response.type,
        completed: responseResult.value.completed,
    });
};
