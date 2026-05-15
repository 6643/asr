#!/bin/bash

echo "=========================================="
echo "豆包 ASR 语音识别测试"
echo "=========================================="
echo ""
echo "准备开始录音测试..."
echo "请在看到 '>>> 现在开始说话 <<<' 后，清晰地说一句话"
echo "例如：'你好世界' 或 '今天天气真好'"
echo ""
read -p "按回车键开始录音..."

echo ""
echo ">>> 现在开始说话 <<<"
echo ""

bun scripts/test-doubao-direct.ts 2>&1 | tee /tmp/asr-test-output.log

echo ""
echo "=========================================="
echo "测试完成"
echo "=========================================="
echo ""
echo "播放刚才录制的音频："
aplay -f S16_LE -r 16000 -c 1 /tmp/asr-debug.pcm 2>&1
echo ""
echo "音频分析："
bun scripts/analyze-audio.ts /tmp/asr-debug.pcm 2>/dev/null | head -15
echo ""
echo "识别结果："
grep -E "(interim|final|VAD)" /tmp/asr-test-output.log || echo "未检测到识别结果"
