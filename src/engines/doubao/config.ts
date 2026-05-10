// ASR 配置管理

import fs from "fs";
import path from "node:path";

import { WEBSOCKET_URL, USER_AGENT, AID, APP_CONFIG, DEFAULT_DEVICE_CONFIG } from "./constants.ts";
import { registerDevice, getAsrToken, isJwtExpired } from "./device.ts";
import { getSamiToken } from "./sami.ts";
import { createWaveClient } from "./wave.ts";
import type { WaveSession, SessionConfig, DeviceCredentials } from "./types.ts";
import { ok, err, tryResult, type Result } from "../../util.ts";

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

const DEFAULT_CREDENTIAL_DIR = ".config/doubao-asr";
const DEFAULT_CREDENTIAL_FILE = "credentials.json";

const getDefaultCredentialPath = (): string => {
    const home = process.env.HOME || "";
    return path.join(home, DEFAULT_CREDENTIAL_DIR, DEFAULT_CREDENTIAL_FILE);
};

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
    frameDurationMs: 20,

    // 会话配置
    enablePunctuation: options?.enablePunctuation ?? true,
    enableSpeechRejection: false,
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

// 加载并验证凭据文件权限
const loadCredentialsFromFile = async (config: Config): Promise<Result<DeviceCredentials | null>> => {
    if (!config.credentialPath) return ok(null);

    const expandedPath = config.credentialPath.replace(/^~/, process.env.HOME || "");
    const file = Bun.file(expandedPath);
    if (!(await file.exists())) return ok(null);

    // 检查文件权限: 仅所有者可读写
    try {
        const stat = fs.statSync(expandedPath);
        const mode = stat.mode & 0o777;
        const isOwnerOnly = (mode & 0o077) === 0;
        if (!isOwnerOnly) {
            return err(new Error(
                `Credential file ${expandedPath} has insecure permissions (${mode.toString(8)}). ` +
                "Run: chmod 600 " + expandedPath,
            ));
        }
    } catch (e) {
        return err(new Error(`Cannot stat credential file: ${e instanceof Error ? e.message : String(e)}`));
    }

    const [content, contentError] = await tryResult(file.text());
    if (contentError !== null) return ok(null);

    return tryResult(() => JSON.parse(content) as DeviceCredentials);
};

// 保存凭据到文件
const saveCredentialsToFile = async (config: Config, creds: DeviceCredentials): Promise<Result<void>> => {
    if (!config.credentialPath) return ok<void>(undefined);

    const expandedPath = config.credentialPath.replace(/^~/, process.env.HOME || "");
    const dir = expandedPath.substring(0, expandedPath.lastIndexOf("/"));
    if (dir) {
        const [, mkdirError] = await tryResult(fs.promises.mkdir(dir, { recursive: true }));
        if (mkdirError !== null) return err(mkdirError);
    }

    const [, writeError] = await tryResult(Bun.write(expandedPath, JSON.stringify(creds, null, 2)));
    if (writeError !== null) return err(writeError);

    // 设置安全文件权限: 仅所有者可读写
    try {
        fs.chmodSync(expandedPath, 0o600);
    } catch {
        // 非致命错误, 不阻止流程
    }

    return ok<void>(undefined);
};

// 确保凭据已初始化
export const ensureCredentials = async (config: Config): Promise<Result<void>> => {
    if (config._initialized) return ok<void>(undefined);

    const userDeviceId = config.deviceId;
    const userToken = config.token;

    const [fileCreds, fileCredsError] = await loadCredentialsFromFile(config);
    if (fileCredsError === null && fileCreds) {
        config._credentials = fileCreds;
        if (config.deviceId === null) config.deviceId = fileCreds.device_id;
        if (config.token === null) config.token = fileCreds.token;
    }

    let needSave = false;
    if (config.deviceId === null) {
        const [credentials, regError] = await tryResult(registerDevice());
        if (regError !== null) return err(regError);
        config._credentials = credentials;
        config.deviceId = credentials.device_id;
        needSave = true;
    }

    if (config.token === null) {
        const cdid = config._credentials?.cdid ?? "";
        const [token, tokenError] = await tryResult(getAsrToken(config.deviceId!, cdid || null));
        if (tokenError !== null) return err(tokenError);
        config.token = token;
    }

    if (config.credentialPath && needSave && config._credentials) {
        if (config.token !== null) config._credentials.token = config.token;
        await saveCredentialsToFile(config, config._credentials);
    }

    if (userDeviceId !== null) config.deviceId = userDeviceId;
    if (userToken !== null) config.token = userToken;

    config._initialized = true;
    return ok<void>(undefined);
};

// 获取 WebSocket URL
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
    };
};

// 获取会话配置
export const getSessionConfig = (config: Config): Result<SessionConfig> => {
    if (!config._initialized) return err(new Error("Credentials not initialized. Call ensureCredentials() first."));

    return ok({
        audio_info: {
            channel: config.channels,
            format: "speech_opus",
            sample_rate: config.sampleRate,
        },
        enable_punctuation: config.enablePunctuation,
        enable_speech_rejection: config.enableSpeechRejection,
        extra: {
            app_name: config.appName,
            cell_compress_rate: 8,
            did: config.deviceId!,
            enable_asr_threepass: config.enableAsrThreepass,
            enable_asr_twopass: config.enableAsrTwopass,
            input_mode: "tool",
        },
    });
};

// 获取 token
export const getToken = (config: Config): Result<string> => {
    if (!config._initialized) return err(new Error("Credentials not initialized."));
    return ok(config.token!);
};

// Wave 会话更新回调
const onWaveSessionUpdate = (config: Config, session: WaveSession): void => {
    if (config._credentials) {
        config._credentials.wave_session = {
            ticket: session.ticket,
            ticket_long: session.ticket_long,
            encryption_key: Buffer.from(session.encryption_key).toString("base64"),
            client_random: Buffer.from(session.client_random).toString("base64"),
            server_random: Buffer.from(session.server_random).toString("base64"),
            shared_key: Buffer.from(session.shared_key).toString("base64"),
            ticket_exp: session.ticket_exp,
            ticket_long_exp: session.ticket_long_exp,
            expires_at: session.expires_at,
        };
        saveCredentialsToFile(config, config._credentials).catch(() => {});
    }
};

// 获取 WaveClient
export const getWaveClient = (config: Config): ReturnType<typeof createWaveClient> => {
    if (!config._initialized) throw new Error("Credentials not initialized."); // 这里可以用 Result，但作为 getter 抛出异常也可以，或者返回 Result。暂时保持抛出。

    if (config._waveClient === null) {
        let cachedSession: WaveSession | null = null;

        if (config._credentials?.wave_session) {
            const s = config._credentials.wave_session as Record<string, unknown>;
            const now = Date.now() / 1000;
            const [session, parseError] = tryResult(() => {
                if (now < ((s.expires_at as number) ?? Infinity)) {
                    return {
                        ticket: s.ticket as string,
                        ticket_long: s.ticket_long as string,
                        encryption_key: Buffer.from(s.encryption_key as string, "base64"),
                        client_random: Buffer.from(s.client_random as string, "base64"),
                        server_random: Buffer.from(s.server_random as string, "base64"),
                        shared_key: Buffer.from(s.shared_key as string, "base64"),
                        ticket_exp: s.ticket_exp as number,
                        ticket_long_exp: s.ticket_long_exp as number,
                        expires_at: s.expires_at as number,
                    };
                }
                return null;
            });

            if (parseError === null && session) {
                cachedSession = session;
            }
        }

        config._waveClient = createWaveClient(config.deviceId!, config.aid, cachedSession, (session) =>
            onWaveSessionUpdate(config, session),
        );
    }

    return config._waveClient;
};

// 获取 SAMI token
export const getSamiTokenFromConfig = async (config: Config): Promise<Result<string>> => {
    const [, ensureError] = await ensureCredentials(config);
    if (ensureError !== null) return err(ensureError);

    if (config._credentials?.sami_token && !isJwtExpired(config._credentials.sami_token)) {
        return ok<string>(config._credentials.sami_token);
    }

    const cdid = config._credentials?.cdid ?? null;
    const [samiToken, samiError] = await tryResult(getSamiToken(cdid));
    if (samiError !== null) return err(samiError);

    if (config._credentials) {
        config._credentials.sami_token = samiToken;
        await saveCredentialsToFile(config, config._credentials);
    }

    return ok<string>(samiToken);
};
