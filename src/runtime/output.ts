export enum LogLevel {
    ERROR = 0,
    WARN = 1,
    INFO = 2,
    DEBUG = 3,
}

let currentLogLevel = LogLevel.INFO;

export const setLogLevel = (level: LogLevel): void => {
    currentLogLevel = level;
};

export const getLogLevel = (): LogLevel => {
    return currentLogLevel;
};

const formatTime = (): string => {
    return new Date().toLocaleString("sv-SE", { hour12: false }).replace("T", " ");
};

const writeLog = (level: string, message: string): void => {
    console.log(`${formatTime()} [${level}] ${message}`);
};

const writeError = (level: string, message: string): void => {
    console.error(`${formatTime()} [${level}] ${message}`);
};

const shouldLog = (level: LogLevel): boolean => {
    return level <= currentLogLevel;
};

export const logError = (domain: string, message: string): void => {
    if (shouldLog(LogLevel.ERROR)) {
        writeError("ERROR", `[${domain}] ${message}`);
    }
};

export const logWarn = (domain: string, message: string): void => {
    if (shouldLog(LogLevel.WARN)) {
        writeLog("WARN", `[${domain}] ${message}`);
    }
};

export const logInfo = (domain: string, message: string): void => {
    if (shouldLog(LogLevel.INFO)) {
        writeLog("INFO", `[${domain}] ${message}`);
    }
};

export const logDebug = (domain: string, message: string): void => {
    if (shouldLog(LogLevel.DEBUG)) {
        writeLog("DEBUG", `[${domain}] ${message}`);
    }
};

// 向后兼容的别名
export const printTimedLine = (message: string): void => {
    logInfo("app", message);
};

export const printTimedError = (message: string): void => {
    logError("app", message);
};

export const printTimedDomain = (domain: string, message: string): void => {
    logInfo(domain, message);
};

export const printTimedDomainError = (domain: string, message: string): void => {
    logError(domain, message);
};

export const printSessionStart = (): void => {
    logInfo("doubao", "🎤");
};

export const printInterim = (text: string): void => {
    logInfo("doubao", `🎤 ${text || "…"}`);
};

export const printFinal = (text: string): void => {
    logInfo("doubao", `🚀 ${text || "…"}`);
};

export const printRecognitionError = (message: string): void => {
    logError("doubao", `❎ ${message}`);
};

export const printAsrError = (message: string): void => {
    logError("doubao", `❎ ${message}`);
};

export const printIbusCommitSuccess = (): void => {
    logInfo("ibus", "✅");
};

export const printIbusCommitFailure = (message: string): void => {
    logError("ibus", `❎: ${message}`);
};

export const printKeyDevice = (device: string): void => {
    logInfo("kbd", device);
};

export const printKeyboardWait = (event: "down" | "up", key: string): void => {
    logDebug("kbd", `wait ${event} ${key}`);
};

export const printKeyboardEvent = (event: "press" | "release"): void => {
    const label = event === "press" ? "down" : "up";
    logInfo("kbd", `${label} RightAlt`);
};
