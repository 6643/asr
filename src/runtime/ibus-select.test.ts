import { expect, test } from "bun:test";
import fs from "fs";
import net from "net";

import {
    IBUS_READY_PATH,
    isIbusDaemonRunning,
    ensureIbusServiceRunning,
    isAsrInputSourceSelected,
    isIbusEngineReady,
    isIbusServiceReady,
    isIbusSocketReady,
    parseGsettingsInputSources,
    normalizeGsettingsInputSources,
    normalizeGsettingsInputSourcesState,
    waitForIbusRuntimeReady,
} from "./ibus.ts";

test("ibus readiness uses the dedicated ready marker", () => {
    try {
        fs.unlinkSync("/tmp/asr_ibus.ready");
    } catch {
        // ignore
    }
    try {
        fs.unlinkSync("/tmp/asr_ibus.sock");
    } catch {
        // ignore
    }

    expect(IBUS_READY_PATH).toContain("/tmp/asr_ibus.ready");
    expect(isIbusEngineReady()).toBe(false);
});

test("ibus service readiness uses the socket path", async () => {
    try {
        fs.unlinkSync("/tmp/asr_ibus.sock");
    } catch {
        // ignore
    }
    try {
        fs.unlinkSync(IBUS_READY_PATH);
    } catch {
        // ignore
    }

    expect(isIbusServiceReady()).toBe(false);

    const [, serviceError] = await ensureIbusServiceRunning();
    expect(serviceError === null).toBe(true);
});

test("ibus socket readiness rejects stale socket files", async () => {
    try {
        fs.unlinkSync("/tmp/asr_ibus.sock");
    } catch {
        // ignore
    }
    try {
        fs.unlinkSync(IBUS_READY_PATH);
    } catch {
        // ignore
    }

    fs.writeFileSync("/tmp/asr_ibus.sock", "stale", "utf8");
    try {
        await expect(isIbusSocketReady()).resolves.toBe(false);
    } finally {
        try {
            fs.unlinkSync("/tmp/asr_ibus.sock");
        } catch {
            // ignore
        }
    }
});

test("gsettings input source parser recognizes the asr source", () => {
    const sources = parseGsettingsInputSources("[('xkb', 'us'), ('ibus', 'asr')]");

    expect(sources).toEqual([
        { backend: "xkb", id: "us" },
        { backend: "ibus", id: "asr" },
    ]);
    expect(isAsrInputSourceSelected("[('xkb', 'us'), ('ibus', 'asr')]", "uint32 1")).toBe(true);
    expect(isAsrInputSourceSelected("[('xkb', 'us'), ('ibus', 'asr')]", "uint32 0")).toBe(false);
});

test("gsettings input source normalization rewrites legacy doubao source to asr", () => {
    expect(normalizeGsettingsInputSources("[('xkb', 'us'), ('ibus', 'doubao-asr')]")).toBe(
        "[('xkb', 'us'), ('ibus', 'asr')]",
    );
});

test("gsettings input source normalization state preserves current index", () => {
    expect(normalizeGsettingsInputSourcesState("[('xkb', 'us'), ('ibus', 'doubao-asr')]", "uint32 1")).toEqual({
        sources: "[('xkb', 'us'), ('ibus', 'asr')]",
        current: "uint32 1",
    });
});

test("ibus runtime ready waits for service state", async () => {
    const server = net.createServer();
    try {
        try {
            fs.unlinkSync("/tmp/asr_ibus.sock");
        } catch {
            // ignore
        }
        try {
            fs.unlinkSync("/tmp/asr_ibus.ready");
        } catch {
            // ignore
        }

        await new Promise<void>((resolve, reject) => {
            server.once("error", reject);
            server.listen("/tmp/asr_ibus.sock", () => resolve());
        });

        const [, readyError] = await waitForIbusRuntimeReady();
        expect(readyError === null).toBe(true);
    } finally {
        await new Promise<void>((resolve) => server.close(() => resolve()));
        try {
            fs.unlinkSync("/tmp/asr_ibus.sock");
        } catch {
            // ignore
        }
        try {
            fs.unlinkSync("/tmp/asr_ibus.ready");
        } catch {
            // ignore
        }
    }
});

test("ibus daemon probe is callable", () => {
    expect(typeof isIbusDaemonRunning()).toBe("boolean");
});

test("ibus daemon path is present in the environment", () => {
    expect(typeof Bun.which("ibus-daemon")).toBe("string");
});
