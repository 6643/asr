// ASR 配置管理

import fs from "fs";

import { WEBSOCKET_URL, USER_AGENT, AID } from "./constants.ts";
import { registerDevice, getAsrToken, isJwtExpired } from "./device.ts";
import { getSamiToken } from "./sami.ts";
import { createWaveClient } from "./wave.ts";
import type { WaveSession, SessionConfig, DeviceCredentials } from "./types.ts";
import { ok, err, tryAsyncResult, trySyncResult, isOk, isErr, type Result, uint8ArrayToBase64, base64ToUint8Array } from "../../util.ts";
import { getDefaultCredentialPath, resolveCredentialPath } from "./config-path.ts";
import { printTimedDomainError } from "../../runtime/output.ts";

// 配置接口
export interface Config {
    // 基本配置
    url: string;
    aid: string;
    userAgent: string;

    // 设备配置
    deviceId: string | null;
    token: string | null;
    credentialPath: string | null;

    // 音频配置
    sampleRate: number;
    channels: number;
    frameDurationMs: number;

    // 会话配置
    enablePunctuation: boolean;
    enableSpeechRejection: boolean;
    enableAsrTwopass: boolean;
    enableAsrThreepass: boolean;
    appName: string;

    // 连接配置
    connectTimeout: number;
    recvTimeout: number;

    // 内部状态
    _credentials: DeviceCredentials | null;
    _initialized: boolean;
    _waveClient: ReturnType<typeof createWaveClient> | null;
}

// 创建 Config 实例
export const createConfig = (options?: {
    deviceId?: string;
    token?: string;
    credentialPath?: string;
    sampleRate?: number;
    channels?: number;
    enablePunctuation?: boolean;
}): Config => ({
    // 基本配置
    url: WEBSOCKET_URL,
    aid: String(AID),
    userAgent: USER_AGENT,

    // 设备配置
    deviceId: options?.deviceId ?? null,
    token: options?.token ?? null,
    credentialPath: options?.credentialPath ?? getDefaultCredentialPath(),

    // 音频配置
    sampleRate: options?.sampleRate ?? 16000,
    channels: options?.channels ?? 1,
    frameDurationMs: 100,

    // 会话配置
    enablePunctuation: options?.enablePunctuation ?? true,
    enableSpeechRejection: true,
    enableAsrTwopass: true,
    enableAsrThreepass: true,
    appName: "com.android.chrome",

    // 连接配置
    connectTimeout: 10000,
    recvTimeout: 10000,

    // 内部状态
    _credentials: null,
    _initialized: false,
    _waveClient: null,
});

// 加载凭据文件
const loadCredentialsFromFile = async (config: Config): Promise<Result<DeviceCredentials | null>> => {
    if (!config.credentialPath) return ok(null);
    const credentialPath = config.credentialPath;

    const expandedPathResult = trySyncResult(() => resolveCredentialPath(credentialPath));
    if (isErr(expandedPathResult)) return err(expandedPathResult.error);
    const expandedPath = expandedPathResult.value;
    const file = Bun.file(expandedPath);
    if (!(await file.exists())) return ok(null);

    const contentResult = await tryAsyncResult(() => file.text());
    if (isErr(contentResult)) return err(new Error(`Cannot read credential file: ${contentResult.error.message}`));

    const content = contentResult.value;
    const parseResult = trySyncResult(() => JSON.parse(content) as DeviceCredentials);
    if (isErr(parseResult)) return err(parseResult.error);
    return ok(parseResult.value);
};

// 保存凭据到文件
const saveCredentialsToFile = async (config: Config, creds: DeviceCredentials): Promise<Result<void>> => {
    if (!config.credentialPath) return ok<void>(undefined);
    const credentialPath = config.credentialPath;

    const expandedPathResult = trySyncResult(() => resolveCredentialPath(credentialPath));
    if (isErr(expandedPathResult)) return err(expandedPathResult.error);
    const expandedPath = expandedPathResult.value;
    const dir = expandedPath.substring(0, expandedPath.lastIndexOf("/"));
    const dirResult = await ensureCredentialDir(dir);
    if (isErr(dirResult)) return err(dirResult.error);

    const writeResult = await tryAsyncResult(() => fs.promises.writeFile(expandedPath, JSON.stringify(creds, null, 2), { mode: 0o600 }));
    if (isErr(writeResult)) return err(writeResult.error);

    return ok<void>(undefined);
};

const ensureCredentialDir = async (dir: string): Promise<Result<void>> => {
    if (!dir) return ok(undefined);
    const mkdirResult = await tryAsyncResult(() => fs.promises.mkdir(dir, { recursive: true }));
    if (isErr(mkdirResult)) return err(mkdirResult.error);
    return ok(undefined);
};

// 确保凭据已初始化
export const ensureCredentials = async (config: Config): Promise<Result<void>> => {
    if (config._initialized) return ok<void>(undefined);

    const userDeviceId = config.deviceId;
    const userToken = config.token;

    const fileCredsResult = await loadCredentialsFromFile(config);
    if (isErr(fileCredsResult)) return err(fileCredsResult.error);
    applyFileCredentials(config, fileCredsResult.value);

    let needSave = false;
    const deviceResult = await ensureConfigDevice(config);
    if (isErr(deviceResult)) return err(deviceResult.error);
    needSave = deviceResult.value;

    const tokenResult = await ensureConfigToken(config);
    if (isErr(tokenResult)) return err(tokenResult.error);

    const saveResult = await saveConfigCredentialsIfNeeded(config, needSave);
    if (isErr(saveResult)) return err(saveResult.error);

    if (userDeviceId !== null) config.deviceId = userDeviceId;
    if (userToken !== null) config.token = userToken;

    config._initialized = true;
    return ok<void>(undefined);
};

const applyFileCredentials = (config: Config, fileCreds: DeviceCredentials | null): void => {
    if (!fileCreds) return;
    config._credentials = fileCreds;
    if (config.deviceId === null) config.deviceId = fileCreds.device_id;
    if (config.token === null) config.token = fileCreds.token;
};

const ensureConfigDevice = async (config: Config): Promise<Result<boolean>> => {
    if (config.deviceId !== null) return ok(false);
    const credsResult = await registerDevice();
    if (isErr(credsResult)) return err(credsResult.error);
    const credentials = credsResult.value;
    config._credentials = credentials;
    config.deviceId = credentials.device_id;
    return ok(true);
};

const ensureConfigToken = async (config: Config): Promise<Result<void>> => {
    if (config.token !== null) return ok(undefined);
    const cdid = config._credentials?.cdid ?? "";
    const tokenResult = await getAsrToken(config.deviceId!, cdid || null);
    if (isErr(tokenResult)) return err(tokenResult.error);
    config.token = tokenResult.value;
    return ok(undefined);
};

const saveConfigCredentialsIfNeeded = async (config: Config, needSave: boolean): Promise<Result<void>> => {
    if (!config.credentialPath || !needSave || !config._credentials) return ok(undefined);
    if (config.token !== null) config._credentials.token = config.token;
    const saveResult = await saveCredentialsToFile(config, config._credentials);
    if (isErr(saveResult)) return err(saveResult.error);
    return ok(undefined);
};

// 获取 WebSocket URL
// NOTE: device_id is placed in the URL query string as required by the Doubao ASR server.
// The connection uses WSS (encrypted transport), so the query string is protected in transit,
// but may appear in proxy logs, debug output, or connection traces.
export const getWsUrl = (config: Config): Result<string> => {
    if (!config._initialized) return err(new Error("Credentials not initialized. Call ensureCredentials() first."));
    return ok(`${config.url}?aid=${config.aid}&device_id=${config.deviceId}`);
};

// 获取请求头
export const getHeaders = (config: Config): Record<string, string> => {
    return {
        "User-Agent": config.userAgent,
        "proto-version": "v2",
        "x-custom-keepalive": "true",
        "X-Device-Id": config.deviceId || "",
    };
};

// 获取会话配置
export const getSessionConfig = (config: Config): Result<SessionConfig> => {
    if (!config._initialized) return err(new Error("Credentials not initialized. Call ensureCredentials() first."));

    return ok({
        audio_info: {
            channel: config.channels,
            format: "pcm",
            sample_rate: config.sampleRate,
        },
        enable_punctuation: config.enablePunctuation,
        enable_speech_rejection: config.enableSpeechRejection,
        extra: {
            app_name: config.appName,
            cell_compress_rate: 8,
            did: config.deviceId ?? "",
            enable_asr_threepass: config.enableAsrThreepass,
            enable_asr_twopass: config.enableAsrTwopass,
            input_mode: "tool",
        },
    });
};

// 获取 token
export const getToken = (config: Config): Result<string> => {
    if (!config._initialized) return err(new Error("Credentials not initialized."));
    if (config.token === null) return err(new Error("Token is null."));
    return ok(config.token);
};

// Wave 会话更新回调
const onWaveSessionUpdate = (config: Config, session: WaveSession): void => {
    if (!config._credentials) return;
    config._credentials.wave_session = serializeWaveSession(session);
    void saveCredentialsToFile(config, config._credentials).then(logCredentialSaveFailure);
};

const serializeWaveSession = (session: WaveSession): DeviceCredentials["wave_session"] => ({
    ticket: session.ticket,
    ticket_long: session.ticket_long,
    encryption_key: uint8ArrayToBase64(session.encryption_key),
    client_random: uint8ArrayToBase64(session.client_random),
    server_random: uint8ArrayToBase64(session.server_random),
    shared_key: uint8ArrayToBase64(session.shared_key),
    ticket_exp: session.ticket_exp,
    ticket_long_exp: session.ticket_long_exp,
    expires_at: session.expires_at,
});

const logCredentialSaveFailure = (result: Result<void>): void => {
    if (!isErr(result)) return;
    printTimedDomainError("doubao", `Failed to save credential file: ${result.error.message}`);
};

// 获取 WaveClient
export const getWaveClient = (config: Config): Result<ReturnType<typeof createWaveClient>> => {
    if (!config._initialized) return err(new Error("Credentials not initialized."));
    return ok(getInitializedWaveClient(config));
};

const getInitializedWaveClient = (config: Config): ReturnType<typeof createWaveClient> => {
    if (config._waveClient === null) initializeWaveClient(config);
    return config._waveClient!;
};

const initializeWaveClient = (config: Config): void => {
    const cachedSession = readCachedWaveSession(config);
    config._waveClient = createWaveClient(config.deviceId!, config.aid, cachedSession, (session) =>
        onWaveSessionUpdate(config, session),
    );
};

const readCachedWaveSession = (config: Config): WaveSession | null => {
    const cached = config._credentials?.wave_session;
    if (!cached) return null;
    const sessionResult = parseCachedWaveSession(cached as Record<string, unknown>);
    if (isOk(sessionResult)) return sessionResult.value;
    return null;
};

const parseCachedWaveSession = (s: Record<string, unknown>): Result<WaveSession> => {
    const now = Date.now() / 1_000;
    if (now >= ((s.expires_at as number) ?? Infinity)) return err(new Error("Session expired"));
    return ok({
        ticket: s.ticket as string,
        ticket_long: s.ticket_long as string,
        encryption_key: base64ToUint8Array(s.encryption_key as string),
        client_random: base64ToUint8Array(s.client_random as string),
        server_random: base64ToUint8Array(s.server_random as string),
        shared_key: base64ToUint8Array(s.shared_key as string),
        ticket_exp: s.ticket_exp as number,
        ticket_long_exp: s.ticket_long_exp as number,
        expires_at: s.expires_at as number,
    } as WaveSession);
};

// 获取 SAMI token
export const getSamiTokenFromConfig = async (config: Config): Promise<Result<string>> => {
    const ensureResult = await ensureCredentials(config);
    if (isErr(ensureResult)) return err(ensureResult.error);

    if (config._credentials?.sami_token && !isJwtExpired(config._credentials.sami_token)) {
        return ok<string>(config._credentials.sami_token);
    }

    const cdid = config._credentials?.cdid ?? null;
    const samiTokenResult = await getSamiToken(cdid);
    if (isErr(samiTokenResult)) return err(samiTokenResult.error);

    const samiToken = samiTokenResult.value;
    const saveResult = await saveSamiToken(config, samiToken);
    if (isErr(saveResult)) return err(saveResult.error);

    return ok<string>(samiToken);
};

const saveSamiToken = async (config: Config, samiToken: string): Promise<Result<void>> => {
    if (!config._credentials) return ok(undefined);
    config._credentials.sami_token = samiToken;
    const saveResult = await saveCredentialsToFile(config, config._credentials);
    if (isErr(saveResult)) return err(saveResult.error);
    return ok(undefined);
};
