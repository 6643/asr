// ByteDance Wave 加密协议客户端

import { createCipheriv, createHash } from "crypto";

import { HANDSHAKE_URL, HKDF_INFO, USER_AGENT } from "./constants.ts";
import type { WaveSession } from "./types.ts";
import { err, isErr, ok, tryAsyncResult, type Result } from "../../util.ts";
import { logError } from "../../runtime/output.ts";

// 密钥交换信息
export interface KeyShare {
    curve: string;
    pubkey: string;
}

// 握手请求
interface HandshakeRequest {
    version: number;
    random: string;
    app_id: string;
    did: string;
    key_shares: KeyShare[];
    cipher_suites: number[];
}

// 握手响应
interface HandshakeResponse {
    version: number;
    random: string;
    key_share: KeyShare;
    cipher_suite: number;
    cert: string;
    ticket: string;
    ticket_exp: number;
    ticket_long: string;
    ticket_long_exp: number;
}

// Wave 客户端接口
export interface WaveClient {
    deviceId: string;
    appId: string;
    session: WaveSession | null;
    onSessionUpdate: ((session: WaveSession) => void) | null;
    privateKey: CryptoKey | null;
    publicKey: Uint8Array | null;
}

// 创建 WaveClient 实例
export const createWaveClient = (
    deviceId: string,
    appId: string | number,
    session: WaveSession | null = null,
    onSessionUpdate: ((session: WaveSession) => void) | null = null,
): WaveClient => ({
    deviceId,
    appId: String(appId),
    session,
    onSessionUpdate,
    privateKey: null,
    publicKey: null,
});

// 生成 ECDH 密钥对 (使用 X25519)
const toBufferSource = (value: Uint8Array): ArrayBuffer => {
    return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) as ArrayBuffer;
};

const generateKeyPair = async (): Promise<{ publicKey: Uint8Array; privateKey: CryptoKey }> => {
    const keyPair = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as unknown as CryptoKeyPair;
    const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey));
    return { publicKey, privateKey: keyPair.privateKey };
}

// ChaCha20 加密/解密
const chacha20Crypt = (key: Uint8Array, nonce: Uint8Array, data: Uint8Array): Uint8Array => {
    const nonce16 = nonce.length === 12
        ? (() => {
            const value = new Uint8Array(16);
            value.set(nonce, 4);
            return value;
        })()
        : nonce;

    const cipher = createCipheriv("chacha20", Buffer.from(key), Buffer.from(nonce16));
    const output = Buffer.concat([cipher.update(Buffer.from(data)), cipher.final()]);
    return new Uint8Array(output);
}

// HKDF 密钥派生
const deriveKey = async (sharedKey: Uint8Array, salt: Uint8Array, info: Uint8Array): Promise<Uint8Array> => {
    const key = await crypto.subtle.importKey(
        "raw",
        toBufferSource(sharedKey),
        { name: "HKDF" },
        false,
        ["deriveBits"],
);
    const bits = await crypto.subtle.deriveBits(
        {
            name: "HKDF",
            hash: "SHA-256",
            salt: toBufferSource(salt),
            info: toBufferSource(info),
        },
        key,
        256,
    );
    return new Uint8Array(bits);
}

// 执行握手
export const handshake = async (client: WaveClient): Promise<boolean> => {
    const result = await tryAsyncResult(() => handshakeUnchecked(client));
    if (!isErr(result)) return result.value;
    logError("doubao", `Handshake failed: ${result.error.message}`);
    return false;
};

const handshakeUnchecked = async (client: WaveClient): Promise<boolean> => {
    const keyPair = await generateKeyPair();
    client.privateKey = keyPair.privateKey;
    client.publicKey = keyPair.publicKey;

    const clientRandom = crypto.getRandomValues(new Uint8Array(32));

    const pubkeyBytes = keyPair.publicKey;
    const request: HandshakeRequest = {
        version: 2,
        random: Buffer.from(clientRandom).toString("base64"),
        app_id: client.appId,
        did: client.deviceId,
        key_shares: [
            {
                curve: "curve25519",
                pubkey: Buffer.from(pubkeyBytes).toString("base64"),
            },
        ],
        cipher_suites: [4097],
    };

    const requestJson = JSON.stringify(request);

    const headers: Record<string, string> = {
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
    };

    const response = await fetch(HANDSHAKE_URL, {
        method: "POST",
        headers,
        body: requestJson,
    });

    if (!response.ok) return false;

    const resp = (await response.json()) as HandshakeResponse;
    const serverPubkey = Buffer.from(resp.key_share.pubkey, "base64");
    const sharedKey = await computeSharedKey(client, new Uint8Array(serverPubkey));
    const serverRandom = Buffer.from(resp.random, "base64");
    const salt = concatBytes([clientRandom, serverRandom]);
    const encryptionKey = await deriveKey(sharedKey, salt, HKDF_INFO);

    client.session = createWaveSession(resp, encryptionKey, clientRandom, serverRandom, sharedKey);
    client.onSessionUpdate?.(client.session);
    return true;
};

const computeSharedKey = async (client: WaveClient, serverPubkey: Uint8Array): Promise<Uint8Array> => {
    const result = await tryAsyncResult(() => deriveSharedKey(client.privateKey!, serverPubkey));
    if (isErr(result)) return fallbackSharedKey(result.error);
    if (client.session) client.session.shared_key = result.value;
    return result.value;
};

const deriveSharedKey = async (privateKey: CryptoKey, serverPubkey: Uint8Array): Promise<Uint8Array> => {
    const serverPublicKey = await crypto.subtle.importKey(
        "raw",
        toBufferSource(serverPubkey),
        { name: "X25519" },
        false,
        [],
    ) as CryptoKey;
    const bits = await crypto.subtle.deriveBits(
        {
            name: "X25519",
            public: serverPublicKey,
        },
        privateKey,
        256,
    );
    return new Uint8Array(bits);
};

const fallbackSharedKey = (error: Error): Uint8Array => {
    logError("doubao", `Failed to compute shared secret: ${error.message}`);
    return new Uint8Array(32);
};

const createWaveSession = (
    resp: HandshakeResponse,
    encryptionKey: Uint8Array,
    clientRandom: Uint8Array,
    serverRandom: Uint8Array,
    sharedKey: Uint8Array,
): WaveSession => ({
    ticket: resp.ticket,
    ticket_long: resp.ticket_long,
    encryption_key: encryptionKey,
    client_random: clientRandom,
    server_random: serverRandom,
    shared_key: sharedKey,
    ticket_exp: resp.ticket_exp,
    ticket_long_exp: resp.ticket_long_exp,
    expires_at: Date.now() / 1000 + resp.ticket_exp - 60,
});

// 检查会话是否过期
const isSessionExpired = (client: WaveClient): boolean => {
    if (!client.session) return true;
    return Date.now() / 1000 >= client.session.expires_at;
}

// 确保会话有效
const ensureSession = (client: WaveClient): Result<WaveSession> => {
    if (client.session === null || isSessionExpired(client)) {
        return err(new Error("Session expired or not initialized. Call handshake() first."));
    }
    return ok(client.session);
}

// 准备加密请求
export const prepareRequest = (client: WaveClient, plaintext: Uint8Array, extraHeaders?: Record<string, string>): Result<[Uint8Array, Record<string, string>]> => {
    const sessionResult = ensureSession(client);
    if (isErr(sessionResult)) return err(sessionResult.error);
    const session = sessionResult.value;

    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = chacha20Crypt(session.encryption_key, nonce, plaintext);
    const stub = simpleHash(ciphertext).toUpperCase();

    const headers: Record<string, string> = {
        "Content-Type": "application/json",
        "x-tt-e-b": "1",
        "x-tt-e-t": session.ticket,
        "x-tt-e-p": Buffer.from(nonce).toString("base64"),
        "x-ss-stub": stub,
    };

    if (extraHeaders) {
        Object.assign(headers, extraHeaders);
    }

    return ok([ciphertext, headers]);
};

// 解密数据
export const waveDecrypt = (client: WaveClient, ciphertext: Uint8Array, nonce: Uint8Array): Result<Uint8Array> => {
    if (!client.session) {
        return err(new Error("No active session. Call handshake() first."));
    }

    return ok(chacha20Crypt(client.session.encryption_key, nonce, ciphertext));
};

const simpleHash = (data: Uint8Array): string => {
    return createHash("md5").update(Buffer.from(data)).digest("hex");
}

// 辅助函数：连接字节数组
const concatBytes = (arrays: Uint8Array[]): Uint8Array => {
    const totalLength = arrays.reduce((sum, arr) => sum + arr.length, 0);
    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (const arr of arrays) {
        result.set(arr, offset);
        offset += arr.length;
    }
    return result;
}
