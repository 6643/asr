const formatTime = (): string => {
    return new Date().toLocaleString("sv-SE", { hour12: false }).replace("T", " ");
};

const writeTimedLine = (message: string): void => {
    console.log(`${formatTime()} ${message}`);
};

const writeTimedError = (message: string): void => {
    console.error(`${formatTime()} ${message}`);
};

export const printTimedDomain = (domain: string, message: string): void => {
    writeTimedLine(`[${domain}] ${message}`);
};

export const printTimedDomainError = (domain: string, message: string): void => {
    writeTimedError(`[${domain}] ${message}`);
};

export const printSessionStart = (): void => {
    printTimedDomain("doubao", "🎤");
};

export const printInterim = (text: string): void => {
    printTimedDomain("doubao", `🎤 ${text || "…"}`);
};

export const printFinal = (text: string): void => {
    printTimedDomain("doubao", `🚀 ${text || "…"}`);
};

export const printRecognitionError = (message: string): void => {
    printTimedDomainError("doubao", `❎ ${message}`);
};

export const printAsrError = (message: string): void => {
    printTimedDomainError("doubao", `❎ ${message}`);
};

export const printIbusCommitSuccess = (): void => {
    printTimedDomain("ibus", "✅");
};

export const printIbusCommitFailure = (message: string): void => {
    printTimedDomain("ibus", `❎: ${message}`);
};

export const printKeyDevice = (device: string): void => {
    printTimedDomain("kbd", device);
};

export const printKeyboardWait = (event: "down" | "up", key: string): void => {
    printTimedDomain("kbd", `wait ${event} ${key}`);
};

export const printKeyboardEvent = (event: "press" | "release"): void => {
    const label = event === "press" ? "down" : "up";
    printTimedDomain("kbd", `${label} RightAlt`);
};
