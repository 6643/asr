import fs from "fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import net from "net";
import dbus from "dbus-next";

import { err, ok, type Result, runCommand } from "../util.ts";

const { Interface } = dbus.interface;
const { Message, Variant } = dbus;

export const IBUS_ENGINE_NAME = "asr";
export const IBUS_BUS_NAME = "org.freedesktop.IBus.ASR";
export const IBUS_ENGINE_PATH_PREFIX = "/org/freedesktop/IBus/Engine/ASR";
export const IBUS_FACTORY_PATH = "/org/freedesktop/IBus/Factory";
export const IBUS_FACTORY_IFACE = "org.freedesktop.IBus.Factory";
export const IBUS_ENGINE_IFACE = "org.freedesktop.IBus.Engine";
export const IBUS_SOCKET_PATH = process.env.ASR_IBUS_SOCKET || "/tmp/asr_ibus.sock";
export const IBUS_READY_PATH = process.env.ASR_IBUS_READY || "/tmp/asr_ibus.ready";
export const IBUS_COMPONENT_NAME = "asr.xml";
export const IBUS_SYSTEM_COMPONENT_PATH = `/usr/share/ibus/component/${IBUS_COMPONENT_NAME}`;

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(MODULE_DIR, "../..");
const BIN_DIR = path.join(PROJECT_ROOT, "bin");
const IBUS_LAUNCHER_PATH = path.join(BIN_DIR, "asr-service");
const IBUS_DAEMON_PATH = Bun.which("ibus-daemon");
const BUN_BINARY = Bun.which("bun");

export const getIbusComponentXml = (): string => `<?xml version="1.0" encoding="utf-8"?>
<component>
    <name>${IBUS_BUS_NAME}</name>
    <description>ASR IBus Engine</description>
    <exec>${IBUS_LAUNCHER_PATH}</exec>
    <version>0.1.0</version>
    <author>_</author>
    <license>MIT</license>
    <homepage>https://example.invalid/asr</homepage>
    <textdomain>asr</textdomain>
    <engines>
        <engine>
            <name>${IBUS_ENGINE_NAME}</name>
            <longname>ZH</longname>
            <language>zh</language>
            <license>MIT</license>
            <author>_</author>
            <icon></icon>
            <layout>us</layout>
            <symbol>asr</symbol>
            <description>Commit ASR text through IBus</description>
            <setup></setup>
            <rank>80</rank>
        </engine>
    </engines>
</component>
`;

export const getIbusEnginesXml = (): string => `<?xml version="1.0" encoding="utf-8"?>
<engines>
    <engine>
        <name>${IBUS_ENGINE_NAME}</name>
        <longname>ZH</longname>
        <language>zh</language>
        <license>MIT</license>
        <author>_</author>
        <icon></icon>
        <layout>us</layout>
        <symbol>asr</symbol>
        <description>Commit ASR text through IBus</description>
        <setup></setup>
        <rank>80</rank>
    </engine>
</engines>
`;

export const IBUS_COMPONENT_XML = getIbusComponentXml();
export const IBUS_XML = IBUS_COMPONENT_XML;

const canWriteDirectory = (dir: string): boolean => {
    try {
        fs.mkdirSync(dir, { recursive: true });
        fs.accessSync(dir, fs.constants.W_OK);
        return true;
    } catch {
        return false;
    }
};

const readIfExists = (filePath: string): string | null => {
    try {
        if (!fs.existsSync(filePath)) return null;
        return fs.readFileSync(filePath, "utf8");
    } catch {
        return null;
    }
};

export const isIbusDaemonRunning = (): boolean => {
    const [result, error] = runCommand("pgrep", ["-af", "ibus-daemon"], { timeoutMs: 1000 });
    if (error !== null) {
        return false;
    }

    return result.stdout.split("\n").some((line) => line.includes("ibus-daemon"));
};

export const ensureIbusDaemonRunning = async (): Promise<Result<void>> => {
    if (isIbusDaemonRunning()) {
        return ok(undefined);
    }

    if (!IBUS_DAEMON_PATH) {
        return err(new Error("ibus-daemon executable not found"));
    }

    try {
        Bun.spawn({
            cmd: [IBUS_DAEMON_PATH, "-xdr"],
            cwd: PROJECT_ROOT,
            stdin: "ignore",
            stdout: "ignore",
            stderr: "ignore",
            env: process.env,
        });
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return err(new Error(`Failed to start IBus daemon: ${message}`));
    }

    for (let i = 0; i < 20; i++) {
        if (isIbusDaemonRunning()) {
            return ok(undefined);
        }
        await Bun.sleep(250);
    }

    return err(new Error("IBus daemon did not become ready"));
};

const writeWithSudo = async (filePath: string, content: string): Promise<void> => {
    const tmpDir = fs.mkdtempSync("/tmp/asr-ibus-");
    const tempPath = path.join(tmpDir, "component.xml");
    const cleanupTemp = () => {
        try {
            fs.unlinkSync(tempPath);
        } catch {
            /* ignore */
        }
        try {
            fs.rmdirSync(tmpDir);
        } catch {
            /* ignore */
        }
    };
    // 注册多个信号清理, SIGKILL/OOM 下无法清理, 但 tmpfs /tmp 重启后自动消失, 影响可控
    for (const sig of ["exit", "SIGINT", "SIGTERM", "SIGHUP"] as const) {
        process.once(sig, cleanupTemp);
    }

    fs.writeFileSync(tempPath, content, "utf8");
    try {
        if (!process.stdout.isTTY) {
            throw new Error(`Cannot prompt for sudo without a TTY: ${filePath}`);
        }

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
        if (exitCode !== 0) {
            throw new Error(`pkexec install failed with code ${exitCode}`);
        }
    } finally {
        try {
            fs.unlinkSync(tempPath);
        } catch {
            // ignore
        }
    }
};

export const resolveIbusComponentPath = (): string => {
    const overridePath = process.env.ASR_IBUS_COMPONENT_PATH?.trim();
    if (overridePath) return overridePath;
    return IBUS_SYSTEM_COMPONENT_PATH;
};

export const ensureIbusComponentInstalled = async (): Promise<Result<string>> => {
    const xml = getIbusComponentXml();
    const targetPath = resolveIbusComponentPath();
    const targetDir = path.dirname(targetPath);
    const currentXml = readIfExists(targetPath);

    if (currentXml === xml) {
        return ok<string>(targetPath);
    }

    try {
        if (canWriteDirectory(targetDir)) {
            await Bun.write(targetPath, xml);
        } else if (targetPath === IBUS_SYSTEM_COMPONENT_PATH) {
            await writeWithSudo(targetPath, xml);
        } else {
            return err(new Error(`Component path not writable: ${targetPath}`));
        }
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return err(new Error(`Failed to install IBus component XML at ${targetPath}: ${message}`));
    }

    return ok<string>(targetPath);
};

export const refreshIbusCache = (): Result<void> => {
    const [, writeError] = runCommand("ibus", ["write-cache"], { timeoutMs: 3000 });
    if (writeError !== null) {
        return err(new Error(`Failed to write IBus cache: ${writeError.message}`));
    }

    const [, restartError] = runCommand("ibus", ["restart"], { timeoutMs: 3000 });
    if (restartError !== null) {
        return err(new Error(`Failed to restart IBus: ${restartError.message}`));
    }

    return ok(undefined);
};

export const initIbusRuntime = async (): Promise<Result<string>> => {
    const [, daemonError] = await ensureIbusDaemonRunning();
    if (daemonError !== null) {
        return err(daemonError);
    }

    const [componentPath, installError] = await ensureIbusComponentInstalled();
    if (installError !== null) {
        return err(installError);
    }

    const [, refreshError] = refreshIbusCache();
    if (refreshError !== null) {
        return err(new Error(`Failed to refresh IBus cache: ${refreshError.message}`));
    }

    await Bun.sleep(2000);
    return ok<string>(componentPath);
};

const extractUnixSocketPath = (address: string): string | null => {
    const match = address.match(/unix:path=([^,]+)/);
    return match?.[1] || null;
};

const readCurrentIbusAddress = (): string => {
    const [addressResult, addressError] = runCommand("ibus", ["address"], { timeoutMs: 1000 });
    const directAddress = addressError === null ? addressResult.stdout.trim() : "";

    const directSocket = extractUnixSocketPath(directAddress);
    if (directSocket && fs.existsSync(directSocket)) {
        return directAddress;
    }

    const cacheDir = `${process.env.HOME || ""}/.cache/ibus`;
    const sockets = fs.existsSync(cacheDir)
        ? fs
              .readdirSync(cacheDir)
              .filter((name) => name.startsWith("dbus-"))
              .map((name) => {
                  const path = `${cacheDir}/${name}`;
                  const stat = fs.statSync(path);
                  return { path, mtimeMs: stat.mtimeMs };
              })
              .sort((a, b) => b.mtimeMs - a.mtimeMs)
        : [];

    if (sockets.length > 0) {
        const latest = sockets[0];
        if (latest) {
            return `unix:path=${latest.path}`;
        }
    }

    return directAddress;
};

export const resolveIbusAddress = async (): Promise<string> => {
    const seenAddresses: string[] = [];

    for (let i = 0; i < 20; i++) {
        const candidates = [readCurrentIbusAddress(), process.env.IBUS_ADDRESS?.trim()].filter(
            (value): value is string => !!value,
        );

        for (const address of candidates) {
            if (!seenAddresses.includes(address)) {
                seenAddresses.push(address);
            }
            const socketPath = extractUnixSocketPath(address);
            if (!socketPath || fs.existsSync(socketPath)) {
                return address;
            }
        }

        await Bun.sleep(500);
    }

    throw new Error(`IBUS_ADDRESS is invalid after retries: ${seenAddresses.join(" | ")}`);
};

const probeSocket = (socketPath: string, timeoutMs = 300): Promise<boolean> => {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        try {
            socket.once("connect", () => {
                clearTimeout(timer);
                socket.end();
                resolve(true);
            });
            socket.once("error", () => {
                clearTimeout(timer);
                socket.destroy();
                resolve(false);
            });
        } catch {
            resolve(false);
            return;
        }

        const timer = setTimeout(() => {
            socket.destroy();
            resolve(false);
        }, timeoutMs);

        socket.connect(socketPath);
    });
};

export const isIbusSocketReady = async (): Promise<boolean> => {
    return await probeSocket(IBUS_SOCKET_PATH);
};

export const isIbusEngineReady = (): boolean => {
    return fs.existsSync(IBUS_READY_PATH);
};

export const isIbusServiceReady = (): boolean => {
    return fs.existsSync(IBUS_SOCKET_PATH);
};

export interface GsettingsInputSource {
    backend: string;
    id: string;
}

export const parseGsettingsInputSources = (value: string): GsettingsInputSource[] => {
    const sources: GsettingsInputSource[] = [];
    const pattern = /\('([^']*)',\s*'([^']*)'\)/g;

    for (const match of value.matchAll(pattern)) {
        const backend = match[1]?.trim();
        const id = match[2]?.trim();
        if (!backend || !id) continue;
        sources.push({ backend, id });
    }

    return sources;
};

export const normalizeGsettingsInputSources = (value: string): string => {
    return value.replace(/\('ibus',\s*'doubao-asr'\)/g, "('ibus', 'asr')");
};

const parseGsettingsCurrentIndex = (value: string): number | null => {
    const match = value.match(/uint32\s+(\d+)/);
    if (!match?.[1]) return null;
    const parsed = Number(match[1]);
    return Number.isFinite(parsed) ? parsed : null;
};

export const isAsrInputSourceSelected = (sourcesValue: string, currentValue: string): boolean => {
    const sources = parseGsettingsInputSources(sourcesValue);
    const currentIndex = parseGsettingsCurrentIndex(currentValue);
    if (currentIndex === null) return false;

    const currentSource = sources[currentIndex];
    return currentSource?.backend === "ibus" && currentSource.id === IBUS_ENGINE_NAME;
};

export const normalizeGsettingsInputSourcesState = (
    sourcesValue: string,
    currentValue: string,
): { sources: string; current: string } => {
    return {
        sources: normalizeGsettingsInputSources(sourcesValue),
        current: currentValue,
    };
};

const readGsettingsInputSourceState = (): Result<{ sources: string; current: string }> => {
    const [sourcesResult, sourcesError] = runCommand("gsettings", ["get", "org.gnome.desktop.input-sources", "sources"], {
        timeoutMs: 1000,
    });
    if (sourcesError !== null) {
        return err(new Error(`Failed to read input sources: ${sourcesError.message}`));
    }

    const [currentResult, currentError] = runCommand("gsettings", ["get", "org.gnome.desktop.input-sources", "current"], {
        timeoutMs: 1000,
    });
    if (currentError !== null) {
        return err(new Error(`Failed to read current input source: ${currentError.message}`));
    }

    return ok({
        sources: sourcesResult.stdout.trim(),
        current: currentResult.stdout.trim(),
    });
};

const writeGsettingsInputSourceState = (state: { sources: string; current: string }): Result<void> => {
    const [, setSourcesError] = runCommand("gsettings", ["set", "org.gnome.desktop.input-sources", "sources", state.sources], {
        timeoutMs: 1000,
    });
    if (setSourcesError !== null) {
        return err(new Error(`Failed to update input sources: ${setSourcesError.message}`));
    }

    const [, setCurrentError] = runCommand(
        "gsettings",
        ["set", "org.gnome.desktop.input-sources", "current", state.current.replace(/^uint32\s+/, "")],
        { timeoutMs: 1000 },
    );
    if (setCurrentError !== null) {
        return err(new Error(`Failed to update current input source: ${setCurrentError.message}`));
    }

    return ok(undefined);
};

const selectAsrInputSource = (): Result<void> => {
    const [rawState, stateError] = readGsettingsInputSourceState();
    if (stateError !== null) return err(stateError);

    const normalizedState = normalizeGsettingsInputSourcesState(rawState.sources, rawState.current);
    const rawSelected = isAsrInputSourceSelected(rawState.sources, rawState.current);
    const normalizedSelected = isAsrInputSourceSelected(normalizedState.sources, normalizedState.current);

    if (rawSelected && normalizedSelected && rawState.sources === normalizedState.sources) {
        return ok(undefined);
    }

    const [, writeError] = writeGsettingsInputSourceState(normalizedState);
    if (writeError !== null) return err(writeError);

    const [confirmState, confirmError] = readGsettingsInputSourceState();
    if (confirmError !== null) {
        return err(confirmError);
    }

    if (!isAsrInputSourceSelected(normalizeGsettingsInputSources(confirmState.sources), confirmState.current)) {
        return err(new Error(`Failed to select ASR input source`));
    }

    return ok(undefined);
};

const startIbusServiceBackground = (): Result<void> => {
    if (!BUN_BINARY) {
        return err(new Error("bun executable not found"));
    }

    try {
        Bun.spawn({
            cmd: [BUN_BINARY, IBUS_LAUNCHER_PATH],
            cwd: PROJECT_ROOT,
            stdin: "ignore",
            stdout: "ignore",
            stderr: "ignore",
            env: process.env,
        });
        return ok(undefined);
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return err(new Error(`Failed to start IBus service: ${message}`));
    }
};

export const ensureIbusServiceRunning = async (): Promise<Result<void>> => {
    if (await isIbusSocketReady()) {
        return ok<void>(undefined);
    }

    const [, startError] = startIbusServiceBackground();
    if (startError !== null) {
        return err(startError);
    }

    for (let i = 0; i < 20; i++) {
        if (isIbusServiceReady()) {
            return ok<void>(undefined);
        }
        await Bun.sleep(250);
    }

    return err(new Error("IBus service did not become ready"));
};

class IBusEngine extends Interface {
    public hasFocus = false;
    public enabled = false;
    private readonly bus: dbus.MessageBus;
    private readonly objectPath: string;

    constructor(bus: dbus.MessageBus, objectPath: string) {
        super(IBUS_ENGINE_IFACE);
        this.bus = bus;
        this.objectPath = objectPath;
    }

    FocusIn(): void {
        this.hasFocus = true;
        console.log("[IBus] FocusIn");
    }

    FocusOut(): void {
        this.hasFocus = false;
        console.log("[IBus] FocusOut");
    }

    Destroy(): void {
        this.hasFocus = false;
        this.enabled = false;
        console.log("[IBus] Destroy");
    }

    Enable(): void {
        this.enabled = true;
        console.log("[IBus] Enable");
    }

    Disable(): void {
        this.enabled = false;
        console.log("[IBus] Disable");
    }

    ProcessKeyEvent(_keyval: number, _keycode: number, _state: number): boolean {
        return false;
    }

    SetCursorLocation(_x: number, _y: number, _w: number, _h: number): void {}
    SetCursorLocationRelative(_x: number, _y: number, _w: number, _h: number): void {}
    ProcessHandWritingEvent(_coordinates: number[]): void {}
    CancelHandWriting(_nStrokes: number): void {}
    Reset(): void {}
    SetCapabilities(_caps: number): void {}
    PropertyActivate(_name: string, _state: number): void {}
    SetEngine(_name: string): void {}
    GetEngine(): [
        string,
        Record<string, never>,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        number,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
    ] {
        return [
            "IBusEngineDesc",
            {},
            IBUS_ENGINE_NAME,
            "ASR",
            "Commit ASR text through IBus",
            "zh",
            "MIT",
            "_",
            "",
            "us",
            0,
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "ASR",
        ];
    }

    SetSurroundingText(_text: unknown, _cursorPos: number, _anchorPos: number): void {}

    commitText(text: string): boolean {
        if (process.env.ASR_DEBUG) {
            console.log(`[IBus] commit requested. focus=${this.hasFocus} enabled=${this.enabled} text_len=${text.length}`);
        }
        if (!this.hasFocus || !this.enabled) {
            return false;
        }
        const textVariant = new Variant("(sa{sv}sv)", [
            "IBusText",
            {},
            text,
            new Variant("(sa{sv}av)", ["IBusAttrList", {}, []]),
        ]);
        this.bus.send(
            new Message({
                type: dbus.MessageType.SIGNAL,
                path: this.objectPath,
                interface: IBUS_ENGINE_IFACE,
                member: "CommitText",
                signature: "v",
                body: [textVariant],
            }),
        );
        console.log("[IBus] CommitText sent");
        return true;
    }
}

IBusEngine.configureMembers({
    methods: {
        FocusIn: { inSignature: "", outSignature: "" },
        FocusOut: { inSignature: "", outSignature: "" },
        Enable: { inSignature: "", outSignature: "" },
        Disable: { inSignature: "", outSignature: "" },
        Destroy: { inSignature: "", outSignature: "" },
        ProcessKeyEvent: { inSignature: "uuu", outSignature: "b" },
        SetCursorLocation: { inSignature: "iiii", outSignature: "" },
        SetCursorLocationRelative: { inSignature: "iiii", outSignature: "" },
        ProcessHandWritingEvent: { inSignature: "ad", outSignature: "" },
        CancelHandWriting: { inSignature: "u", outSignature: "" },
        Reset: { inSignature: "", outSignature: "" },
        SetCapabilities: { inSignature: "u", outSignature: "" },
        PropertyActivate: { inSignature: "su", outSignature: "" },
        SetEngine: { inSignature: "s", outSignature: "" },
        GetEngine: { inSignature: "", outSignature: "v" },
        SetSurroundingText: { inSignature: "vuu", outSignature: "" },
    },
});

class IBusFactory extends Interface {
    private engineId = 0;
    public activeEngine: IBusEngine | null = null;
    private readonly bus: dbus.MessageBus;

    constructor(bus: dbus.MessageBus) {
        super(IBUS_FACTORY_IFACE);
        this.bus = bus;
    }

    CreateEngine(engineName: string): string {
        if (engineName !== IBUS_ENGINE_NAME) {
            throw new Error(`unsupported engine: ${engineName}`);
        }
        const path = `${IBUS_ENGINE_PATH_PREFIX}/${this.engineId++}`;
        console.log(`[IBus] CreateEngine name=${engineName} path=${path}`);
        const engine = new IBusEngine(this.bus, path);
        this.bus.export(path, engine);
        this.activeEngine = engine;
        fs.writeFileSync(IBUS_READY_PATH, "ready", "utf8");
        return path;
    }
}

IBusFactory.configureMembers({
    methods: {
        CreateEngine: { inSignature: "s", outSignature: "o" },
    },
});

const createSocketServer = (factory: IBusFactory): net.Server => {
    const server = net.createServer({ allowHalfOpen: true }, (socket) => {
        const chunks: Buffer[] = [];
        let handled = false;
        let flushTimer: ReturnType<typeof setTimeout> | null = null;

        const flush = (): void => {
            if (handled) return;
            handled = true;
            if (flushTimer) {
                clearTimeout(flushTimer);
                flushTimer = null;
            }

            try {
                const text = Buffer.concat(chunks).toString("utf8").trim();
                if (process.env.ASR_DEBUG) {
                    console.log(`[Socket] text received: ${JSON.stringify(text)}`);
                }
                if (!text) {
                    console.log("[Socket] commit response: ERR empty_text");
                    socket.write("ERR empty_text");
                    socket.end();
                    return;
                }

                const engine = factory.activeEngine;
                if (!engine) {
                    console.log("[Socket] commit response: ERR engine_not_created");
                    socket.write("ERR engine_not_created");
                    socket.end();
                    return;
                }

                if (!engine.hasFocus) {
                    console.log("[Socket] commit response: ERR engine_not_focused");
                    socket.write("ERR engine_not_focused");
                    socket.end();
                    return;
                }

                const ok = engine.commitText(text);
                console.log(`[Socket] commit response: ${ok ? "OK committed" : "ERR commit_rejected"}`);
                socket.write(ok ? "OK committed" : "ERR commit_rejected");
                socket.end();
            } catch (error) {
                const message = error instanceof Error ? error.stack || error.message : String(error);
                console.error("[Socket] commit failed:", message);
                console.log(`[Socket] commit response: ERR ${message}`);
                socket.write(`ERR ${message}`);
                socket.end();
            }
        };

        socket.on("data", (chunk) => {
            chunks.push(Buffer.from(chunk));
            if (flushTimer) {
                clearTimeout(flushTimer);
            }
            flushTimer = setTimeout(flush, 10);
        });

        socket.on("end", () => {
            flush();
        });

        socket.on("error", () => {
            socket.destroy();
        });
    });

    return server;
};

export const startIbusService = async (): Promise<void> => {
    const ibusAddress = await resolveIbusAddress();
    try {
        await Bun.$`rm -f ${IBUS_SOCKET_PATH}`.quiet();
        await Bun.$`rm -f ${IBUS_READY_PATH}`.quiet();
    } catch {
        // ignore
    }

    const bus = dbus.sessionBus({ busAddress: ibusAddress });
    bus.on("error", (error) => {
        console.error("DBus error:", error);
    });

    const factory = new IBusFactory(bus);
    bus.export(IBUS_FACTORY_PATH, factory);

    await bus.requestName(IBUS_BUS_NAME, 0);

    const server = createSocketServer(factory);

    await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(IBUS_SOCKET_PATH, () => resolve());
    });

    console.log(`IBus engine ready. name=${IBUS_ENGINE_NAME} socket=${IBUS_SOCKET_PATH} address=${ibusAddress}`);

    const shutdown = async () => {
        server.close();
        bus.disconnect();
        try {
            await Bun.$`rm -f ${IBUS_SOCKET_PATH}`.quiet();
            await Bun.$`rm -f ${IBUS_READY_PATH}`.quiet();
        } catch {
            // ignore
        }
        process.exit(0);
    };

    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
};

export const ensureIbusEngineSelected = async (): Promise<Result<void>> => {
    const IBUS_ENGINE_MAX_ATTEMPTS = 20;
    const IBUS_ENGINE_INITIAL_DELAY_MS = 200;
    const IBUS_ENGINE_MAX_DELAY_MS = 2000;

    try {
        const [initialState, initialError] = readGsettingsInputSourceState();
        if (initialError !== null) {
            return err(new Error(`IBus engine is not available: ${initialError.message}`));
        }

        if (isAsrInputSourceSelected(initialState.sources, initialState.current)) {
            return ok<void>(undefined);
        }

        const [, selectError] = selectAsrInputSource();
        if (selectError !== null) {
            return err(new Error(`IBus engine is not available: ${selectError.message}`));
        }

        for (let attempt = 0; attempt < IBUS_ENGINE_MAX_ATTEMPTS; attempt++) {
            const [state, stateError] = readGsettingsInputSourceState();
            if (stateError !== null) {
                const delay = Math.min(IBUS_ENGINE_INITIAL_DELAY_MS * (1 << attempt), IBUS_ENGINE_MAX_DELAY_MS);
                await Bun.sleep(delay);
                continue;
            }

            if (isAsrInputSourceSelected(state.sources, state.current)) {
                return ok<void>(undefined);
            }

            const delay = Math.min(IBUS_ENGINE_INITIAL_DELAY_MS * (1 << attempt), IBUS_ENGINE_MAX_DELAY_MS);
            await Bun.sleep(delay);
        }

        return err(new Error(`IBus engine did not become ready after selecting ${IBUS_ENGINE_NAME}`));
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return err(new Error(`IBus engine is not available: ${message}`));
    }
};

export const waitForIbusRuntimeReady = async (): Promise<Result<void>> => {
    for (let attempt = 0; attempt < 20; attempt++) {
        if (!(await isIbusSocketReady())) {
            await Bun.sleep(250);
            continue;
        }

        return ok<void>(undefined);
    }

    return err(new Error("IBus runtime did not become ready"));
};
