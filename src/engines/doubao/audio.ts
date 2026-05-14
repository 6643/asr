// 音频处理

import type { Config } from "./config.ts";
import { err, isErr, ok, type Result } from "../../util.ts";

// WAV 文件头结构
interface WavHeader {
    sampleRate: number;
    channels: number;
    bitsPerSample: number;
    dataSize: number;
}

interface WavParseState extends WavHeader {
    offset: number;
}

interface WavChunk {
    id: string;
    size: number;
    offset: number;
}

// 解析 WAV 文件头
const parseWavHeader = (data: Uint8Array): Result<WavHeader> => {
    if (data.length < 12) {
        return err(new Error("Not a valid WAV file: file too short"));
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);

    // 检查 "RIFF" 标记
    const riff = String.fromCharCode(data[0]!, data[1]!, data[2]!, data[3]!);
    if (riff !== "RIFF") {
        return err(new Error("Not a valid WAV file: missing RIFF header"));
    }

    // 检查 "WAVE" 标记
    const wave = String.fromCharCode(data[8]!, data[9]!, data[10]!, data[11]!);
    if (wave !== "WAVE") {
        return err(new Error("Not a valid WAV file: missing WAVE header"));
    }

    return parseWavChunks(data, view, { offset: 12, sampleRate: 0, channels: 0, bitsPerSample: 0, dataSize: 0 });
};

const parseWavChunks = (data: Uint8Array, view: DataView, state: WavParseState): Result<WavHeader> => {
    if (state.offset >= data.length) return ok(state);
    const chunk = readWavChunk(data, view, state.offset);
    if (isErr(chunk)) return err(chunk.error);
    const nextState = applyWavChunk(view, state, chunk.value);
    if (isErr(nextState)) return err(nextState.error);
    if (chunk.value.id === "data") return ok(nextState.value);
    return parseWavChunks(data, view, nextState.value);
};

const readWavChunk = (data: Uint8Array, view: DataView, offset: number): Result<WavChunk> => {
    if (offset + 8 > data.length) return err(new Error("Not a valid WAV file: truncated chunk header"));
    const id = String.fromCharCode(data[offset]!, data[offset + 1]!, data[offset + 2]!, data[offset + 3]!);
    const size = view.getUint32(offset + 4, true);
    if (offset + 8 + size > data.length) return err(new Error(`Not a valid WAV file: truncated ${id} chunk`));
    return ok({ id, size, offset });
};

const applyWavChunk = (view: DataView, state: WavParseState, chunk: WavChunk): Result<WavParseState> => {
    if (chunk.id === "fmt ") return applyFormatWavChunk(view, state, chunk);
    if (chunk.id === "data") return ok({ ...state, dataSize: chunk.size });
    return ok({ ...state, offset: nextWavChunkOffset(chunk) });
};

const applyFormatWavChunk = (view: DataView, state: WavParseState, chunk: WavChunk): Result<WavParseState> => {
    const audioFormat = view.getUint16(chunk.offset + 8, true);
    if (audioFormat !== 1 && audioFormat !== 3) {
        return err(new Error(`Unsupported WAV format: ${audioFormat} (only PCM and Float supported)`));
    }
    return ok({
        ...state,
        channels: view.getUint16(chunk.offset + 10, true),
        sampleRate: view.getUint32(chunk.offset + 12, true),
        bitsPerSample: view.getUint16(chunk.offset + 22, true),
        offset: nextWavChunkOffset(chunk),
    });
};

const nextWavChunkOffset = (chunk: WavChunk): number => {
    const nextOffset = chunk.offset + 8 + chunk.size;
    return chunk.size % 2 === 1 ? nextOffset + 1 : nextOffset;
};

// 读取 WAV 文件的 PCM 数据
export const readWavPcm = async (
    wavPath: string,
): Promise<
    Result<{
        sampleRate: number;
        channels: number;
        pcmData: Uint8Array;
    }>
> => {
    const file = Bun.file(wavPath);
    const arrayBuffer = await file.arrayBuffer();
    const data = new Uint8Array(arrayBuffer);
    if (data.length < 44) {
        return err(new Error("WAV file is too short"));
    }

    const header = parseWavHeader(data);
    if (isErr(header)) return err(header.error);
    const wavHeader = header.value;

    if (wavHeader.bitsPerSample !== 16) {
        return err(new Error(`Only 16-bit PCM WAV is supported, got ${wavHeader.bitsPerSample}-bit`));
    }

    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const dataOffset = findWavDataOffset(data, view, 12);

    if (dataOffset === 0) {
        return err(new Error("WAV data chunk not found"));
    }

    const pcmData = data.slice(dataOffset, dataOffset + wavHeader.dataSize);

    return ok({
        sampleRate: wavHeader.sampleRate,
        channels: wavHeader.channels,
        pcmData,
    });
};

const findWavDataOffset = (data: Uint8Array, view: DataView, offset: number): number => {
    if (offset >= data.length) return 0;
    const chunkId = String.fromCharCode(data[offset]!, data[offset + 1]!, data[offset + 2]!, data[offset + 3]!);
    const chunkSize = view.getUint32(offset + 4, true);
    if (chunkId === "data") return offset + 8;
    return findWavDataOffset(data, view, nextWavChunkOffset({ id: chunkId, size: chunkSize, offset }));
};

// 音频编码器接口
export interface AudioEncoder {
    config: Config;
}

// 创建音频编码器
export const createAudioEncoder = (config: Config): AudioEncoder => ({
    config,
});

// PCM 帧分割
export const splitPcmFrames = async (encoder: AudioEncoder, pcmData: Uint8Array): Promise<Uint8Array[]> => {
    const samplesPerFrame = Math.floor((encoder.config.sampleRate * encoder.config.frameDurationMs) / 1000);
    const bytesPerFrame = samplesPerFrame * 2; // 16-bit
    const frameCount = Math.ceil(pcmData.length / bytesPerFrame);
    return Array.from({ length: frameCount }, (_, index) => createPcmFrame(pcmData, index * bytesPerFrame, bytesPerFrame));
};

const createPcmFrame = (pcmData: Uint8Array, start: number, bytesPerFrame: number): Uint8Array => {
    const frame = pcmData.slice(start, start + bytesPerFrame);
    if (frame.length >= bytesPerFrame) return frame;
    const padded = new Uint8Array(bytesPerFrame);
    padded.set(frame);
    return padded;
};

// 将音频文件转换为 PCM
export const convertAudioToPcm = async (
    audioPath: string,
    _sampleRate: number = 16000,
    _channels: number = 1,
): Promise<Result<Uint8Array>> => {
    // 检查是否为 WAV 文件
    if (audioPath.toLowerCase().endsWith(".wav")) return convertWavToPcm(audioPath);

    // 其他格式需要 ffmpeg 或其他工具转换
    return err(
        new Error(
            `Unsupported audio format. Please convert to WAV (16-bit PCM) first.\n` +
                `You can use: ffmpeg -i ${audioPath} -acodec pcm_s16le -ar 16000 -ac 1 output.wav`,
        ),
    );
};

const convertWavToPcm = async (audioPath: string): Promise<Result<Uint8Array>> => {
    const wavResult = await readWavPcm(audioPath);
    if (isErr(wavResult)) return err(wavResult.error);
    return ok(wavResult.value.pcmData);
};
