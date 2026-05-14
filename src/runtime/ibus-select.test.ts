import { expect, test } from "bun:test";

import {
    ensureIbusServiceRunning,
    isIbusEngineReady,
    isIbusRuntimeStatusReady,
    isIbusServiceReady,
    isIbusServiceStatusAvailable,
    readIbusServiceStatus,
    startIbusService,
    waitForIbusRuntimeReady,
} from "./ibus.ts";
import {
    isInputSourceSelected,
    normalizeGsettingsInputSources,
    normalizeGsettingsInputSourcesState,
    parseGsettingsInputSources,
    selectGsettingsInputSourceState,
} from "./gsettings-input-source.ts";
import { err, ok } from "../util.ts";

test("gsettings input source parser recognizes the asr source", () => {
    const sources = parseGsettingsInputSources("[('xkb', 'us'), ('ibus', 'asr')]");

    expect(sources).toEqual([
        { backend: "xkb", id: "us" },
        { backend: "ibus", id: "asr" },
    ]);
    expect(isInputSourceSelected("[('xkb', 'us'), ('ibus', 'asr')]", "uint32 1", "asr")).toBe(true);
    expect(isInputSourceSelected("[('xkb', 'us'), ('ibus', 'asr')]", "uint32 0", "asr")).toBe(false);
});

test("gsettings input source normalization rewrites legacy doubao source to asr", () => {
    expect(normalizeGsettingsInputSources("[('xkb', 'us'), ('ibus', 'doubao-asr')]")).toBe("[('xkb', 'us'), ('ibus', 'asr')]");
});

test("gsettings input source normalization state preserves current index", () => {
    expect(normalizeGsettingsInputSourcesState("[('xkb', 'us'), ('ibus', 'doubao-asr')]", "uint32 1")).toEqual({
        sources: "[('xkb', 'us'), ('ibus', 'asr')]",
        current: "uint32 1",
    });
});

test("gsettings input source selection preserves existing sources", () => {
    expect(selectGsettingsInputSourceState("[('xkb', 'us'), ('ibus', 'pinyin')]", "uint32 0", "asr")).toEqual({
        sources: "[('xkb', 'us'), ('ibus', 'pinyin'), ('ibus', 'asr')]",
        current: "uint32 2",
    });
});

test("gsettings input source selection rewrites legacy source without replacing the list", () => {
    expect(selectGsettingsInputSourceState("[('xkb', 'us'), ('ibus', 'doubao-asr')]", "uint32 0", "asr")).toEqual({
        sources: "[('xkb', 'us'), ('ibus', 'asr')]",
        current: "uint32 1",
    });
});

test("ibus service running is not aliased to service entrypoint", () => {
    expect(ensureIbusServiceRunning).not.toBe(startIbusService);
});

test("ibus service readiness helpers distinguish service availability and engine readiness", () => {
    expect(isIbusServiceStatusAvailable(ok("engine_not_focused"))).toBe(true);
    expect(isIbusServiceStatusAvailable(err(new Error("unavailable")))).toBe(false);
    expect(isIbusRuntimeStatusReady("engine_not_focused")).toBe(false);
    expect(isIbusRuntimeStatusReady("ready")).toBe(true);
});

test("ibus runtime readiness exports remain callable", async () => {
    expect(typeof readIbusServiceStatus).toBe("function");
    expect(typeof isIbusServiceReady).toBe("function");
    expect(typeof isIbusEngineReady).toBe("function");
    expect(typeof waitForIbusRuntimeReady).toBe("function");
});

test("ibus service launcher remains callable", async () => {
    expect(typeof ensureIbusServiceRunning).toBe("function");
});

test("ibus runtime orchestration relies on gsettings selection for activation", async () => {
    const source = await Bun.file(new URL("./ibus.ts", import.meta.url)).text();

    expect(source).toContain("selectAsrInputSource");
    expect(source).not.toContain('"SetGlobalEngine"');
    expect(source).not.toContain('"CreateInputContext"');
});

test("session bus does not expose a callable ibus bus object in this environment", async () => {
    const proc = Bun.spawn([
        "gdbus",
        "introspect",
        "--session",
        "--dest",
        "org.freedesktop.IBus",
        "--object-path",
        "/org/freedesktop/IBus",
    ], { stdout: "pipe", stderr: "pipe" });
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();
    const exitCode = await proc.exited;

    expect(exitCode).toBe(0);
    expect(stderr.trim()).toBe("");
    expect(stdout).toContain("node /org/freedesktop/IBus {");
    expect(stdout).not.toContain("interface org.freedesktop.IBus");
});

test("ibus runtime no longer shells out to ibus engine", async () => {
    const source = await Bun.file(new URL("./ibus.ts", import.meta.url)).text();

    expect(source).not.toContain('runCommand("ibus", ["engine", IBUS_ENGINE_NAME])');
});

test("app runtime automatically switches to asr input method on startup", async () => {
    const source = await Bun.file(new URL("./app.ts", import.meta.url)).text();

    expect(source).toContain('["ibus", "engine", "asr"]');
    expect(source).toContain("Switched to ASR input method");
});

test("app runtime treats input method switch failure as fatal error", async () => {
    const source = await Bun.file(new URL("./app.ts", import.meta.url)).text();

    expect(source).toContain("abortIbusStartup");
    expect(source).toContain("failed to switch input method");
});

