import { isErr, createAsyncQueue, type Result } from "../util.ts";
import type { RecognitionEngine, RecognitionEvent } from "./recognition.ts";
import type { RecognitionSession } from "./session.ts";

export interface DoubaoLifecycleHandlers {
    onSessionStart: () => void;
    onSessionStartFailed: (message: string) => void;
    onSessionStarted: () => void;
    onWriterOpen: () => void;
    onWriterClose: () => void;
    onPushFailed: (message: string) => void;
    onEvent: (event: RecognitionEvent) => Promise<void> | void;
}

export const startDoubaoLifecycle = <TClient>(
    engine: RecognitionEngine<TClient>,
    client: TClient,
    audioQueue: ReturnType<typeof createAsyncQueue<Uint8Array>>,
    stopSignal: AbortSignal,
    options: { debugEnabled?: boolean },
    handlers: {
        onSessionStart: () => void;
        onSessionStartFailed: (message: string) => void;
        onSessionStarted: () => void;
        onWriterOpen: () => void;
        onWriterClose: () => void;
        onPushFailed: (message: string) => void;
        onEvent: (event: RecognitionEvent) => Promise<void> | void;
    },
): Promise<void> => {
    return (async () => {
        handlers.onSessionStart();
        const sessionResult = await engine.startSession(client, { debugEnabled: options.debugEnabled });
        if (isErr(sessionResult)) {
            handlers.onSessionStartFailed(sessionResult.error.message);
            return;
        }

        const session = sessionResult.value;
        handlers.onSessionStarted();

        const writer = (async () => {
            handlers.onWriterOpen();
            await pushAudioQueue(session, audioQueue.iterator, stopSignal, handlers);
            await session.close();
            handlers.onWriterClose();
        })();

        await consumeRecognitionEvents(session.events, handlers);

        await writer;
    })();
};

const pushAudioQueue = async (
    session: RecognitionSession,
    iterator: AsyncIterator<Uint8Array>,
    stopSignal: AbortSignal,
    handlers: DoubaoLifecycleHandlers,
): Promise<void> => {
    const next = await iterator.next();
    if (next.done) return;
    const pushed = await pushAudioChunk(session, next.value, handlers);
    if (!pushed) return;
    if (stopSignal.aborted) return;
    await pushAudioQueue(session, iterator, stopSignal, handlers);
};

const pushAudioChunk = async (
    session: RecognitionSession,
    chunk: Uint8Array,
    handlers: DoubaoLifecycleHandlers,
): Promise<boolean> => {
    const pushResult = await session.pushAudio(chunk);
    if (!isErr(pushResult)) return true;
    handlers.onPushFailed(pushResult.error.message);
    return false;
};

const consumeRecognitionEvents = async (
    events: AsyncIterable<Result<RecognitionEvent>>,
    handlers: DoubaoLifecycleHandlers,
): Promise<void> => {
    const iterator = events[Symbol.asyncIterator]();
    await consumeRecognitionEventIterator(iterator, handlers);
};

const consumeRecognitionEventIterator = async (
    iterator: AsyncIterator<Result<RecognitionEvent>>,
    handlers: DoubaoLifecycleHandlers,
): Promise<void> => {
    const next = await iterator.next();
    if (next.done) return;
    const shouldContinue = await handleRecognitionQueueResult(next.value, handlers);
    if (!shouldContinue) return;
    await consumeRecognitionEventIterator(iterator, handlers);
};

const handleRecognitionQueueResult = async (
    result: Result<RecognitionEvent>,
    handlers: DoubaoLifecycleHandlers,
): Promise<boolean> => {
    if (isErr(result)) {
        await handlers.onEvent({ type: "error", message: result.error.message });
        return false;
    }
    await handlers.onEvent(result.value);
    return true;
};
