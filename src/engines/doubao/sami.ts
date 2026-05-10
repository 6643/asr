// SAMI 服务相关

import { SAMI_CONFIG_URL, SAMI_APP_KEY, USER_AGENT, APP_CONFIG, DEFAULT_DEVICE_CONFIG } from "./constants.ts";

// 计算 SHA-256 哈希
const sha256 = async (data: Uint8Array): Promise<Uint8Array> => {
    const hashBuffer = await crypto.subtle.digest("SHA-256", new Uint8Array(data));
    return new Uint8Array(hashBuffer);
};

// 字节数组转十六进制字符串
const bytesToHex = (bytes: Uint8Array): string => {
    return Array.from(bytes)
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
};

// SAMI 配置请求参数
interface SamiConfigParams {
    device_platform: string;
    os: string;
    ssmix: string;
    _rticket: string;
    cdid: string;
    channel: string;
    aid: string;
    app_name: string;
    version_code: string;
    version_name: string;
    manifest_version_code: string;
    update_version_code: string;
    resolution: string;
    dpi: string;
    device_type: string;
    device_brand: string;
    language: string;
    os_api: string;
    os_version: string;
    ac: string;
    "use-olympus-account": string;
}

const getDefaultSamiParams = (cdid: string): SamiConfigParams => {
    return {
        device_platform: "android",
        os: "android",
        ssmix: "a",
        _rticket: Date.now().toString(),
        cdid,
        channel: APP_CONFIG.channel,
        aid: String(APP_CONFIG.aid),
        app_name: APP_CONFIG.app_name,
        version_code: String(APP_CONFIG.version_code),
        version_name: APP_CONFIG.version_name,
        manifest_version_code: String(APP_CONFIG.manifest_version_code),
        update_version_code: String(APP_CONFIG.update_version_code),
        resolution: DEFAULT_DEVICE_CONFIG.resolution,
        dpi: DEFAULT_DEVICE_CONFIG.dpi,
        device_type: DEFAULT_DEVICE_CONFIG.device_type,
        device_brand: DEFAULT_DEVICE_CONFIG.device_brand,
        language: DEFAULT_DEVICE_CONFIG.language,
        os_api: DEFAULT_DEVICE_CONFIG.os_api,
        os_version: DEFAULT_DEVICE_CONFIG.os_version,
        ac: "wifi",
        "use-olympus-account": "1",
    };
};

// SAMI 配置请求体
interface SamiConfigRequest {
    sami_app_key: string;
}

// SAMI 配置响应
interface SamiConfigResponse {
    code: number;
    msg: string;
    data: {
        sami_token: string;
    };
}

// 获取 SAMI 配置
const FETCH_TIMEOUT_MS = 15000;

const fetchWithTimeout = (url: string, init: RequestInit, timeoutMs = FETCH_TIMEOUT_MS): Promise<Response> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    return fetch(url, { ...init, signal: controller.signal }).finally(() => clearTimeout(timer));
};

// иҺ·еҸ– SAMI й…ҚзҪ®
const getSamiConfig = async (cdid: string): Promise<Response> => {
    const params = getDefaultSamiParams(cdid);
    const body: SamiConfigRequest = { sami_app_key: SAMI_APP_KEY };

    const bodyJson = JSON.stringify(body);
    const bodyBytes = new TextEncoder().encode(bodyJson);
    const hash = await sha256(bodyBytes);
    const xSsStub = bytesToHex(hash).toUpperCase();

    const queryString = new URLSearchParams(params as unknown as Record<string, string>).toString();

    const response = await fetchWithTimeout(`${SAMI_CONFIG_URL}?${queryString}`, {
        method: "POST",
        headers: {
            "User-Agent": USER_AGENT,
            "Content-Type": "application/json",
            app_version: APP_CONFIG.version_name,
            app_id: String(APP_CONFIG.aid),
            os_type: "Android",
            "x-ss-stub": xSsStub,
        },
        body: bodyJson,
    });

    return response;
};

// 获取 SAMI token
export const getSamiToken = async (cdid: string | null = null): Promise<string> => {
    const cdidStr = cdid ?? crypto.randomUUID();

    const response = await getSamiConfig(cdidStr);

    if (!response.ok) {
        throw new Error(`Get SAMI token failed: ${response.status}`);
    }

    const data = (await response.json()) as SamiConfigResponse;
    return data.data.sami_token;
};
