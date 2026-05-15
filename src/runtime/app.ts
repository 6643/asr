import { createKeyStream, KEY_RIGHT_ALT, findKeyboardDevice } from "./key.ts";
import { ensureIbusEngineSelected, ensureIbusServiceRunning, initIbusRuntime, startIbusService, waitForIbusRuntimeReady } from "./ibus.ts";
import { printKeyDevice, printKeyboardEvent, printKeyboardWait, logInfo, logWarn, logError } from "./output.ts";
import { runRecognitionSession } from "./session-runner.ts";
import type { RecognitionEngine } from "./recognition.ts";
import { createControlLoop } from "./control.ts";
import { err, isErr, ok, type Result, tryAsyncResult, withFinallyAsync } from "../util.ts";
import { isAutoSwitchEnabled } from "./config.ts";

const switchToAsrInputMethod = async (): Promise<Result<void>> => {
    const switchResult = await tryAsyncResult(async () => {
        const proc = Bun.spawn(["ibus", "engine", "asr"], {
            stdout: "pipe",
            stderr: "pipe",
        });
        await proc.exited;
        if (proc.exitCode !== 0) {
            const stderr = await new Response(proc.stderr).text();
            throw new Error(stderr.trim());
        }
    });
    if (isErr(switchResult)) return err(switchResult.error);
    return ok(undefined);
};

const handleAutoSwitch = async (abortIbusStartup: (message: string) => void): Promise<boolean> => {
    if (!isAutoSwitchEnabled()) {
        logInfo("ibus", "Auto-switch disabled, please manually switch to ASR input method");
        return true;
    }

    const switchResult = await switchToAsrInputMethod();
    if (isErr(switchResult)) {
        abortIbusStartup(`Initialization failed: failed to switch input method: ${switchResult.error.message}`);
        return false;
    }
    logInfo("ibus", "Switched to ASR input method");
    return true;
};

const printEngineDescription = (line: string): void => {
    const match = line.match(/^\[([^\]]+)\]\s*(.*)$/);
    if (!match?.[1]) {
        logInfo("app", line);
        return;
    }

    logInfo(match[1], match[2] || "");
};

export const runRuntime = async <TClient>(
    engine: RecognitionEngine<TClient>,
    options: { debugEnabled?: boolean } = {},
): Promise<void> => {
    const client = engine.createClient();
    const prepareResult = await engine.prepare(client);
    if (isErr(prepareResult)) {
        logError("app", `Initialization failed: ${prepareResult.error.message}`);
        return;
    }

    for (const line of engine.describe(client)) {
        printEngineDescription(line);
    }

    const keyboardDevice = await findKeyboardDevice();
    if (!keyboardDevice) {
        logError("app", "Initialization failed: keyboard device not found");
        return;
    }
    printKeyDevice(keyboardDevice);

    const initIbusResult = await initIbusRuntime();
    if (isErr(initIbusResult)) {
        logError("ibus", `Initialization failed: ${initIbusResult.error.message}`);
        return;
    }

    const stopIbusServiceResult = await tryAsyncResult(() => startIbusService());
    if (isErr(stopIbusServiceResult)) {
        logError("ibus", `Initialization failed: ${stopIbusServiceResult.error.message}`);
        return;
    }

    const control = createControlLoop({
        startSession: async () => {
            const abort = new AbortController();
            const release = new AbortController();
            const done = runRecognitionSession(engine, client, abort.signal, {
                ...options,
                releaseSignal: release.signal,
            });
            return {
                release: async () => {
                    release.abort();
                },
                stop: async () => {
                    abort.abort();
                },
                done,
            };
        },
    });

    const stopController = new AbortController();
    const stopSignal = stopController.signal;
    const onStop = (): void => stopController.abort();
    process.on("SIGINT", onStop);
    process.on("SIGTERM", onStop);

    const startKeyLoop = async (): Promise<void> => {
        printKeyboardWait("down", "RightAlt");
        const result = await tryAsyncResult(() => consumeKeyEvents(createKeyStream(keyboardDevice, KEY_RIGHT_ALT, stopSignal), control.signal));
        if (!isErr(result)) return;
        logError("kbd", `stream failed: ${result.error.message}`);
        stopController.abort();
    };
    let keyLoop: Promise<void> | null = null;

    await withFinallyAsync(async () => {
        const serviceReady = await ensureIbusServiceRunning();
        if (isErr(serviceReady)) {
            abortIbusStartup(`Initialization failed: ${serviceReady.error.message}`);
            return;
        }

        const engineSelected = await ensureIbusEngineSelected();
        if (isErr(engineSelected)) {
            abortIbusStartup(`Initialization failed: ${engineSelected.error.message}`);
            return;
        }

        const switchSuccess = await handleAutoSwitch(abortIbusStartup);
        if (!switchSuccess) return;

        const runtimeReady = await waitForIbusRuntimeReady();
        if (isErr(runtimeReady)) {
            logWarn("ibus", `runtime not ready: ${runtimeReady.error.message}`);
        }

        keyLoop = startKeyLoop();
        await waitForStopSignal(stopSignal);
        await control.signal("shutdown");
        await keyLoop;
        await stopIbusServiceResult.value();
        logInfo("app", "Shutting down...");
    }, async () => {
        await waitForKeyLoop(keyLoop);
        process.removeListener("SIGINT", onStop);
        process.removeListener("SIGTERM", onStop);
    });
};

const consumeKeyEvents = async (
    events: AsyncIterable<"press" | "release">,
    signal: (event: "start" | "stop" | "shutdown") => Promise<void>,
): Promise<void> => {
    await consumeKeyEventIterator(events[Symbol.asyncIterator](), signal);
};

const consumeKeyEventIterator = async (
    iterator: AsyncIterator<"press" | "release">,
    signal: (event: "start" | "stop" | "shutdown") => Promise<void>,
): Promise<void> => {
    const next = await iterator.next();
    if (next.done) return;
    emitKeyControlSignal(next.value, signal);
    await consumeKeyEventIterator(iterator, signal);
};

const emitKeyControlSignal = (
    event: "press" | "release",
    signal: (event: "start" | "stop" | "shutdown") => Promise<void>,
): void => {
    if (event === "press") {
        printKeyboardEvent("press");
        void signal("start").catch(() => {}); // fire-and-forget, errors logged by signal handler
        return;
    }
    printKeyboardEvent("release");
    void signal("stop").catch(() => {}); // fire-and-forget, errors logged by signal handler
};

const abortIbusStartup = (message: string): boolean => {
    logError("ibus", message);
    return false;
};

const waitForStopSignal = (stopSignal: AbortSignal): Promise<void> => {
    if (stopSignal.aborted) return Promise.resolve();
    return new Promise<void>((resolve) => {
        stopSignal.addEventListener("abort", () => resolve(), { once: true });
    });
};

const waitForKeyLoop = async (keyLoop: Promise<void> | null): Promise<void> => {
    if (keyLoop === null) return;
    await keyLoop;
};
