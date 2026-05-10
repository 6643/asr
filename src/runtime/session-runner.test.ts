import { expect, mock, test } from "bun:test";
import { err, ok } from "../util.ts";

test("session runner notifies and mutes on first mic chunk", async () => {
    const calls: string[] = [];

    mock.module("./mute.ts", () => ({
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
    }));

    mock.module("./notify.ts", () => ({
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    }));

    mock.module("./mic.ts", () => ({
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([1, 2, 3]);
                return;
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
    }));

    const { runRecognitionSession } = await import("./session-runner.ts");

    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () =>
            ok({
                pushAudio: mock(async () => {
                    calls.push("push");
                }),
                close: mock(async () => {}),
                events: (async function* (): AsyncGenerator<[{
                    type: "session_finished";
                }, null]> {
                    yield [{ type: "session_finished" }, null];
                })(),
            }),
    };

    await runRecognitionSession(engine, {} as never, new AbortController().signal);

    expect(calls).toEqual(["notify", "mute", "push", "stop", "unmute"]);
});

test("session runner starts mic capture before session is ready", async () => {
    let sessionReady = false;
    let sawChunkBeforeSession = false;
    const calls: string[] = [];

    mock.module("./mute.ts", () => ({
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
    }));

    mock.module("./notify.ts", () => ({
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    }));

    mock.module("./mic.ts", () => ({
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                if (!sessionReady) {
                    sawChunkBeforeSession = true;
                }
                yield new Uint8Array([9, 9, 9]);
                return;
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
    }));

    const { runRecognitionSession } = await import("./session-runner.ts");

    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () => {
            await new Promise<void>((resolve) => setTimeout(resolve, 10));
            sessionReady = true;
            return ok({
                pushAudio: mock(async () => {}),
                close: mock(async () => {}),
                events: (async function* (): AsyncGenerator<[{ type: "session_finished" }, null]> {
                    yield [{ type: "session_finished" }, null];
                })(),
            });
        },
    };

    await runRecognitionSession(engine, {} as never, new AbortController().signal);

    expect(sawChunkBeforeSession).toBe(true);
    expect(calls).toContain("mute");
    expect(calls).toContain("stop");
    expect(calls).toContain("unmute");
});

test("session runner stops mic when session start fails", async () => {
    const calls: string[] = [];

    mock.module("./mute.ts", () => ({
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
    }));

    mock.module("./notify.ts", () => ({
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    }));

    mock.module("./mic.ts", () => ({
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([1, 2, 3]);
                return;
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
    }));

    const { runRecognitionSession } = await import("./session-runner.ts");

    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () => err(new Error("boom")),
    };

    await runRecognitionSession(engine, {} as never, new AbortController().signal);

    expect(calls).toContain("stop");
    expect(calls).toContain("unmute");
    expect(calls).toContain("mute");
});
