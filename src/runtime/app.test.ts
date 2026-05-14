import { expect, mock, afterEach, test, beforeAll } from "bun:test";
import { ok } from "../util.ts";

beforeAll(() => {
    process.env.ASR_AUTO_SWITCH = "false";
});

afterEach(() => {
    mock.restore();
});

const outputModule = {
    printAsrError: () => {},
    printFinal: () => {},
    printIbusCommitFailure: () => {},
    printIbusCommitSuccess: () => {},
    printInterim: () => {},
    printKeyDevice: () => {},
    printKeyboardEvent: () => {},
    printKeyboardWait: () => {},
    printRecognitionError: () => {},
    printSessionStart: () => {},
    printTimedDomain: () => {},
    printTimedDomainError: () => {},
};

const keyModule = {
    KEY_RIGHT_ALT: 100,
    findKeyboardDevice: async () => "/dev/input/event-test",
    createKeyStream: async function* (_devicePath: string, _keyCode: number, signal?: AbortSignal) {
        while (!signal?.aborted) {
            await new Promise((resolve) => setTimeout(resolve, 0));
        }
    },
};

const ibusModule = {
    isIbusRuntimeStatusReady: (status: string) => status === "ready",
    isIbusServiceStatusAvailable: (statusResult: { error?: Error; value?: string }) => {
        return !statusResult.error || statusResult.error.message.includes("engine_not");
    },
    readIbusServiceStatus: async () => ok("ready"),
    isIbusServiceReady: async () => true,
    isIbusEngineReady: async () => true,
    initIbusRuntime: async () => ok("/usr/share/ibus/component/asr.xml"),
    startIbusService: async () => async () => {},
    ensureIbusServiceRunning: async () => ok(undefined),
    ensureIbusEngineSelected: async () => ok(undefined),
    waitForIbusRuntimeReady: async () => ok(undefined),
};

test("runtime initializes the ibus runtime before starting the local service", async () => {
    const events: string[] = [];

    mock.module("./output.ts", () => ({
        ...outputModule,
        printKeyDevice: () => {},
        printKeyboardEvent: () => {},
        printKeyboardWait: () => {},
        printTimedDomain: (domain: string, message: string) => events.push(`${domain}:${message}`),
        printTimedDomainError: (domain: string, message: string) => events.push(`${domain}:${message}`),
    }));

    mock.module("./key.ts", () => ({
        ...keyModule,
        KEY_RIGHT_ALT: 100,
        findKeyboardDevice: async () => "/dev/input/event-test",
        createKeyStream: async function* (_devicePath: string, _keyCode: number, signal?: AbortSignal) {
            events.push("keyStream:start");
            while (!signal?.aborted) {
                await new Promise((resolve) => setTimeout(resolve, 0));
            }
        },
    }));

    mock.module("./ibus.ts", () => ({
        ...ibusModule,
        initIbusRuntime: async () => {
            events.push("ibus:init");
            return ok("/usr/share/ibus/component/asr.xml");
        },
        startIbusService: async () => {
            events.push("ibus:start");
            return async () => {
                events.push("ibus:stop");
            };
        },
        ensureIbusServiceRunning: async () => {
            events.push("ibus:service");
            return ok(undefined);
        },
        ensureIbusEngineSelected: async () => {
            events.push("ibus:engine");
            return ok(undefined);
        },
        waitForIbusRuntimeReady: async () => {
            events.push("ibus:ready");
            return ok(undefined);
        },
    }));

    const { runRuntime } = await import("./app.ts");
    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: mock(async () => ok({
            pushAudio: mock(async () => ok(undefined)),
            close: mock(async () => {}),
            events: (async function* () {})(),
        })),
    };

    const runPromise = runRuntime(engine, { debugEnabled: true });
    await new Promise((resolve) => setTimeout(resolve, 0));
    process.emit("SIGINT");
    await runPromise;

    expect(events[0]).toBe("ibus:init");
    expect(events.indexOf("ibus:init")).toBeLessThan(events.indexOf("ibus:start"));
    expect(events).toContain("ibus:service");
    expect(events).toContain("ibus:engine");
});

test("runtime starts the keyboard stream even when ibus runtime readiness is still pending", async () => {
    const events: string[] = [];

    mock.module("./output.ts", () => ({
        ...outputModule,
        printKeyDevice: () => {},
        printKeyboardEvent: () => {},
        printKeyboardWait: () => {},
        printTimedDomain: (domain: string, message: string) => events.push(`${domain}:${message}`),
        printTimedDomainError: (domain: string, message: string) => events.push(`${domain}:${message}`),
    }));

    mock.module("./key.ts", () => ({
        ...keyModule,
        KEY_RIGHT_ALT: 100,
        findKeyboardDevice: async () => "/dev/input/event-test",
        createKeyStream: async function* (_devicePath: string, _keyCode: number, signal?: AbortSignal) {
            events.push("keyStream:start");
            while (!signal?.aborted) {
                await new Promise((resolve) => setTimeout(resolve, 0));
            }
        },
    }));

    mock.module("./ibus.ts", () => ({
        ...ibusModule,
        startIbusService: async () => {
            events.push("ibus:start");
            return async () => {
                events.push("ibus:stop");
            };
        },
        ensureIbusServiceRunning: async () => {
            events.push("ibus:service");
            return ok(undefined);
        },
        ensureIbusEngineSelected: async () => {
            events.push("ibus:engine");
            return ok(undefined);
        },
        waitForIbusRuntimeReady: async () => {
            events.push("ibus:ready");
            return { error: new Error("not ready") } as never;
        },
    }));

    const { runRuntime } = await import("./app.ts");
    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: mock(async () => ok({
            pushAudio: mock(async () => ok(undefined)),
            close: mock(async () => {}),
            events: (async function* () {})(),
        })),
    };

    const runPromise = runRuntime(engine, { debugEnabled: true });
    await new Promise((resolve) => setTimeout(resolve, 0));
    process.emit("SIGINT");
    await runPromise;

    expect(events).toEqual([
        "ibus:start",
        "ibus:service",
        "ibus:engine",
        "ibus:Auto-switch disabled, please manually switch to ASR input method",
        "ibus:ready",
        "ibus:runtime not ready: not ready",
        "keyStream:start",
        "ibus:stop",
        "app:Shutting down...",
    ]);
});

test("runtime creates an ibus engine after selecting the input source", async () => {
    const events: string[] = [];

    mock.module("./output.ts", () => ({
        ...outputModule,
        printKeyDevice: () => {},
        printKeyboardEvent: () => {},
        printKeyboardWait: () => {},
        printTimedDomain: (domain: string, message: string) => events.push(`${domain}:${message}`),
        printTimedDomainError: (domain: string, message: string) => events.push(`${domain}:${message}`),
    }));

    mock.module("./key.ts", () => ({
        ...keyModule,
        KEY_RIGHT_ALT: 100,
        findKeyboardDevice: async () => "/dev/input/event-test",
        createKeyStream: async function* (_devicePath: string, _keyCode: number, signal?: AbortSignal) {
            events.push("keyStream:start");
            while (!signal?.aborted) {
                await new Promise((resolve) => setTimeout(resolve, 0));
            }
        },
    }));

    mock.module("./ibus.ts", () => ({
        ...ibusModule,
        ensureIbusServiceRunning: async () => {
            events.push("ibus:service");
            return ok(undefined);
        },
        ensureIbusEngineSelected: async () => {
            events.push("ibus:engine");
            events.push("ibus:CreateEngine name=asr path=/org/freedesktop/IBus/Engine/ASR/0");
            return ok(undefined);
        },
        waitForIbusRuntimeReady: async () => {
            events.push("ibus:ready");
            return { error: new Error("IBus runtime did not become ready") } as never;
        },
    }));

    const { runRuntime } = await import("./app.ts");
    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: mock(async () => ok({
            pushAudio: mock(async () => ok(undefined)),
            close: mock(async () => {}),
            events: (async function* () {})(),
        })),
    };

    const runPromise = runRuntime(engine, { debugEnabled: true });
    await new Promise((resolve) => setTimeout(resolve, 0));
    process.emit("SIGINT");
    await runPromise;

    expect(events).toContain("ibus:engine");
    expect(events).toContain("ibus:CreateEngine name=asr path=/org/freedesktop/IBus/Engine/ASR/0");
    expect(events).toContain("ibus:runtime not ready: IBus runtime did not become ready");
});

test("runtime starts ibus service during normal startup", async () => {
    const events: string[] = [];

    mock.module("./output.ts", () => ({
        ...outputModule,
        printKeyDevice: () => {},
        printKeyboardEvent: () => {},
        printKeyboardWait: () => {},
        printTimedDomain: (domain: string, message: string) => events.push(`${domain}:${message}`),
        printTimedDomainError: (domain: string, message: string) => events.push(`${domain}:${message}`),
    }));

    mock.module("./key.ts", () => ({
        ...keyModule,
        KEY_RIGHT_ALT: 100,
        findKeyboardDevice: async () => "/dev/input/event-test",
        createKeyStream: async function* (_devicePath: string, _keyCode: number, signal?: AbortSignal) {
            events.push("keyStream:start");
            while (!signal?.aborted) {
                await new Promise((resolve) => setTimeout(resolve, 0));
            }
        },
    }));

    mock.module("./ibus.ts", () => ({
        ...ibusModule,
        startIbusService: async () => {
            events.push("ibus:start");
            return async () => {
                events.push("ibus:stop");
            };
        },
    }));

    const { runRuntime } = await import("./app.ts");
    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: mock(async () => ok({
            pushAudio: mock(async () => ok(undefined)),
            close: mock(async () => {}),
            events: (async function* () {})(),
        })),
    };

    const runPromise = runRuntime(engine, { debugEnabled: true });
    await new Promise((resolve) => setTimeout(resolve, 0));
    process.emit("SIGINT");
    await runPromise;

    expect(events[0]).toBe("ibus:start");
    expect(events).toContain("ibus:stop");
});

test("runtime keeps the ibus runtime check non-blocking after startup", async () => {
    const events: string[] = [];

    mock.module("./output.ts", () => ({
        ...outputModule,
        printKeyDevice: () => {},
        printKeyboardEvent: () => {},
        printKeyboardWait: () => {},
        printTimedDomain: (domain: string, message: string) => events.push(`${domain}:${message}`),
        printTimedDomainError: (domain: string, message: string) => events.push(`${domain}:${message}`),
    }));

    mock.module("./key.ts", () => ({
        ...keyModule,
        KEY_RIGHT_ALT: 100,
        findKeyboardDevice: async () => "/dev/input/event-test",
        createKeyStream: async function* (_devicePath: string, _keyCode: number, signal?: AbortSignal) {
            events.push("keyStream:start");
            while (!signal?.aborted) {
                await new Promise((resolve) => setTimeout(resolve, 0));
            }
        },
    }));

    mock.module("./ibus.ts", () => ({
        ...ibusModule,
        ensureIbusServiceRunning: async () => {
            events.push("ibus:service");
            return ok(undefined);
        },
        ensureIbusEngineSelected: async () => {
            events.push("ibus:engine");
            return ok(undefined);
        },
        waitForIbusRuntimeReady: async () => {
            events.push("ibus:ready");
            return ok(undefined);
        },
    }));

    const { runRuntime } = await import("./app.ts");
    const engine = {
        name: "mock",
        createClient: () => ({}),
        prepare: async () => ok(undefined),
        describe: () => [],
        startSession: mock(async () => ok({
            pushAudio: mock(async () => ok(undefined)),
            close: mock(async () => {}),
            events: (async function* () {})(),
        })),
    };

    const runPromise = runRuntime(engine, { debugEnabled: true });
    await new Promise((resolve) => setTimeout(resolve, 0));
    process.emit("SIGINT");
    await runPromise;

    expect(events).toContain("ibus:service");
    expect(events).toContain("ibus:ready");
    expect(events).toContain("keyStream:start");
});
