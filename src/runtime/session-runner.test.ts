import { expect, mock, test } from "bun:test";
import { err, ok } from "../util.ts";
import { runRecognitionSession } from "./session-runner.ts";

const withMutedConsole = async (fn: () => Promise<void>): Promise<void> => {
    const originalLog = console.log;
    const originalError = console.error;
    console.log = mock(() => {});
    console.error = mock(() => {});
    try {
        await fn();
    } finally {
        console.log = originalLog;
        console.error = originalError;
    }
};

test("session runner notifies and mutes after first asr event", async () => {
    const calls: string[] = [];
    const deps = {
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([1, 0, 1, 0]);
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                return;
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        commitText: mock(async () => ({
            success: true,
            method: "ibus" as const,
            message: "mock commit",
        })),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    };

    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () =>
            ok({
                pushAudio: mock(async () => {
                    calls.push("push");
                    return ok(undefined);
                }),
                close: mock(async () => {}),
                events: (async function* () {
                    yield ok({ type: "session_finished" } as const);
                })(),
            }),
    };

    await withMutedConsole(async () => {
        await runRecognitionSession(engine, {} as never, new AbortController().signal, { deps });
    });

    expect(calls).toContain("notify");
    expect(calls.indexOf("mute")).toBeGreaterThan(calls.indexOf("notify"));
    expect(calls).toContain("push");
    expect(calls).toContain("stop");
    expect(calls.at(-1)).toBe("unmute");
});

test("session runner stops mic when session start fails", async () => {
    const calls: string[] = [];
    const deps = {
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([1, 0, 1, 0]);
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                return;
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        commitText: mock(async () => ({
            success: true,
            method: "ibus" as const,
            message: "mock commit",
        })),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    };

    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () => err(new Error("boom")),
    };

    await withMutedConsole(async () => {
        await runRecognitionSession(engine, {} as never, new AbortController().signal, { deps });
    });

    expect(calls).toContain("stop");
    expect(calls).toContain("unmute");
    expect(calls).not.toContain("mute");
});

test("session runner does not mute before first asr event", async () => {
    const calls: string[] = [];
    const deps = {
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                return;
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        commitText: mock(async () => ({
            success: true,
            method: "ibus" as const,
            message: "mock commit",
        })),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    };

    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () =>
            ok({
                pushAudio: mock(async () => ok(undefined)),
                close: mock(async () => {}),
                events: (async function* () {
                    yield ok({ type: "interim", text: "实时" } as const);
                    yield ok({ type: "final", text: "实时识别。" } as const);
                })(),
            }),
    };

    await withMutedConsole(async () => {
        await runRecognitionSession(engine, {} as never, new AbortController().signal, { deps });
    });

    expect(calls).toContain("notify");
    expect(calls.indexOf("mute")).toBeGreaterThan(calls.indexOf("notify"));
});

test("session runner surfaces mic stream failure before voice detection", async () => {
    const calls: string[] = [];
    const deps = {
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([0, 0, 0, 0]);
                throw new Error("mic failed");
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        commitText: mock(async () => ({
            success: true,
            method: "ibus" as const,
            message: "mock commit",
        })),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    };

    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () =>
            ok({
                pushAudio: mock(async () => ok(undefined)),
                close: mock(async () => {}),
                events: (async function* () {
                    yield ok({ type: "session_finished" } as const);
                })(),
            }),
    };

    await withMutedConsole(async () => {
        await runRecognitionSession(engine, {} as never, new AbortController().signal, { deps });
    });

    expect(calls).not.toContain("mute");
    expect(calls).toContain("stop");
});

test("session runner preserves commit failures from the engine", async () => {
    const calls: string[] = [];
    const deps = {
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([1, 0, 1, 0]);
                return;
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        commitText: mock(async () => ({
            success: false,
            method: "ibus" as const,
            message: "ERR service_unavailable",
        })),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    };

    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () =>
            ok({
                pushAudio: mock(async () => ok(undefined)),
                close: mock(async () => {}),
                events: (async function* () {
                    yield ok({ type: "final", text: "识别结果" } as const);
                })(),
            }),
    };

    await withMutedConsole(async () => {
        await runRecognitionSession(engine, {} as never, new AbortController().signal, { deps, debugEnabled: true });
    });

    expect(calls).toContain("stop");
    expect(calls).toContain("unmute");
});
