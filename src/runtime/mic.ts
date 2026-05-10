// 麦克风音频捕获

import { tryResult } from "../util.ts";

const DEFAULT_SAMPLE_RATE = 16000;
const DEFAULT_CHANNELS = 1;
const FRAME_DURATION_MS = 20;
const FRAME_BYTES = (DEFAULT_SAMPLE_RATE * FRAME_DURATION_MS) / 1000 * 2;

// 从麦克风捕获音频流（Linux arecord）
export const createMicStream = (
    options: { sampleRate?: number; channels?: number; signal?: AbortSignal } = {},
): AsyncGenerator<Uint8Array> & { stop: () => void } => {
    const sampleRate = options.sampleRate ?? DEFAULT_SAMPLE_RATE;
    const channels = options.channels ?? DEFAULT_CHANNELS;
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
            stderr: "ignore",
        });

        if (!proc.stdout || typeof proc.stdout === "number") {
            throw new Error("arecord stdout is null");
        }

        const stream = proc.stdout as ReadableStream<Uint8Array>;
        const reader = stream.getReader();

        let buffer = new Uint8Array(0);

        try {
            for (;;) {
                if (stopped) break;

                const [result, readError] = await tryResult<{ done: boolean; value?: Uint8Array }>(reader.read());
                if (readError !== null || result.done) break;

                const value = result.value!;

                const newBuffer = new Uint8Array(buffer.length + value.length);
                newBuffer.set(buffer);
                newBuffer.set(value, buffer.length);
                buffer = newBuffer;

                while (buffer.length >= FRAME_BYTES) {
                    if (stopped) break;
                    const frame = buffer.slice(0, FRAME_BYTES);
                    buffer = buffer.slice(FRAME_BYTES);
                    yield frame;
                }
            }

            if (!stopped && buffer.length > 0) {
                const padded = new Uint8Array(FRAME_BYTES);
                padded.set(buffer);
                yield padded;
            }
        } finally {
            try {
                reader.releaseLock();
            } catch {
                // ignore
            }
            proc?.kill();
            proc = null;
        }
    };

    return Object.assign(generator(), { stop });
};
