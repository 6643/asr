import { createMicStream } from "./mic.ts";
import { isErr, tryAsyncResult, withFinallyAsync } from "../util.ts";

const MIC_START_PEAK_THRESHOLD = 800;
const MIC_START_WARMUP_CHUNKS = 1;
const MIC_START_CONSECUTIVE_CHUNKS = 1;

const getPcmPeak = (chunk: Uint8Array): number => {
    let peak = 0;
    for (let i = 0; i + 1 < chunk.length; i += 2) {
        const lo = chunk[i] ?? 0;
        const hi = chunk[i + 1] ?? 0;
        const sample = (lo | (hi << 8)) << 16 >> 16;
        peak = Math.max(peak, Math.abs(sample));
    }
    return peak;
};

export interface MicLifecycleSummary {
    sawAudioChunk: boolean;
    chunkCount: number;
    byteCount: number;
    peak: number;
}

export interface MicLifecycleHandlers {
    onOpen: () => void;
    onReady: () => Promise<void> | void;
    onChunk: (chunk: Uint8Array) => void;
    onClose: (summary: MicLifecycleSummary) => void;
    onFailure: (error: Error) => void;
}

interface MicReadState extends MicLifecycleSummary {
    warmupChunks: number;
    voiceChunkStreak: number;
    readyNotified: boolean;
    pendingAudioChunks: Uint8Array[];
}

const createMicReadState = (): MicReadState => ({
    sawAudioChunk: false,
    chunkCount: 0,
    byteCount: 0,
    peak: 0,
    warmupChunks: 0,
    voiceChunkStreak: 0,
    readyNotified: false,
    pendingAudioChunks: [],
});

export const startMicLifecycle = (
    deps: { createMicStream: typeof createMicStream },
    stopSignal: AbortSignal,
    handlers: MicLifecycleHandlers,
): { task: Promise<void>; stop: () => void } => {
    const mic = deps.createMicStream({ signal: stopSignal });
    let stopped = false;

    const stop = (): void => {
        if (stopped) return;
        stopped = true;
        mic.stop();
    };

    const task = (async (): Promise<void> => {
        const state = createMicReadState();
        await withFinallyAsync(
            async () => {
                handlers.onOpen();
                const result = await tryAsyncResult(() => consumeMicChunks(mic, state, handlers, stopSignal));
                if (isErr(result)) handlers.onFailure(result.error);
            },
            () => {
                stop();
                handlers.onClose(state);
            },
        );
    })();

    return { task, stop };
};

const consumeMicChunks = async (
    mic: AsyncIterable<Uint8Array>,
    state: MicReadState,
    handlers: MicLifecycleHandlers,
    stopSignal: AbortSignal,
): Promise<void> => {
    const iterator = mic[Symbol.asyncIterator]();
    await consumeMicChunkIterator(iterator, state, handlers, stopSignal);
};

const consumeMicChunkIterator = async (
    iterator: AsyncIterator<Uint8Array>,
    state: MicReadState,
    handlers: MicLifecycleHandlers,
    stopSignal: AbortSignal,
): Promise<void> => {
    const next = await iterator.next();
    if (next.done) return;
    await handleMicChunk(next.value, state, handlers);
    if (stopSignal.aborted) return;
    await consumeMicChunkIterator(iterator, state, handlers, stopSignal);
};

const handleMicChunk = async (
    chunk: Uint8Array,
    state: MicReadState,
    handlers: MicLifecycleHandlers,
): Promise<void> => {
    recordMicChunk(state, chunk);
    const emittedAfterReady = await notifyMicReadyIfNeeded(chunk, state, handlers);
    if (emittedAfterReady) return;
    emitOrBufferMicChunk(chunk, state, handlers);
};

const recordMicChunk = (state: MicReadState, chunk: Uint8Array): void => {
    state.sawAudioChunk = true;
    state.chunkCount++;
    state.byteCount += chunk.length;
    state.peak = Math.max(state.peak, getPcmPeak(chunk));
    state.warmupChunks++;
};

const notifyMicReadyIfNeeded = async (
    chunk: Uint8Array,
    state: MicReadState,
    handlers: MicLifecycleHandlers,
): Promise<boolean> => {
    if (state.readyNotified) return false;
    if (state.warmupChunks <= MIC_START_WARMUP_CHUNKS) return false;
    updateVoiceChunkStreak(state, chunk);
    if (state.voiceChunkStreak < MIC_START_CONSECUTIVE_CHUNKS) return false;
    state.readyNotified = true;
    await handlers.onReady();
    flushPendingAudioChunks(state, handlers);
    handlers.onChunk(chunk);
    return true;
};

const updateVoiceChunkStreak = (state: MicReadState, chunk: Uint8Array): void => {
    const chunkPeak = getPcmPeak(chunk);
    if (chunkPeak < MIC_START_PEAK_THRESHOLD) {
        state.voiceChunkStreak = 0;
        return;
    }
    state.voiceChunkStreak++;
};

const flushPendingAudioChunks = (state: MicReadState, handlers: MicLifecycleHandlers): void => {
    for (const pendingChunk of state.pendingAudioChunks) {
        handlers.onChunk(pendingChunk);
    }
    state.pendingAudioChunks.length = 0;
};

const emitOrBufferMicChunk = (chunk: Uint8Array, state: MicReadState, handlers: MicLifecycleHandlers): void => {
    if (state.readyNotified) {
        handlers.onChunk(chunk);
        return;
    }
    state.pendingAudioChunks.push(chunk);
};
