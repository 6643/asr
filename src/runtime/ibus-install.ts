import fs from "fs";

import { err, ignoreError, isErr, ok, tryAsyncResult, trySyncResult, type Result, runCommand, withFinallyAsync } from "../util.ts";
import { IBUS_COMPONENT_NAME } from "./ibus-meta.ts";
import { getIbusSocketPath } from "./ibus-address.ts";
import { getIbusComponentPath } from "./config.ts";

// 优先使用用户本地路径, 无需 pkexec/sudo
const IBUS_USER_COMPONENT_DIR = `${process.env.HOME || "/tmp"}/.local/share/ibus/component`;
const IBUS_USER_COMPONENT_PATH = `${IBUS_USER_COMPONENT_DIR}/${IBUS_COMPONENT_NAME}`;
const IBUS_SYSTEM_COMPONENT_PATH = `/usr/share/ibus/component/${IBUS_COMPONENT_NAME}`;
const PROJECT_ROOT = decodeURIComponent(new URL("../..", import.meta.url).pathname);
const IBUS_DAEMON_PATH = Bun.which("ibus-daemon");

export interface IbusComponentInstallResult {
    path: string;
    changed: boolean;
}

export const isIbusCacheRefreshNeeded = (installResult: IbusComponentInstallResult): boolean => {
    return installResult.changed;
};

export const isIbusRestartFailureFatal = (message: string): boolean => {
    if (message.includes("timed out")) return false;
    if (message.includes("exited with null")) return false;
    return true;
};

const canWriteDirectory = (dir: string): boolean => {
    const result = trySyncResult(() => {
        fs.mkdirSync(dir, { recursive: true });
        fs.accessSync(dir, fs.constants.W_OK);
        return true;
    });
    return !isErr(result) && result.value;
};

const dirnameFromPath = (filePath: string): string => {
    const index = filePath.lastIndexOf("/");
    if (index <= 0) return "/";
    return filePath.slice(0, index);
};

const readIfExists = async (filePath: string): Promise<string | null> => {
    const result = await tryAsyncResult(() => Bun.file(filePath).text());
    if (isErr(result)) return null;
    return result.value;
};

const waitForReady = async (
    isReady: () => Promise<boolean> | boolean,
    attempts: number,
    delayMs: number,
): Promise<boolean> => {
    return waitForReadyAttempt(isReady, attempts, delayMs, 0);
};

const waitForReadyAttempt = async (
    isReady: () => Promise<boolean> | boolean,
    attempts: number,
    delayMs: number,
    attempt: number,
): Promise<boolean> => {
    if (attempt >= attempts) return false;
    if (await isReady()) return true;
    await Bun.sleep(delayMs);
    return waitForReadyAttempt(isReady, attempts, delayMs, attempt + 1);
};

const writeWithSudo = async (filePath: string, content: string): Promise<Result<void>> => {
    const tmpDir = fs.mkdtempSync("/tmp/asr-ibus-");
    const tempPath = `${tmpDir}/component.xml`;
    const cleanupTemp = () => {
        ignoreError(() => fs.unlinkSync(tempPath));
        ignoreError(() => fs.rmdirSync(tmpDir));
    };
    fs.writeFileSync(tempPath, content, "utf8");
    return withFinallyAsync(() => installWithPkexecSafely(filePath, tempPath), cleanupTemp);
};

const installWithPkexecSafely = async (filePath: string, tempPath: string): Promise<Result<void>> => {
    const result = await tryAsyncResult(() => installWithPkexec(filePath, tempPath));
    if (isErr(result)) return err(new Error(`Failed to install IBus component XML at ${filePath}: ${result.error.message}`));
    return result.value;
};

const installWithPkexec = async (filePath: string, tempPath: string): Promise<Result<void>> => {
    if (!process.stdout.isTTY) return err(new Error(`Cannot prompt for sudo without a TTY: ${filePath}`));

    const proc = Bun.spawn(["pkexec", "install", "-m", "644", tempPath, filePath], {
        terminal: {
            cols: process.stdout.columns || 80,
            rows: process.stdout.rows || 24,
            data(_terminal, data) {
                process.stdout.write(data);
            },
        },
    });

    const exitCode = await proc.exited;
    if (exitCode !== 0) return err(new Error(`pkexec install failed with code ${exitCode}`));
    return ok(undefined);
};

export const resolveIbusComponentPath = (): string => {
    const overridePath = getIbusComponentPath();
    if (overridePath) return overridePath;
    // 默认使用用户本地路径, 避免系统级安装需要 sudo
    return IBUS_USER_COMPONENT_PATH;
};

export const isIbusDaemonRunning = (): boolean => {
    const result = runCommand("pgrep", ["-af", "ibus-daemon"], { timeoutMs: 1000 });
    if (isErr(result)) {
        return false;
    }

    return result.value.stdout.split("\n").some((line: string) => line.includes("ibus-daemon"));
};

export const ensureIbusDaemonRunning = async (): Promise<Result<void>> => {
    if (isIbusDaemonRunning()) {
        return ok(undefined);
    }

    if (!IBUS_DAEMON_PATH) {
        return err(new Error("ibus-daemon executable not found"));
    }

    const spawnResult = trySyncResult(() => Bun.spawn({
        cmd: [IBUS_DAEMON_PATH, "-xdr"],
        cwd: PROJECT_ROOT,
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
        env: process.env,
    }));
    if (isErr(spawnResult)) return err(new Error(`Failed to start IBus daemon: ${spawnResult.error.message}`));

    if (await waitForReady(() => isIbusDaemonRunning(), 20, 250)) {
        return ok(undefined);
    }

    return err(new Error("IBus daemon did not become ready"));
};

export const ensureIbusComponentInstalled = async (): Promise<Result<IbusComponentInstallResult>> => {
    const { getIbusComponentXml } = await import("./ibus-meta.ts");
    const xml = getIbusComponentXml();
    const targetPath = resolveIbusComponentPath();
    const targetDir = dirnameFromPath(targetPath);
    const currentXml = await readIfExists(targetPath);

    if (currentXml === xml) {
        return ok({ path: targetPath, changed: false });
    }

    const writeResult = await writeIbusComponentXmlSafely(targetPath, targetDir, xml);
    if (isErr(writeResult)) return err(writeResult.error);

    return ok({ path: targetPath, changed: true });
};

const writeIbusComponentXmlSafely = async (targetPath: string, targetDir: string, xml: string): Promise<Result<void>> => {
    const writeResult = await tryAsyncResult(() => writeIbusComponentXml(targetPath, targetDir, xml));
    if (isErr(writeResult)) return err(new Error(`Failed to install IBus component XML at ${targetPath}: ${writeResult.error.message}`));
    if (isErr(writeResult.value)) return err(writeResult.value.error);
    return ok(undefined);
};

const writeIbusComponentXml = async (targetPath: string, targetDir: string, xml: string): Promise<Result<void>> => {
    if (canWriteDirectory(targetDir)) {
        await Bun.write(targetPath, xml);
        return ok(undefined);
    }
    if (targetPath === IBUS_SYSTEM_COMPONENT_PATH) return writeSystemIbusComponentXml(targetPath, xml);
    return err(new Error(`Component path not writable: ${targetPath}`));
};

const writeSystemIbusComponentXml = async (targetPath: string, xml: string): Promise<Result<void>> => {
    const sudoResult = await writeWithSudo(targetPath, xml);
    if (!isErr(sudoResult)) return ok(undefined);
    return err(new Error(`Failed to install IBus component XML at ${targetPath}: ${sudoResult.error.message}`));
};

export const refreshIbusCache = (): Result<void> => {
    const result = runCommand("ibus", ["write-cache"], { timeoutMs: 3000 });
    if (isErr(result)) {
        return err(new Error(`Failed to write IBus cache: ${result.error.message}`));
    }

    const restartResult = runCommand("ibus", ["restart"], { timeoutMs: 3000 });
    if (isErr(restartResult)) return handleIbusRestartResult(restartResult.error.message);

    return ok(undefined);
};

const handleIbusRestartResult = (message: string): Result<void> => {
    if (!isIbusRestartFailureFatal(message)) return ok(undefined);
    return err(new Error(`Failed to restart IBus: ${message}`));
};

const waitForIbusAddressReady = async (): Promise<Result<void>> => {
    return waitForIbusAddressReadyAttempt("", 0);
};

const waitForIbusAddressReadyAttempt = async (lastAddress: string, attempt: number): Promise<Result<void>> => {
    if (attempt >= 40) return err(createIbusAddressReadyError(lastAddress));
    const nextAddress = readIbusAddressForReadyCheck(lastAddress);
    if (isReadyIbusAddress(nextAddress)) return ok(undefined);
    await Bun.sleep(250);
    return waitForIbusAddressReadyAttempt(nextAddress, attempt + 1);
};

const readIbusAddressForReadyCheck = (fallbackAddress: string): string => {
    const addressResult = runCommand("ibus", ["address"], { timeoutMs: 1_000 });
    if (isErr(addressResult)) return fallbackAddress;
    return addressResult.value.stdout.trim();
};

const isReadyIbusAddress = (address: string): boolean => {
    const socketPath = getIbusSocketPath(address);
    return Boolean(socketPath && fs.existsSync(socketPath));
};

const createIbusAddressReadyError = (lastAddress: string): Error => {
    const message = lastAddress
        ? "IBus address did not expose a ready unix socket"
        : "IBus did not become ready after cache refresh";
    return new Error(message);
};

export const initIbusRuntime = async (): Promise<Result<string>> => {
    const daemonResult = await ensureIbusDaemonRunning();
    if (isErr(daemonResult)) {
        return err(daemonResult.error);
    }

    const componentResult = await ensureIbusComponentInstalled();
    if (isErr(componentResult)) {
        return err(componentResult.error);
    }

    const refreshResult = refreshIbusCacheIfNeeded(componentResult.value);
    if (isErr(refreshResult)) return err(refreshResult.error);

    const readyResult = await waitForIbusAddressReady();
    if (isErr(readyResult)) {
        return err(readyResult.error);
    }

    return ok<string>(componentResult.value.path);
};

const refreshIbusCacheIfNeeded = (componentResult: IbusComponentInstallResult): Result<void> => {
    if (!isIbusCacheRefreshNeeded(componentResult)) return ok(undefined);
    const refreshResult = refreshIbusCache();
    if (isErr(refreshResult)) return err(new Error(`Failed to refresh IBus cache: ${refreshResult.error.message}`));
    return ok(undefined);
};
