import { expect, mock, test } from "bun:test";
import { ok } from "../util.ts";
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

test("session runner flushes final result after key release stop", async () => {
    const calls: string[] = [];
    const stopController = new AbortController();
    let pushCount = 0;

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
        commitText: mock(async (text: string) => {
            calls.push(`commit:${text}`);
            return { success: true, method: "ibus" as const, message: "Committed via IBus engine" };
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
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
                    pushCount++;
                    if (pushCount === 1) {
                        stopController.abort();
                    }
                    return ok(undefined);
                }),
                close: mock(async () => {
                    calls.push("close");
                }),
                events: (async function* () {
                    yield ok({ type: "interim", text: "实时" } as const);
                    await new Promise((resolve) => setTimeout(resolve, 20));
                    yield ok({ type: "final", text: "实时识别。" } as const);
                })(),
            }),
    };

    await withMutedConsole(async () => {
        await runRecognitionSession(engine, {} as never, stopController.signal, { deps });
    });

    expect(pushCount).toBeGreaterThan(0);
    expect(calls).toContain("stop");
    expect(calls).toContain("mute");
    expect(calls).toContain("unmute");
    expect(calls).toContain("commit:实时识别。");
});

test("session runner plays notification before starting microphone", async () => {
    const calls: string[] = [];

    const deps = {
        createMicStream: mock(() => {
            calls.push("mic:start");
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
        commitText: mock(async (text: string) => {
            calls.push(`commit:${text}`);
            return { success: true, method: "ibus" as const, message: "Committed via IBus engine" };
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
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
                    await new Promise((resolve) => setTimeout(resolve, 10));
                    yield ok({ type: "final", text: "实时识别。" } as const);
                })(),
            }),
    };

    await withMutedConsole(async () => {
        await runRecognitionSession(engine, {} as never, new AbortController().signal, { deps });
    });

    const notifyIndex = calls.indexOf("notify");
    const micStartIndex = calls.indexOf("mic:start");
    expect(notifyIndex).toBeGreaterThanOrEqual(0);
    expect(micStartIndex).toBeGreaterThan(notifyIndex);
});

test("session runner releases speaker immediately when key is released while commit is pending", async () => {
    const calls: string[] = [];
    const stopController = new AbortController();
    const releaseController = new AbortController();
    let finishCommit: (() => void) | undefined;
    let commitStarted: (() => void) | undefined;
    const commitStartedPromise = new Promise<void>((resolve) => {
        commitStarted = resolve;
    });
    const finishCommitPromise = new Promise<void>((resolve) => {
        finishCommit = resolve;
    });

    const deps = {
        createMicStream: mock((options?: { signal?: AbortSignal }) => {
            let stopMic: (() => void) | undefined;
            const stopMicPromise = new Promise<void>((resolve) => {
                stopMic = resolve;
            });
            options?.signal?.addEventListener("abort", () => stopMic?.(), { once: true });
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                await stopMicPromise;
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                    stopMic?.();
                }),
            });
        }),
        commitText: mock(async (text: string) => {
            calls.push(`commit:${text}`);
            commitStarted?.();
            await finishCommitPromise;
            calls.push("commitDone");
            return { success: true, method: "ibus" as const, message: "Committed via IBus engine" };
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
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
                    while (!calls.includes("mute")) {
                        await new Promise((resolve) => setTimeout(resolve, 0));
                    }
                    yield ok({ type: "final", text: "实时识别。" } as const);
                })(),
            }),
    };

    const runPromise = withMutedConsole(async () => {
        await runRecognitionSession(engine, {} as never, stopController.signal, {
            deps,
            releaseSignal: releaseController.signal,
        });
    });

    await commitStartedPromise;
    releaseController.abort();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(calls).toContain("unmute");
    expect(calls).not.toContain("commitDone");

    finishCommit?.();
    stopController.abort();
    await runPromise;

    expect(calls.filter((call) => call === "unmute")).toHaveLength(1);
});

test("session runner finishes without waiting for pending ibus commit", async () => {
    const calls: string[] = [];
    let finishCommit: (() => void) | undefined;
    let commitStarted: (() => void) | undefined;
    const commitStartedPromise = new Promise<void>((resolve) => {
        commitStarted = resolve;
    });
    const finishCommitPromise = new Promise<void>((resolve) => {
        finishCommit = resolve;
    });

    const deps = {
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
        commitText: mock(async (text: string) => {
            calls.push(`commit:${text}`);
            commitStarted?.();
            await finishCommitPromise;
            calls.push("commitDone");
            return { success: true, method: "ibus" as const, message: "Committed via IBus engine" };
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
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
                    yield ok({ type: "final", text: "实时识别。" } as const);
                    yield ok({ type: "session_finished" } as const);
                })(),
            }),
    };

    await withMutedConsole(async () => {
        const runPromise = runRecognitionSession(engine, {} as never, new AbortController().signal, { deps });

        await commitStartedPromise;
        const result = await Promise.race([
            runPromise.then(() => "done" as const),
            new Promise<"blocked">((resolve) => setTimeout(() => resolve("blocked"), 20)),
        ]);

        expect(result).toBe("done");
        expect(calls).not.toContain("commitDone");

        finishCommit?.();
        await new Promise((resolve) => setTimeout(resolve, 0));
        await runPromise;
    });
});

test("session runner serializes ibus commits across recognition sessions", async () => {
    const calls: string[] = [];
    let finishFirstCommit: (() => void) | undefined;
    let firstCommitStarted: (() => void) | undefined;
    let secondCommitStarted: (() => void) | undefined;
    const firstCommitStartedPromise = new Promise<void>((resolve) => {
        firstCommitStarted = resolve;
    });
    const secondCommitStartedPromise = new Promise<void>((resolve) => {
        secondCommitStarted = resolve;
    });
    const finishFirstCommitPromise = new Promise<void>((resolve) => {
        finishFirstCommit = resolve;
    });

    const deps = {
        createMicStream: mock(() => {
            const stream = (async function* (): AsyncGenerator<Uint8Array> {
                yield new Uint8Array([0, 0, 0, 0]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
                yield new Uint8Array([0xff, 0x7f, 0xff, 0x7f]);
            })();
            return Object.assign(stream, {
                stop: mock(() => {
                    calls.push("stop");
                }),
            });
        }),
        commitText: mock(async (text: string) => {
            calls.push(`commit:start:${text}`);
            if (text === "第一条。") {
                firstCommitStarted?.();
                await finishFirstCommitPromise;
            }
            if (text === "第二条。") {
                secondCommitStarted?.();
            }
            calls.push(`commit:finish:${text}`);
            return { success: true, method: "ibus" as const, message: "Committed via IBus engine" };
        }),
        muteSpeaker: mock(() => {
            calls.push("mute");
        }),
        unmuteSpeaker: mock(() => {
            calls.push("unmute");
        }),
        playMicReadyNotification: mock(async () => {
            calls.push("notify");
        }),
    };

    const createEngine = (text: string) => ({
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: async () =>
            ok({
                pushAudio: mock(async () => ok(undefined)),
                close: mock(async () => {}),
                events: (async function* () {
                    yield ok({ type: "final", text } as const);
                    yield ok({ type: "session_finished" } as const);
                })(),
            }),
    });

    await withMutedConsole(async () => {
        const firstRun = runRecognitionSession(createEngine("第一条。"), {} as never, new AbortController().signal, { deps });
        await firstCommitStartedPromise;

        const secondRun = runRecognitionSession(createEngine("第二条。"), {} as never, new AbortController().signal, { deps });
        const secondStartResult = await Promise.race([
            secondCommitStartedPromise.then(() => "started" as const),
            new Promise<"blocked">((resolve) => setTimeout(() => resolve("blocked"), 20)),
        ]);

        expect(secondStartResult).toBe("blocked");

        finishFirstCommit?.();
        await secondCommitStartedPromise;
        await Promise.all([firstRun, secondRun]);
    });

    expect(calls.filter((call) => call.startsWith("commit:start:"))).toEqual([
        "commit:start:第一条。",
        "commit:start:第二条。",
    ]);
});
