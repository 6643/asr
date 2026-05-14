import { isErr, ok, err, tryAsyncResult, trySyncResult, type Result, createAsyncQueue, withFinallyAsync } from "../../util.ts";
import type { RecognitionEvent } from "../../runtime/recognition.ts";
import type { RecognitionSession } from "../../runtime/session.ts";
import { ResponseType, type ASRResponse } from "./types.ts";
import type { Client } from "./client.ts";

const MAX_AUDIO_QUEUE_ITEMS = 64;
const MAX_EVENT_QUEUE_ITEMS = 32;


export type TranscribeRealtimeSource = (
    client: Client,
    audio: AsyncIterable<Uint8Array>,
    options?: { debugEnabled?: boolean },
) => AsyncGenerator<Result<ASRResponse>>;

const defaultTranscribeRealtimeSource: TranscribeRealtimeSource = async function* (
    client: Client,
    audio: AsyncIterable<Uint8Array>,
    options?: { debugEnabled?: boolean },
) {
    const { transcribeRealtime } = await import("./client.ts");
    yield* transcribeRealtime(client, audio, options);
};

export const retryableTranscribeRealtime = async function* (
    source: TranscribeRealtimeSource,
    client: Client,
    audio: AsyncIterable<Uint8Array>,
    options?: { debugEnabled?: boolean },
): AsyncGenerator<Result<ASRResponse>> {
    const responses = trySyncResult(() => source(client, audio, options));
    if (isErr(responses)) {
        yield err(responses.error);
        return;
    }
    yield* consumeRetryableTranscribeRealtime(responses.value[Symbol.asyncIterator]());
};

const consumeRetryableTranscribeRealtime = async function* (
    iterator: AsyncIterator<Result<ASRResponse>>,
): AsyncGenerator<Result<ASRResponse>> {
    const nextResult = await tryAsyncResult(() => iterator.next());
    if (isErr(nextResult)) {
        yield err(nextResult.error);
        return;
    }
    const next = nextResult.value;
    if (next.done) return;
    if (isErr(next.value)) {
        yield next.value;
        return;
    }
    yield ok(next.value.value);
    yield* consumeRetryableTranscribeRealtime(iterator);
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

export const createDoubaoSession = (
    client: Client,
    options?: { debugEnabled?: boolean; transcribeRealtime?: TranscribeRealtimeSource },
): Result<RecognitionSession> => {
    const audioQueue = createAsyncQueue<Uint8Array>(MAX_AUDIO_QUEUE_ITEMS);
    const eventQueue = createAsyncQueue<Result<RecognitionEvent>>(MAX_EVENT_QUEUE_ITEMS);
    const source = options?.transcribeRealtime ?? defaultTranscribeRealtimeSource;

    const pushRecognitionEvent = (resp: ASRResponse): void => {
        switch (resp.type) {
            case ResponseType.INTERIM_RESULT:
                eventQueue.push(ok(toRecognitionEvent("interim", resp.text || "")));
                break;
            case ResponseType.FINAL_RESULT:
                eventQueue.push(ok(toRecognitionEvent("final", resp.text || "")));
                break;
            case ResponseType.ERROR:
                eventQueue.push(ok(toRecognitionEvent("error", "", resp.error_msg || "Unknown error")));
                break;
            case ResponseType.VAD_START:
                eventQueue.push(ok(toRecognitionEvent("vad")));
                break;
            case ResponseType.SESSION_FINISHED:
                eventQueue.push(ok(toRecognitionEvent("session_finished")));
                break;
            default:
                break;
        }
    };

    void consumeTranscriptionEventsSafely(
        retryableTranscribeRealtime(source, client, audioQueue.iterator, options),
        pushRecognitionEvent,
        eventQueue,
    );

    return ok<RecognitionSession>({
        pushAudio: async (chunk: Uint8Array) => {
            if (!audioQueue.push(chunk)) {
                return err(new Error("Audio queue is full or closed"));
            }
            return ok(undefined);
        },
        close: async () => {
            audioQueue.close();
        },
        events: eventQueue.iterator,
    });
};

const consumeTranscriptionEventsSafely = async (
    responses: AsyncIterable<Result<ASRResponse>>,
    pushRecognitionEvent: (resp: ASRResponse) => void,
    eventQueue: ReturnType<typeof createAsyncQueue<Result<RecognitionEvent>>>,
): Promise<void> => {
    await withFinallyAsync(async () => {
        const result = await tryAsyncResult(() => consumeTranscriptionEvents(responses, pushRecognitionEvent, eventQueue));
        if (isErr(result)) eventQueue.push(err(result.error));
    }, () => {
        eventQueue.close();
    });
};

const consumeTranscriptionEvents = async (
    responses: AsyncIterable<Result<ASRResponse>>,
    pushRecognitionEvent: (resp: ASRResponse) => void,
    eventQueue: ReturnType<typeof createAsyncQueue<Result<RecognitionEvent>>>,
): Promise<void> => {
    await consumeTranscriptionEventIterator(responses[Symbol.asyncIterator](), pushRecognitionEvent, eventQueue);
};

const consumeTranscriptionEventIterator = async (
    iterator: AsyncIterator<Result<ASRResponse>>,
    pushRecognitionEvent: (resp: ASRResponse) => void,
    eventQueue: ReturnType<typeof createAsyncQueue<Result<RecognitionEvent>>>,
): Promise<void> => {
    const next = await iterator.next();
    if (next.done) return;
    pushTranscriptionResult(next.value, pushRecognitionEvent, eventQueue);
    await consumeTranscriptionEventIterator(iterator, pushRecognitionEvent, eventQueue);
};

const pushTranscriptionResult = (
    resp: Result<ASRResponse>,
    pushRecognitionEvent: (resp: ASRResponse) => void,
    eventQueue: ReturnType<typeof createAsyncQueue<Result<RecognitionEvent>>>,
): void => {
    if (isErr(resp)) {
        eventQueue.push(resp);
        return;
    }
    pushRecognitionEvent(resp.value);
};
