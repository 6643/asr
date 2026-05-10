import { createMicStream } from "./mic.ts";
import { commitText } from "./commit.ts";
import { muteSpeaker, unmuteSpeaker } from "./mute.ts";
import { playMicReadyNotification } from "./notify.ts";
import {
    printAsrError,
    printIbusCommitFailure,
    printIbusCommitSuccess,
    printFinal,
    printRecognitionError,
    printInterim,
    printSessionStart,
    printVadStart,
} from "./output.ts";
import type { RecognitionEngine } from "./recognition.ts";

const ASR_TEXT_MAX_LENGTH = 4096;
const KEY_RELEASE_GRACE_MS = 300;

const sanitizeAsrText = (text: string): string => {
    const sanitized = text.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "").trim();
    return sanitized.length > ASR_TEXT_MAX_LENGTH ? sanitized.slice(0, ASR_TEXT_MAX_LENGTH) : sanitized;
};

const debugSession = (enabled: boolean, message: string): void => {
    if (!enabled) return;
    console.log(`[session] ${message}`);
};

const createAsyncQueue = <T>() => {
    const items: T[] = [];
    let closed = false;
    let wake: (() => void) | null = null;

    const push = (value: T): void => {
        if (closed) return;
        items.push(value);
        wake?.();
        wake = null;
    };

    const close = (): void => {
        closed = true;
        wake?.();
        wake = null;
    };

    const iterator = (async function* (): AsyncGenerator<T> {
        for (;;) {
            if (items.length > 0) {
                yield items.shift() as T;
                continue;
            }

            if (closed) return;

            await new Promise<void>((resolve) => {
                wake = resolve;
            });
        }
    })();

    return { push, close, iterator };
};

export const runRecognitionSession = async <TClient>(
    engine: RecognitionEngine<TClient>,
    client: TClient,
    stopSignal: AbortSignal,
    options: { debugEnabled?: boolean } = {},
): Promise<void> => {
    const debugEnabled = options.debugEnabled ?? false;
    const mic = createMicStream();
    const audioQueue = createAsyncQueue<Uint8Array>();
    let sawAudioChunk = false;
    let micReadyNotified = false;
    let micStopped = false;
    const stopMic = (): void => {
        if (micStopped) return;
        micStopped = true;
        mic.stop();
    };
    const cleanup = async (): Promise<void> => {
        audioQueue.close();
        stopMic();
        await audioPump.catch(() => {});
        unmuteSpeaker();
    };
    const audioPump = (async () => {
        debugSession(debugEnabled, "mic: begin");
        try {
            for await (const chunk of mic) {
                sawAudioChunk = true;
                if (!micReadyNotified) {
                    micReadyNotified = true;
                    debugSession(debugEnabled, "mic: ready");
                    await playMicReadyNotification().catch(() => {});
                    muteSpeaker();
                }
                audioQueue.push(chunk);
                if (stopSignal.aborted) break;
            }
        } finally {
            audioQueue.close();
            debugSession(debugEnabled, "mic: closed");
        }
    })();

    printSessionStart();

    let sawAnyResult = false;
    let sawRecognitionError = false;
    debugSession(debugEnabled, "startSession: begin");
    try {
        const [session, sessionError] = await engine.startSession(client);
        if (sessionError !== null) {
            debugSession(debugEnabled, `startSession: failed: ${sessionError.message}`);
            printRecognitionError(sessionError.message);
            return;
        }

        debugSession(debugEnabled, "startSession: ok");

        const writer = (async () => {
            debugSession(debugEnabled, "writer: begin");
            for await (const chunk of audioQueue.iterator) {
                await session.pushAudio(chunk);
                if (stopSignal.aborted) break;
            }
            await session.close();
            debugSession(debugEnabled, "writer: closed");
        })();

        for await (const [resp, eventError] of session.events) {
            if (eventError !== null) {
                debugSession(debugEnabled, `events: error: ${eventError.message}`);
                printRecognitionError(eventError.message);
                sawRecognitionError = true;
                break;
            }

            debugSession(debugEnabled, `events: ${resp.type}`);
            switch (resp.type) {
                case "interim":
                    sawAnyResult = true;
                    printInterim(sanitizeAsrText(resp.text || ""));
                    break;
                case "final": {
                    sawAnyResult = true;
                    const text = sanitizeAsrText(resp.text || "");
                    printFinal(text);
                    const res = await commitText(text);
                    if (res.success) {
                        printIbusCommitSuccess();
                    } else {
                        printIbusCommitFailure(res.message);
                    }
                    break;
                }
                case "error":
                    sawAnyResult = true;
                    printAsrError(resp.message || "Unknown error");
                    break;
                case "vad":
                    sawAnyResult = true;
                    printVadStart();
                    break;
                case "session_finished":
                    break;
            }
        }
        await writer;

        if (!sawAnyResult && !sawRecognitionError) {
            debugSession(debugEnabled, "no results");
            printRecognitionError(sawAudioChunk ? "未收到识别结果" : "未收到音频");
        }
    } finally {
        await cleanup();
    }
};
