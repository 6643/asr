const formatTime = (): string => {
    return new Date().toLocaleString("sv-SE", { hour12: false }).replace("T", " ");
};

const writeTimedLine = (message: string): void => {
    console.log(`${formatTime()} ${message}`);
};

export const printStartupBanner = (): void => {
    writeTimedLine("实时语音识别（按键触发模式）");
    writeTimedLine("按下 右Alt 键开始说话, 松开结束");
    console.log("");
};

export const printInitError = (label: string, message: string): void => {
    console.error(`${formatTime()} ❌ ${label}: ${message}`);
};

export const printSessionStart = (): void => {
    writeTimedLine("🎤");
};

export const printInterim = (text: string): void => {
    writeTimedLine(`🎤 ${text || "…"}`);
};

export const printFinal = (text: string): void => {
    writeTimedLine(`🚀 ${text || "…"}`);
};

export const printRecognitionError = (message: string): void => {
    console.error(`${formatTime()} ❌ 识别错误: ${message}`);
};

export const printAsrError = (message: string): void => {
    console.error(`${formatTime()} ❌ ${message}`);
};

export const printVadStart = (): void => {
    return;
};

export const printIbusCommitSuccess = (): void => {
    writeTimedLine("✅ ibus ok");
};

export const printIbusCommitFailure = (message: string): void => {
    writeTimedLine(`❎ ibus err: ${message}`);
};

export const printKeyDevice = (device: string): void => {
    writeTimedLine(`Keyboard device: ${device}`);
    console.log("");
};
