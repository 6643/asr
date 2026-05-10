import { ok, err, type Result } from "../../util.ts";
import type { RecognitionEvent } from "../../runtime/recognition.ts";
import type { RecognitionSession } from "../../runtime/session.ts";
import { ResponseType, type ASRResponse } from "./types.ts";
import type { Client } from "./client.ts";

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

const retryableTranscribeRealtime = async function* (
    client: Client,
    audio: AsyncIterable<Uint8Array>,
): AsyncGenerator<Result<ASRResponse>> {
    const { transcribeRealtime } = await import("./client.ts");

    try {
        for await (const [response, responseError] of transcribeRealtime(client, audio)) {
            if (responseError !== null) {
                yield err(responseError);
                return;
            }

            yield ok(response);
        }
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        yield err(new Error(message)) as Result<ASRResponse>;
    }
};

const toRecognitionEvent = (type: RecognitionEvent["type"], text = "", message = ""): RecognitionEvent => {
    switch (type) {
        case "interim":
            return { type, text };
        case "final":
            return { type, text };
        case "error":
            return { type, message };
        case "vad":
        case "session_finished":
            return { type };
    }
};

export const createDoubaoSession = (client: Client): Result<RecognitionSession> => {
    const audioQueue = createAsyncQueue<Uint8Array>();
    const events = (async function* (): AsyncGenerator<Result<RecognitionEvent>> {
        for await (const [resp, responseError] of retryableTranscribeRealtime(client, audioQueue.iterator)) {
            if (responseError !== null) {
                yield err(responseError) as Result<RecognitionEvent>;
                continue;
            }

            switch (resp.type) {
                case ResponseType.INTERIM_RESULT:
                    yield ok(toRecognitionEvent("interim", resp.text || ""));
                    break;
                case ResponseType.FINAL_RESULT:
                    yield ok(toRecognitionEvent("final", resp.text || ""));
                    break;
                case ResponseType.ERROR:
                    yield ok(toRecognitionEvent("error", "", resp.error_msg || "Unknown error"));
                    break;
                case ResponseType.VAD_START:
                    yield ok(toRecognitionEvent("vad"));
                    break;
                case ResponseType.SESSION_FINISHED:
                    yield ok(toRecognitionEvent("session_finished"));
                    break;
                default:
                    break;
            }
        }
    })();

    return ok<RecognitionSession>({
        pushAudio: async (chunk: Uint8Array) => {
            audioQueue.push(chunk);
        },
        close: async () => {
            audioQueue.close();
        },
        events,
    });
};
