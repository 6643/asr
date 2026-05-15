#!/usr/bin/env bun

const audioPath = process.argv[2] || "/tmp/asr-debug.pcm";

const file = Bun.file(audioPath);
const exists = await file.exists();

if (!exists) {
    console.error(`文件不存在: ${audioPath}`);
    process.exit(1);
}

const data = await file.arrayBuffer();

// 检查是否是 WAV 文件（RIFF 头）
const view = new DataView(data);
let offset = 0;
if (
    data.byteLength >= 44 &&
    view.getUint32(0, false) === 0x52494646 && // "RIFF"
    view.getUint32(8, false) === 0x57415645
) {
    // "WAVE"
    offset = 44; // 跳过 WAV 头
    console.log("检测到 WAV 格式，跳过文件头");
}

const samples = new Int16Array(data, offset);

const total = samples.length;
const max = Math.max(...samples);
const min = Math.min(...samples);

let clippedHigh = 0;
let clippedLow = 0;
let nearZero = 0;
let sumSquares = 0;

for (const sample of samples) {
    if (sample >= 32700) clippedHigh++;
    if (sample <= -32700) clippedLow++;
    if (Math.abs(sample) < 100) nearZero++;
    sumSquares += sample * sample;
}

const rms = Math.sqrt(sumSquares / total);
const durationSec = total / 16000;

console.log(`音频文件: ${audioPath}`);
console.log(`文件大小: ${(data.byteLength / 1024).toFixed(1)} KB`);
console.log(`时长: ${durationSec.toFixed(2)} 秒`);
console.log(`总样本数: ${total}`);
console.log(`最大值: ${max}, 最小值: ${min}`);
console.log(`RMS 音量: ${rms.toFixed(1)}`);
console.log(`削波样本 (>32700): ${clippedHigh} (${((clippedHigh / total) * 100).toFixed(2)}%)`);
console.log(`削波样本 (<-32700): ${clippedLow} (${((clippedLow / total) * 100).toFixed(2)}%)`);
console.log(`接近静音 (<100): ${nearZero} (${((nearZero / total) * 100).toFixed(1)}%)`);

console.log(`\n前 50 个样本:`);
console.log(Array.from(samples.slice(0, 50)).join(", "));

// 分析音频能量分布
const chunkSize = 1600; // 100ms
const chunks = Math.floor(total / chunkSize);
console.log(`\n音频能量分布 (每 100ms):`);
for (let i = 0; i < Math.min(chunks, 50); i++) {
    const start = i * chunkSize;
    const end = start + chunkSize;
    const chunk = samples.slice(start, end);
    let chunkSumSquares = 0;
    for (const s of chunk) {
        chunkSumSquares += s * s;
    }
    const chunkRms = Math.sqrt(chunkSumSquares / chunk.length);
    const bar = "█".repeat(Math.floor(chunkRms / 500));
    console.log(`${(i * 0.1).toFixed(1)}s: ${chunkRms.toFixed(0).padStart(5)} ${bar}`);
}

console.log(`\n播放命令: aplay -f S16_LE -r 16000 -c 1 ${audioPath}`);
