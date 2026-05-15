// 麦克风音频捕获

import { ignoreError, isErr, tryAsyncResult } from "../util.ts";

const DEFAULT_SAMPLE_RATE = 16000;
const DEFAULT_CHANNELS = 1;
const FRAME_DURATION_MS = 100;

export const getMicFrameBytes = (sampleRate: number, channels: number): number => {
    return Math.floor((sampleRate * FRAME_DURATION_MS) / 1000) * channels * 2;
};

const drainStderr = async (stream: ReadableStream<Uint8Array>, onStderr: (message: string) => void): Promise<void> => {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    try {
        await drainStderrReader(reader, decoder, onStderr);
    } finally {
        releaseReadableReader(reader);
    }
};

const drainStderrReader = async (
    reader: ReadableStreamDefaultReader<Uint8Array>,
    decoder: TextDecoder,
    onStderr: (message: string) => void,
): Promise<void> => {
    const result = await tryAsyncResult(() => reader.read());
    if (isErr(result) || result.value.done) return;
    emitStderrChunk(result.value.value, decoder, onStderr);
    await drainStderrReader(reader, decoder, onStderr);
};

const emitStderrChunk = (
    value: Uint8Array | undefined,
    decoder: TextDecoder,
    onStderr: (message: string) => void,
): void => {
    if (!value) return;
    onStderr(decoder.decode(value, { stream: true }));
};

const releaseReadableReader = (reader: ReadableStreamDefaultReader<Uint8Array>): void => {
    ignoreError(() => reader.releaseLock());
};

// 从麦克风捕获音频流（Linux arecord）
export const createMicStream = (
    options: { sampleRate?: number; channels?: number; signal?: AbortSignal; onStderr?: (message: string) => void } = {},
): AsyncGenerator<Uint8Array> & { stop: () => void } => {
    const sampleRate = options.sampleRate ?? DEFAULT_SAMPLE_RATE;
    const channels = options.channels ?? DEFAULT_CHANNELS;
    const frameBytes = getMicFrameBytes(sampleRate, channels);
    let proc: ReturnType<typeof Bun.spawn> | null = null;
    let stopped = false;

    const stop = () => {
        stopped = true;
        if (proc) {
            proc.kill();
            proc = null;
        }
    };

    if (options.signal) {
        options.signal.addEventListener("abort", stop, { once: true });
    }

    const generator = async function* (): AsyncGenerator<Uint8Array> {
        proc = Bun.spawn(["arecord", "-f", "S16_LE", "-r", String(sampleRate), "-c", String(channels), "-t", "raw"], {
            stdout: "pipe",
            stderr: options.onStderr ? "pipe" : "ignore",
        });

        if (options.onStderr && proc.stderr && typeof proc.stderr !== "number") {
            void drainStderr(proc.stderr as ReadableStream<Uint8Array>, options.onStderr);
        }

        if (!proc.stdout || typeof proc.stdout === "number") {
            stop();
            return;
        }

        const stream = proc.stdout as ReadableStream<Uint8Array>;
        const reader = stream.getReader();

        const state = { buffer: new Uint8Array(0) };

        try {
            yield* readMicFrames(reader, state, frameBytes, () => stopped);
        } finally {
            releaseReadableReader(reader);
            proc?.kill();
            proc = null;
        }
    };

    return Object.assign(generator(), { stop });
};

const readMicFrames = async function* (
    reader: ReadableStreamDefaultReader<Uint8Array>,
    state: { buffer: Uint8Array },
    frameBytes: number,
    isStopped: () => boolean,
): AsyncGenerator<Uint8Array> {
    while (!isStopped()) {
        yield* readNextMicFrameBatch(reader, state, frameBytes, isStopped);
    }
};

const readNextMicFrameBatch = async function* (
    reader: ReadableStreamDefaultReader<Uint8Array>,
    state: { buffer: Uint8Array },
    frameBytes: number,
    isStopped: () => boolean,
): AsyncGenerator<Uint8Array> {
    const shouldStop = await processMicChunk(reader, state, frameBytes);
    if (shouldStop) {
        yield* createFinalMicFrame(state, frameBytes, isStopped);
        return;
    }
    yield* takeBufferedMicFrames(state, frameBytes);
};

const processMicChunk = async (
    reader: ReadableStreamDefaultReader<Uint8Array>,
    state: { buffer: Uint8Array },
    frameBytes: number,
): Promise<boolean> => {
    const result = await tryAsyncResult(() => reader.read());
    if (isErr(result) || result.value.done) return true;
    appendMicBuffer(state, result.value.value ?? new Uint8Array(0), frameBytes);
    return false;
};

const appendMicBuffer = (state: { buffer: Uint8Array }, value: Uint8Array, frameBytes: number): void => {
    if (value.length === 0) return;
    const totalLength = state.buffer.length + value.length;
    const newBuffer = new Uint8Array(totalLength);
    newBuffer.set(state.buffer);
    newBuffer.set(value, state.buffer.length);
    state.buffer = newBuffer;
};

const takeBufferedMicFrames = function* (
    state: { buffer: Uint8Array },
    frameBytes: number,
): Generator<Uint8Array> {
    while (state.buffer.length >= frameBytes) {
        const frame = state.buffer.slice(0, frameBytes);
        state.buffer = state.buffer.slice(frameBytes);
        yield frame;
    }
};

const createFinalMicFrame = function* (
    state: { buffer: Uint8Array },
    frameBytes: number,
    isStopped: () => boolean,
): Generator<Uint8Array> {
    if (isStopped()) return;
    if (state.buffer.length === 0) return;
    const padded = new Uint8Array(frameBytes);
    padded.set(state.buffer);
    yield padded;
};
