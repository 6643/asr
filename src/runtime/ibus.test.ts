import { expect, test } from "bun:test";

import { getIbusComponentXml, getIbusEnginesXml } from "./ibus-meta.ts";
import { startIbusService } from "./ibus.ts";

test("ibus component xml uses inline engine definitions", () => {
    const xml = getIbusComponentXml();

    expect(xml).toContain("<engines>");
    expect(xml).toContain("<engine>");
    expect(xml).toContain("<name>asr</name>");
    expect(xml).toContain("<longname>ZH</longname>");
    expect(xml).toContain("<symbol>asr</symbol>");
    expect(xml).toContain("<exec>asr</exec>");
});

test("ibus engines xml exposes a fragment for legacy exec mode", () => {
    const xml = getIbusEnginesXml();

    expect(xml).toContain("<engines>");
    expect(xml).toContain("<name>asr</name>");
    expect(xml).toContain("<longname>ZH</longname>");
    expect(xml).toContain("<symbol>asr</symbol>");
    expect(xml).not.toContain("<component>");
});

test("ibus service entrypoint is exported", () => {
    expect(typeof startIbusService).toBe("function");
});

test("ibus service avoids business classes", async () => {
    const source = await Bun.file(new URL("./ibus-service.ts", import.meta.url)).text();

    expect(source).not.toMatch(/^\s*class\s+/m);
});

test("ibus runtime does not import dbus-next directly", async () => {
    const ibusSource = await Bun.file(new URL("./ibus.ts", import.meta.url)).text();
    const serviceSource = await Bun.file(new URL("./ibus-service.ts", import.meta.url)).text();

    expect(ibusSource).not.toContain("dbus-next");
    expect(serviceSource).not.toContain("dbus-next");
});

test("ibus runtime delegates service rpc to worker boundary", async () => {
    const source = await Bun.file(new URL("./ibus.ts", import.meta.url)).text();

    expect(source).toContain("callIbusServiceStringMethodInWorker");
    expect(source).not.toContain("./ibus-rpc.ts");
});

test("production gio dbus adapter exposes no spike helpers", async () => {
    const source = await Bun.file(new URL("./gio-dbus.ts", import.meta.url)).text();

    expect(source).not.toContain("Spike");
    expect(source).not.toContain("spike");
    expect(source).not.toContain("startGioIbusService");
    expect(source).not.toContain("IBUS_");
    expect(source).toContain("callGioDbusStringMethod");
});

test("ibus service entrypoint uses the ibus-specific gio service", async () => {
    const source = await Bun.file(new URL("./ibus-service.ts", import.meta.url)).text();

    expect(source).toContain("gio-ibus-service.ts");
    expect(source).toContain("startGioIbusService");
});

test("native gio dbus layer does not know ibus business constants", async () => {
    const source = await Bun.file(new URL("./gio-dbus-native.ts", import.meta.url)).text();

    expect(source).not.toContain("IBUS_");
    expect(source).not.toContain("./ibus-meta");
});

test("native gio dbus layer exposes a dedicated void-return method helper", async () => {
    const source = await Bun.file(new URL("./gio-dbus-native.ts", import.meta.url)).text();

    expect(source).toContain("callGioDbusVoidMethod");
    expect(source).toContain("callGioDbusVoidMethodWithLibraries");
    expect(source).toContain("extractVoidFromTuple");
});

test("ibus gio service rejects queued bus name ownership", async () => {
    const source = await Bun.file(new URL("./gio-ibus-service.ts", import.meta.url)).text();

    expect(source).toContain("DBUS_REQUEST_NAME_FLAG_DO_NOT_QUEUE");
    expect(source).toContain("isGioBusNameReplyOwned");
    expect(source).toContain("IBus bus name not owned");
});

test("ibus gio service logs method handler errors", async () => {
    const source = await Bun.file(new URL("./gio-ibus-service.ts", import.meta.url)).text();

    expect(source).toContain("logIbusMethodError");
    expect(source).toContain("method=${method}");
});

test("native gio dbus layer returns dbus errors for handler failures", async () => {
    const source = await Bun.file(new URL("./gio-dbus-native.ts", import.meta.url)).text();

    expect(source).toContain("g_dbus_method_invocation_return_dbus_error");
    expect(source).not.toContain("g_dbus_method_invocation_return_value(invocation, null)");
});

test("ibus gio service maps commit signal failures to retryable service unavailable", async () => {
    const source = await Bun.file(new URL("./gio-ibus-service.ts", import.meta.url)).text();

    expect(source).toContain('return "ERR service_unavailable"');
    expect(source).not.toContain('return "ERR commit_rejected"');
});

test("ibus gio service commit requires activation before reporting success", async () => {
    const source = await Bun.file(new URL("./gio-ibus-service.ts", import.meta.url)).text();

    expect(source).toContain('if (!engine.state.enabled && !engine.state.hasFocus) return "ERR engine_not_active"');
    expect(source).toContain('return "OK committed"');
});

test("ibus gio service commit no longer requires engine enabled or focused", async () => {
    const source = await Bun.file(new URL("./gio-ibus-service.ts", import.meta.url)).text();

    expect(source).not.toContain('return "ERR engine_not_enabled"');
    expect(source).not.toContain('return "ERR engine_not_focused"');
    expect(source).toContain('if (!engine) return "ERR engine_not_created"');
    expect(source).toContain('return "OK committed"');
});

test("ibus gio service status no longer requires engine enabled or focused", async () => {
    const source = await Bun.file(new URL("./gio-ibus-service.ts", import.meta.url)).text();

    expect(source).not.toContain('return "engine_not_enabled"');
    expect(source).not.toContain('return "engine_not_focused"');
    expect(source).toContain('if (!engine) return "engine_not_created"');
    expect(source).toContain('return "ready"');
});

test("ibus gio service logs commit diagnostics before emitting commit text", async () => {
    const source = await Bun.file(new URL("./gio-ibus-service.ts", import.meta.url)).text();

    expect(source).toContain('commit start path=${engine.objectPath} enabled=${engine.state.enabled} focused=${engine.state.hasFocus}');
    expect(source).toContain('CommitText emitted path=${objectPath}');
});

test("ibus startup does not spawn a separate service process", async () => {
    const source = await Bun.file(new URL("./ibus.ts", import.meta.url)).text();

    expect(source).not.toContain("Bun.spawn({");
    expect(source).not.toContain("bin/asr-service");
});
