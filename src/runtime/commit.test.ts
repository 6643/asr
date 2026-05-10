import { expect, test } from "bun:test";
import fs from "fs";

test("probeIbusSocket rejects stale socket files", async () => {
    const socketPath = "/tmp/asr-ibus-stale.sock";
    try {
        fs.unlinkSync(socketPath);
    } catch {
        // ignore
    }

    fs.writeFileSync(socketPath, "stale", "utf8");

    try {
        process.env.ASR_IBUS_SOCKET = socketPath;
        const { probeIbusSocket } = await import("./commit.ts");
        expect(probeIbusSocket(socketPath)).resolves.toBe(false);
    } finally {
        delete process.env.ASR_IBUS_SOCKET;
        try {
            fs.unlinkSync(socketPath);
        } catch {
            // ignore
        }
    }
});
