#!/usr/bin/env bun
// 独立脚本：刷新 doubao.json 中的 token 和 sami_token，保留固定设备标识
// 用法: bun run scripts/refresh-credentials.ts [output-path]

import { createHash } from "crypto";
import { readFileSync, existsSync } from "fs";

const OUTPUT = process.argv[2] || `${import.meta.dir}/../config/doubao.json`;

type Config = Record<string, any>;

function readOld(): Config | null {
  try {
    const raw = readFileSync(OUTPUT, "utf-8");
    return JSON.parse(raw);
  } catch { return null; }
}

// ---- 常量 ----
const AID = 401734;
const SAMI_APP_KEY = process.env.ASR_SAMI_APP_KEY || "SYlxZr6LnvBaIVmF";
const USER_AGENT = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)";
const DEVICE = {
  device_platform: "android", os: "android", os_api: "34", os_version: "16",
  device_type: "Pixel 7 Pro", device_brand: "google", device_model: "Pixel 7 Pro",
  resolution: "1080*2400", dpi: "420", language: "zh",
  timezone: 8, access: "wifi", rom: "UP1A.231005.007", rom_version: "UP1A.231005.007",
};

function hex(bytes: Uint8Array): string {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
}
function md5Upper(s: string): string {
  return createHash("md5").update(s).digest("hex").toUpperCase();
}
async function sha256Upper(s: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return hex(new Uint8Array(hash)).toUpperCase();
}
// ---- 1. ASR Token ----
async function getAsrToken(deviceId: string, cdid: string) {
  const bodyStr = "body=null";
  const params = new URLSearchParams({
    device_platform: "android", os: "android", ssmix: "a",
    _rticket: Date.now().toString(), cdid,
    channel: "official", aid: String(AID), app_name: "oime",
    version_code: "100102018", version_name: "1.1.2", device_id: deviceId,
  });
  const res = await fetch(`https://is.snssdk.com/service/settings/v3/?${params}`, {
    method: "POST",
    headers: {
      "User-Agent": USER_AGENT,
      "x-ss-stub": md5Upper(bodyStr),
      "Content-Type": "application/json",
    },
    body: bodyStr,
  });
  if (!res.ok) throw new Error(`ASR token failed: ${res.status}`);
  const data = await res.json() as any;
  const token = data?.data?.settings?.asr_config?.app_key;
  if (!token) throw new Error("ASR token: no app_key in response");
  return token;
}

// ---- 2. SAMI Token ----
async function getSamiToken(cdid: string) {
  const body = JSON.stringify({ sami_app_key: SAMI_APP_KEY });
  const params = new URLSearchParams({
    device_platform: "android", os: "android", ssmix: "a",
    _rticket: Date.now().toString(), cdid,
    channel: "official", aid: String(AID), app_name: "oime",
    version_code: "100102018", version_name: "1.1.2",
    manifest_version_code: "100102018", update_version_code: "100102018",
    resolution: DEVICE.resolution, dpi: DEVICE.dpi,
    device_type: DEVICE.device_type, device_brand: DEVICE.device_brand,
    language: DEVICE.language, os_api: DEVICE.os_api, os_version: DEVICE.os_version,
    ac: "wifi",
  });
  const stub = await sha256Upper(body);
  const res = await fetch(`https://ime.oceancloudapi.com/api/v1/user/get_config?${params}`, {
    method: "POST",
    headers: {
      "User-Agent": USER_AGENT, "Content-Type": "application/json",
      "app_version": "1.1.2", "app_id": String(AID), "os_type": "Android",
      "x-ss-stub": stub,
    },
    body,
  });
  if (!res.ok) throw new Error(`SAMI token failed: ${res.status} ${await res.text()}`);
  const data = await res.json() as any;
  const token = data?.data?.sami_token;
  if (!token) throw new Error("SAMI token: no sami_token in response");
  return token;
}

// ---- MAIN ----
async function main() {
  const old = readOld();
  if (!old) { console.error("旧配置不存在，首次使用请先恢复它"); process.exit(1); }

  const cdid = old.cdid || "";
  if (!cdid) { console.error("旧配置缺少 cdid"); process.exit(1); }

  console.log("Step 1: Get ASR token...");
  const token = await getAsrToken(old.device_id, cdid);
  console.log(`  token: ${token}`);

  console.log("\nStep 2: Get SAMI token...");
  const samiToken = await getSamiToken(cdid);
  console.log(`  sami_token: ${samiToken.slice(0, 50)}...`);

  old.token = token;
  old.sami_token = samiToken;

  await Bun.write(OUTPUT, JSON.stringify(old, null, 2));
  console.log(`\n✓ Config written to ${OUTPUT} (设备标识不变)`);
}

main().catch(e => { console.error("FAILED:", e.message); process.exit(1); });
