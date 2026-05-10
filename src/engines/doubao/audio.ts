// 音频处理

import type { Config } from "./config.ts";

// WAV 文件头结构
interface WavHeader {
    sampleRate: number;
    channels: number;
    bitsPerSample: number;
    dataSize: number;
}

// 解析 WAV 文件头
const parseWavHeader = (data: Uint8Array): WavHeader => {
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);

    // 检查 "RIFF" 标记
    const riff = String.fromCharCode(data[0]!, data[1]!, data[2]!, data[3]!);
    if (riff !== "RIFF") {
        throw new Error("Not a valid WAV file: missing RIFF header");
    }

    // 检查 "WAVE" 标记
    const wave = String.fromCharCode(data[8]!, data[9]!, data[10]!, data[11]!);
    if (wave !== "WAVE") {
        throw new Error("Not a valid WAV file: missing WAVE header");
    }

    let offset = 12;
    let sampleRate = 0;
    let channels = 0;
    let bitsPerSample = 0;
    let dataSize = 0;

    // 解析 chunks
    while (offset < data.length) {
        const chunkId = String.fromCharCode(data[offset]!, data[offset + 1]!, data[offset + 2]!, data[offset + 3]!);
        const chunkSize = view.getUint32(offset + 4, true);

        if (chunkId === "fmt ") {
            const audioFormat = view.getUint16(offset + 8, true);
            if (audioFormat !== 1 && audioFormat !== 3) {
                throw new Error(`Unsupported WAV format: ${audioFormat} (only PCM and Float supported)`);
            }
            channels = view.getUint16(offset + 10, true);
            sampleRate = view.getUint32(offset + 12, true);
            bitsPerSample = view.getUint16(offset + 22, true);
        } else if (chunkId === "data") {
            dataSize = chunkSize;
            break;
        }

        offset += 8 + chunkSize;
        if (chunkSize % 2 === 1) offset++; // 对齐
    }

    return { sampleRate, channels, bitsPerSample, dataSize };
};

// 读取 WAV 文件的 PCM 数据
export const readWavPcm = async (
    wavPath: string,
): Promise<{
    sampleRate: number;
    channels: number;
    pcmData: Uint8Array;
}> => {
    const file = Bun.file(wavPath);
    const arrayBuffer = await file.arrayBuffer();
    const data = new Uint8Array(arrayBuffer);

    const header = parseWavHeader(data);

    if (header.bitsPerSample !== 16) {
        throw new Error(`Only 16-bit PCM WAV is supported, got ${header.bitsPerSample}-bit`);
    }

    // 查找 data chunk 的起始位置
    let offset = 12;
    let dataOffset = 0;
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);

    while (offset < data.length) {
        const chunkId = String.fromCharCode(data[offset]!, data[offset + 1]!, data[offset + 2]!, data[offset + 3]!);
        const chunkSize = view.getUint32(offset + 4, true);

        if (chunkId === "data") {
            dataOffset = offset + 8;
            break;
        }

        offset += 8 + chunkSize;
        if (chunkSize % 2 === 1) offset++;
    }

    if (dataOffset === 0) {
        throw new Error("WAV data chunk not found");
    }

    const pcmData = data.slice(dataOffset, dataOffset + header.dataSize);

    return {
        sampleRate: header.sampleRate,
        channels: header.channels,
        pcmData,
    };
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
    const frames: Uint8Array[] = [];
    for (let i = 0; i < pcmData.length; i += bytesPerFrame) {
        let frame = pcmData.slice(i, i + bytesPerFrame);
        // 补零
        if (frame.length < bytesPerFrame) {
            const padded = new Uint8Array(bytesPerFrame);
            padded.set(frame);
            frame = padded;
        }
        frames.push(frame);
    }
    return frames;
};

// 将音频文件转换为 PCM
export const convertAudioToPcm = async (
    audioPath: string,
    sampleRate: number = 16000,
    channels: number = 1,
): Promise<Uint8Array> => {
    // 检查是否为 WAV 文件
    if (audioPath.toLowerCase().endsWith(".wav")) {
        const { pcmData } = await readWavPcm(audioPath);
        // 注意：这里没有进行重采样。如果 WAV 的采样率不是 16000，需要重采样。
        return pcmData;
    }

    // 其他格式需要 ffmpeg 或其他工具转换
    throw new Error(
        `Unsupported audio format. Please convert to WAV (16-bit PCM) first.\n` +
            `You can use: ffmpeg -i ${audioPath} -acodec pcm_s16le -ar 16000 -ac 1 output.wav`,
    );
};
