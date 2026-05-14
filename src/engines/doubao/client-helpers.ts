import { isErr, ok, err, type Result } from "../../util.ts";
import { ResponseType, type ASRResponse } from "./types.ts";

export const isWsUrlSecure = (wsUrl: string): boolean => wsUrl.startsWith("wss://");

export const normalizeWsError = (error: unknown): Error => {
    if (error instanceof Error) return error;
    return new Error(`WebSocket connection failed: ${JSON.stringify(error ?? null)}`);
};

export const isRetryableSessionInitError = (message: string): boolean => {
    if (/StartSession 失败:\s*ExceededConcurrentQuota/.test(message)) {
        return false;
    }

    return /WebSocket connection failed|WebSocket error|StartTask 失败|StartSession 失败|ECONNREFUSED|ECONNRESET|ENOENT|ERR timeout/.test(
        message,
    );
};

export const shouldRetrySessionInit = (attempt: number, retryLimit: number, errorMessage: string): boolean => {
    return attempt < retryLimit && isRetryableSessionInitError(errorMessage);
};

export const createSessionRetryDelayMs = (attempt: number, baseDelayMs: number): number => baseDelayMs * attempt;

export const buildWebSocketInit = (headers: Record<string, string>): { headers: Record<string, string> } => ({ headers });

export const sliceOrPad = (source: Uint8Array, start: number, length: number): Uint8Array => {
    const slice = source.slice(start, start + length);
    if (slice.length < length) {
        const padded = new Uint8Array(length);
        padded.set(slice);
        return padded;
    }
    return slice;
};

export const waitForResponse = (ws: WebSocket, timeoutMs = 0): Promise<ArrayBuffer> => {
    return new Promise((resolve, reject) => {
        let timer: ReturnType<typeof setTimeout> | null = null;

        const onMessage = (event: MessageEvent) => {
            ws.removeEventListener("message", onMessage);
            ws.removeEventListener("error", onError);
            if (timer) clearTimeout(timer);
            resolve(event.data as ArrayBuffer);
        };
        const onError = (e: Event) => {
            ws.removeEventListener("error", onError);
            ws.removeEventListener("message", onMessage);
            if (timer) clearTimeout(timer);
            reject(new Error(`WebSocket error: ${JSON.stringify(e)}`));
        };
        ws.addEventListener("message", onMessage);
        ws.addEventListener("error", onError);

        if (timeoutMs > 0) {
            timer = setTimeout(() => {
                ws.removeEventListener("message", onMessage);
                ws.removeEventListener("error", onError);
                reject(new Error("ERR timeout"));
            }, timeoutMs);
        }
    });
};

export interface ReadableResponseEvent {
    response: ASRResponse;
    completed: boolean;
}

export const consumeReadableResponses = async function* (
    readable: ReadableStream<Result<ASRResponse>>,
    options?: {
        stopOnFinal?: boolean;
        stopOnSessionFinished?: boolean;
        onErrorResponse?: (message: string) => void;
    },
): AsyncGenerator<Result<ReadableResponseEvent>, void, unknown> {
    yield* consumeReadableResponseIterator(readable[Symbol.asyncIterator](), options);
};

const consumeReadableResponseIterator = async function* (
    iterator: AsyncIterator<Result<ASRResponse>>,
    options?: {
        stopOnFinal?: boolean;
        stopOnSessionFinished?: boolean;
        onErrorResponse?: (message: string) => void;
    },
): AsyncGenerator<Result<ReadableResponseEvent>, void, unknown> {
    const next = await iterator.next();
    if (next.done) return;
    const event = createReadableResponseEvent(next.value, options);
    if (event.result !== null) yield event.result;
    if (event.stop) return;
    yield* consumeReadableResponseIterator(iterator, options);
};

const createReadableResponseEvent = (
    responseResult: Result<ASRResponse>,
    options?: {
        stopOnFinal?: boolean;
        stopOnSessionFinished?: boolean;
        onErrorResponse?: (message: string) => void;
    },
): { result: Result<ReadableResponseEvent> | null; stop: boolean } => {
    if (isErr(responseResult)) return { result: err(responseResult.error), stop: true };

    const response = responseResult.value;
    if (response.type === ResponseType.HEARTBEAT) return { result: null, stop: false };

    if (response.type === ResponseType.ERROR) options?.onErrorResponse?.(response.error_msg || "Unknown error");

    const completed =
        response.type === ResponseType.ERROR ||
        (options?.stopOnSessionFinished === true && response.type === ResponseType.SESSION_FINISHED) ||
        (options?.stopOnFinal === true && response.type === ResponseType.FINAL_RESULT);

    return { result: ok({ response, completed }), stop: completed };
};
