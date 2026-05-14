// 设备初始化相关
// 需要先根据客户端配置在豆包服务器注册设备，获取 device_id, install_id, token 等信息

import { createHash } from "crypto";

import {
  REGISTER_URL,
  SETTINGS_URL,
  APP_CONFIG,
  DEFAULT_DEVICE_CONFIG,
  USER_AGENT,
} from "./constants.ts";
import type { DeviceCredentials } from "./types.ts";
import { err, isErr, ok, trySyncResult, type Result } from "../../util.ts";

const bytesToHex = (bytes: Uint8Array): string =>
  Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

const md5Hex = (text: string): string =>
  createHash("md5")
    .update(text)
    .digest("hex")
    .toUpperCase();

// 生成各种设备 ID
const generateOpenUDID = (): string => {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return bytesToHex(bytes);
}

const generateCDID = (): string => {
  return crypto.randomUUID();
}

const generateClientUDID = (): string => {
  return crypto.randomUUID();
}

// 设备注册 Header
interface DeviceRegisterHeaderField {
  device_id: number;
  install_id: number;
  aid: number;
  app_name: string;
  version_code: number;
  version_name: string;
  manifest_version_code: number;
  update_version_code: number;
  channel: string;
  package: string;
  device_platform: string;
  os: string;
  os_api: string;
  os_version: string;
  device_type: string;
  device_brand: string;
  device_model: string;
  resolution: string;
  dpi: string;
  language: string;
  timezone: number;
  access: string;
  rom: string;
  rom_version: string;
  openudid: string;
  clientudid: string;
  cdid: string;
  region: string;
  tz_name: string;
  tz_offset: number;
  sim_region: string;
  carrier_region: string;
  cpu_abi: string;
  build_serial: string;
  not_request_sender: number;
  sig_hash: string;
  google_aid: string;
  mc: string;
  serial_number: string;
}

const getDefaultHeader = (cdid: string, openudid: string, clientudid: string): DeviceRegisterHeaderField => {
  return {
    device_id: 0,
    install_id: 0,
    aid: APP_CONFIG.aid,
    app_name: APP_CONFIG.app_name,
    version_code: APP_CONFIG.version_code,
    version_name: APP_CONFIG.version_name,
    manifest_version_code: APP_CONFIG.manifest_version_code,
    update_version_code: APP_CONFIG.update_version_code,
    channel: APP_CONFIG.channel,
    package: APP_CONFIG.package,
    device_platform: DEFAULT_DEVICE_CONFIG.device_platform,
    os: DEFAULT_DEVICE_CONFIG.os,
    os_api: DEFAULT_DEVICE_CONFIG.os_api,
    os_version: DEFAULT_DEVICE_CONFIG.os_version,
    device_type: DEFAULT_DEVICE_CONFIG.device_type,
    device_brand: DEFAULT_DEVICE_CONFIG.device_brand,
    device_model: DEFAULT_DEVICE_CONFIG.device_model,
    resolution: DEFAULT_DEVICE_CONFIG.resolution,
    dpi: DEFAULT_DEVICE_CONFIG.dpi,
    language: DEFAULT_DEVICE_CONFIG.language,
    timezone: DEFAULT_DEVICE_CONFIG.timezone,
    access: DEFAULT_DEVICE_CONFIG.access,
    rom: DEFAULT_DEVICE_CONFIG.rom,
    rom_version: DEFAULT_DEVICE_CONFIG.rom_version,
    openudid,
    clientudid,
    cdid,
    region: "CN",
    tz_name: "Asia/Shanghai",
    tz_offset: 28800,
    sim_region: "cn",
    carrier_region: "cn",
    cpu_abi: "arm64-v8a",
    build_serial: "unknown",
    not_request_sender: 0,
    sig_hash: "",
    google_aid: "",
    mc: "",
    serial_number: "",
  };
}

// 设备注册请求体
interface DeviceRegisterBody {
  magic_tag: string;
  header: DeviceRegisterHeaderField;
  _gen_time: number;
}

// 设备注册响应
interface DeviceRegisterResponse {
  server_time: number;
  device_id: number;
  install_id: number;
  new_user?: number;
  device_id_str?: string;
  install_id_str?: string;
  ssid?: string;
  device_token?: string;
}

// Settings 响应
interface SettingsResponse {
  data: {
    settings: {
      asr_config: {
        app_key: string;
      };
    };
  };
  message: string;
}

const FETCH_TIMEOUT_MS = 15000;

const fetchWithTimeout = (url: string, init: RequestInit, timeoutMs = FETCH_TIMEOUT_MS): Promise<Response> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    return fetch(url, { ...init, signal: controller.signal }).finally(() => clearTimeout(timer));
};

// 注册设备
export const registerDevice = async (): Promise<Result<DeviceCredentials>> => {
  const cdid = generateCDID();
  const openudid = generateOpenUDID();
  const clientudid = generateClientUDID();

  const header = getDefaultHeader(cdid, openudid, clientudid);

  const body: DeviceRegisterBody = {
    magic_tag: "ss_app_log",
    header,
    _gen_time: Date.now(),
  };

  const params = new URLSearchParams({
    device_platform: DEFAULT_DEVICE_CONFIG.device_platform,
    os: DEFAULT_DEVICE_CONFIG.os,
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
  });

  const response = await fetchWithTimeout(`${REGISTER_URL}?${params}`, {
    method: "POST",
    headers: {
      "User-Agent": USER_AGENT,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    return err(new Error(`Device registration failed: ${response.status}`));
  }

  const data = (await response.json()) as DeviceRegisterResponse;

  if (data.device_id && data.device_id !== 0) {
    return ok({
      device_id: String(data.device_id),
      install_id: String(data.install_id),
      cdid,
      openudid,
      clientudid,
      token: "",
      sami_token: null,
      wave_session: null,
    });
  }

  return err(new Error("Device registration failed: invalid response"));
};

// 获取 ASR token
export const getAsrToken = async (deviceId: string, cdid: string | null): Promise<Result<string>> => {
  if (!cdid) {
    cdid = generateCDID();
  }

  const params = new URLSearchParams({
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
    device_id: deviceId,
  });

  const bodyStr = "body=null";
  const xSsStub = md5Hex(bodyStr);

  const response = await fetchWithTimeout(`${SETTINGS_URL}?${params}`, {
    method: "POST",
    headers: {
      "User-Agent": USER_AGENT,
      "x-ss-stub": xSsStub,
      "Content-Type": "application/json",
    },
    body: bodyStr,
  });

  if (!response.ok) {
    return err(new Error(`Get ASR token failed: ${response.status}`));
  }

  const data = (await response.json()) as SettingsResponse;
  return ok(data.data.settings.asr_config.app_key);
};

// 简单的 JWT 过期检查
export const isJwtExpired = (token: string, margin: number = 60): boolean => {
    const parts = token.split(".");
    if (parts.length < 2) return false;

    const payloadB64 = parts[1];
    if (!payloadB64) return false;
    const padded = payloadB64 + "=".repeat((4 - (payloadB64.length % 4)) % 4);

  const payloadResult = trySyncResult(() => JSON.parse(Buffer.from(padded, "base64").toString("utf-8")) as Record<string, unknown>);
  if (isErr(payloadResult)) return false;
  const payload = payloadResult.value;

    const exp = payload.exp;
    if (exp === undefined) return false;

    return Date.now() / 1_000 >= (exp as number) - margin;
};
