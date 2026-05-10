import { createKeyStream, KEY_RIGHT_ALT, findKeyboardDevice } from "./key.ts";
import {
    ensureIbusEngineSelected,
    ensureIbusServiceRunning,
    waitForIbusRuntimeReady,
} from "./ibus.ts";
import { printInitError, printKeyDevice } from "./output.ts";
import { runRecognitionSession } from "./session-runner.ts";
import type { RecognitionEngine } from "./recognition.ts";
import { createControlLoop } from "./control.ts";

export const runRuntime = async <TClient>(
    engine: RecognitionEngine<TClient>,
    options: { debugEnabled?: boolean } = {},
): Promise<void> => {
    const client = engine.createClient();
    const [, prepareError] = await engine.prepare(client);
    if (prepareError !== null) {
        printInitError("初始化失败", prepareError.message);
        return;
    }

    for (const line of engine.describe(client)) {
        console.log(line);
    }

    const keyboardDevice = await findKeyboardDevice();
    if (!keyboardDevice) {
        printInitError("初始化失败", "未找到键盘设备");
        return;
    }
    printKeyDevice(keyboardDevice);

    const [, serviceError] = await ensureIbusServiceRunning();
    if (serviceError !== null) {
        printInitError("IBus 初始化失败", serviceError.message);
        return;
    }

    const [, ibusError] = await ensureIbusEngineSelected();
    if (ibusError !== null) {
        printInitError("IBus 初始化失败", ibusError.message);
        return;
    }

    const [, readyError] = await waitForIbusRuntimeReady();
    if (readyError !== null) {
        printInitError("IBus 初始化失败", readyError.message);
        return;
    }

    const control = createControlLoop({
        startSession: async () => {
            const abort = new AbortController();
            const done = runRecognitionSession(engine, client, abort.signal, options);
            return {
                stop: async () => {
                    abort.abort();
                },
                done,
            };
        },
    });

    const stopController = new AbortController();
    const stopSignal = stopController.signal;
    process.on("SIGINT", () => stopController.abort());
    process.on("SIGTERM", () => stopController.abort());

    (async () => {
        for await (const event of createKeyStream(keyboardDevice, KEY_RIGHT_ALT, stopSignal)) {
            if (event === "press") {
                void control.signal("start").catch(() => {});
            } else {
                void control.signal("stop").catch(() => {});
            }
        }
    })();

    try {
        await new Promise<void>((_, reject) => {
            if (stopSignal.aborted) reject(new Error("shutdown"));
            stopSignal.addEventListener("abort", () => reject(new Error("shutdown")), { once: true });
        });
    } catch (e) {
        if ((e instanceof Error) && e.message === "shutdown") {
            await control.signal("shutdown");
            console.log("\nShutting down...");
        } else {
            throw e;
        }
    }
};
