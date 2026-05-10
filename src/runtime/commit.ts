/**
 * Text commit: IBus only.
 */

import net from "net";
import fs from "fs";

export interface CommitResult {
    success: boolean;
    method: "ibus";
    message: string;
}

const DEFAULT_IBUS_SOCKET = process.env.ASR_IBUS_SOCKET || "/tmp/asr_ibus.sock";
const RETRYABLE_IBUS_RESPONSES = new Set([
    `ERR connect ENOENT ${DEFAULT_IBUS_SOCKET}`,
    "ERR empty_response",
    "ERR engine_not_created",
    "ERR engine_not_focused",
    "ERR timeout",
]);

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

export const probeIbusSocket = (socketPath: string, timeoutMs = 300): Promise<boolean> => {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        const timer = setTimeout(() => {
            socket.destroy();
            resolve(false);
        }, timeoutMs);

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

        try {
            socket.connect(socketPath);
        } catch {
            clearTimeout(timer);
            socket.destroy();
            resolve(false);
        }
    });
};

const waitForSocket = async (socketPath: string, attempts = 40, intervalMs = 100): Promise<boolean> => {
    for (let i = 0; i < attempts; i++) {
        if (await probeIbusSocket(socketPath)) return true;
        await sleep(intervalMs);
    }
    return await probeIbusSocket(socketPath);
};

export const isRetryableIbusResponse = (response: string): boolean => {
    return RETRYABLE_IBUS_RESPONSES.has(response.trim());
};

const commitViaIbus = async (text: string): Promise<{ ok: boolean; response: string }> => {
    try {
        if (!(await waitForSocket(DEFAULT_IBUS_SOCKET))) {
            return { ok: false, response: `ERR connect ENOENT ${DEFAULT_IBUS_SOCKET}` };
        }

        let output = "";
        for (let attempt = 0; attempt < 20; attempt++) {
            output = await new Promise<string>((resolve) => {
                const socket = net.createConnection(DEFAULT_IBUS_SOCKET);
                let response = "";
                const timer = setTimeout(() => {
                    socket.destroy();
                    resolve("ERR timeout");
                }, 1500);

                socket.on("readable", () => {
                    let chunk: Buffer | null;
                    while ((chunk = socket.read()) !== null) {
                        response += chunk.toString("utf8");
                        const trimmed = response.trim();
                        if (trimmed.startsWith("OK ") || trimmed.startsWith("ERR ")) {
                            clearTimeout(timer);
                            socket.destroy();
                            resolve(trimmed);
                            return;
                        }
                    }
                });
                socket.on("error", (error) => {
                    clearTimeout(timer);
                    if (
                        error &&
                        typeof error === "object" &&
                        "code" in error &&
                        (error as { code?: string }).code === "ENOENT"
                    ) {
                        resolve(`ERR connect ENOENT ${DEFAULT_IBUS_SOCKET}`);
                        return;
                    }
                    resolve(`ERR ${error instanceof Error ? error.message : String(error)}`);
                });
                socket.on("close", () => {
                    clearTimeout(timer);
                    if (!response.trim()) resolve("ERR empty_response");
                });
                socket.write(`${text}\n`);
            });

            if (!isRetryableIbusResponse(output)) {
                break;
            }

            await sleep(250);
        }

        return { ok: output.startsWith("OK "), response: output.trim() };
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return { ok: false, response: `ERR ${message}` };
    }
};

export const commitText = async (text: string): Promise<CommitResult> => {
    const ibusResult = await commitViaIbus(text);
    if (ibusResult.ok) {
        return { success: true, method: "ibus", message: "Committed via IBus engine" };
    }

    return { success: false, method: "ibus", message: ibusResult.response || "IBus commit failed" };
};
