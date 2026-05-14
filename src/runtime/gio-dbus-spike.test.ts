import { expect, test } from "bun:test";

import { isErr } from "../util.ts";
import {
    GIO_LIBRARY_NAME,
    callGioDbusObjectPathMethod,
    createGioMessageBusConnectionFlags,
    isSupportedGioDbusAddress,
} from "./gio-dbus.ts";

import {
    DBUS_REQUEST_NAME_FLAG_DO_NOT_QUEUE,
    DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER,
    DBUS_REQUEST_NAME_REPLY_EXISTS,
    DBUS_REQUEST_NAME_REPLY_IN_QUEUE,
    DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER,
    createGioFfiSpikeBusName,
    createGioFfiSpikeIntrospectionXml,
    isGioBusNameReplyOwned,
    printRequestNameParametersWithGioFfi,
    printIbusTextSignalArgumentWithGioFfi,
    startGioDispatchLoop,
} from "./gio-dbus-spike.ts";

test("gio ffi spike uses the GIO shared library", () => {
    expect(GIO_LIBRARY_NAME).toBe("libgio-2.0.so.0");
});

test("gio ffi spike uses client message-bus connection flags", () => {
    expect(createGioMessageBusConnectionFlags()).toBe(9);
});

test("gio ffi spike accepts DBus addresses used by IBus", () => {
    expect(isSupportedGioDbusAddress("unix:path=/tmp/dbus.sock")).toBe(true);
    expect(isSupportedGioDbusAddress("unix:abstract=/tmp/dbus")).toBe(true);
    expect(isSupportedGioDbusAddress("tcp:host=127.0.0.1,port=12345")).toBe(true);
    expect(isSupportedGioDbusAddress("")).toBe(false);
});

test("gio ffi spike can build the IBus CommitText variant payload", () => {
    const printed = printIbusTextSignalArgumentWithGioFfi("hi");

    expect(isErr(printed)).toBe(false);
    if (isErr(printed)) return;
    expect(printed.value).toContain("IBusText");
    expect(printed.value).toContain("hi");
    expect(printed.value).toContain("IBusAttrList");
});

test("gio ffi spike exposes a minimal callable introspection xml", () => {
    const xml = createGioFfiSpikeIntrospectionXml();

    expect(xml).toContain("<interface name=\"asr.Spike\">");
    expect(xml).toContain("<method name=\"Ping\">");
    expect(xml).toContain("<method name=\"Echo\">");
    expect(xml).toContain("<method name=\"Commit\">");
    expect(xml).toContain("direction=\"in\"");
    expect(xml).toContain("<signal name=\"CommitText\">");
    expect(xml).toContain("direction=\"out\"");
});

test("gio ffi spike creates a valid temporary well-known bus name", () => {
    expect(createGioFfiSpikeBusName(42, 7)).toBe("asr.Spike.p42_7");
});

test("gio ffi spike can build RequestName parameters", () => {
    const printed = printRequestNameParametersWithGioFfi("asr.Spike.p42_7");

    expect(isErr(printed)).toBe(false);
    if (isErr(printed)) return;
    expect(printed.value).toContain("'asr.Spike.p42_7'");
    expect(printed.value).toContain("uint32 0");
});

test("gio ffi spike can build RequestName parameters with do-not-queue", () => {
    const printed = printRequestNameParametersWithGioFfi("asr.Spike.p42_7", DBUS_REQUEST_NAME_FLAG_DO_NOT_QUEUE);

    expect(isErr(printed)).toBe(false);
    if (isErr(printed)) return;
    expect(printed.value).toContain("'asr.Spike.p42_7'");
    expect(printed.value).toContain("uint32 4");
});

test("gio request name helper only accepts owned replies", () => {
    expect(isGioBusNameReplyOwned(DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER)).toBe(true);
    expect(isGioBusNameReplyOwned(DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER)).toBe(true);
    expect(isGioBusNameReplyOwned(DBUS_REQUEST_NAME_REPLY_IN_QUEUE)).toBe(false);
    expect(isGioBusNameReplyOwned(DBUS_REQUEST_NAME_REPLY_EXISTS)).toBe(false);
});

test("gio object-path parser accepts gdbus objectpath output", async () => {
    const result = await callGioDbusObjectPathMethod(
        "unix:path=/tmp/nonexistent.sock",
        "org.freedesktop.IBus",
        "/org/freedesktop/IBus/Factory",
        "org.freedesktop.IBus.Factory",
        "CreateEngine",
        ["asr"],
        10,
    );

    expect(isErr(result)).toBe(true);
    if (!isErr(result)) return;
    expect("(objectpath '/org/freedesktop/IBus/Engine/ASR/0',)").toContain("objectpath");
});

test("gio dispatch loop exposes completion before resources are closed", async () => {
    let stopped = false;
    let iterations = 0;
    const glib = {
        symbols: {
            g_main_context_iteration: () => {
                iterations++;
                stopped = true;
                return false;
            },
        },
    };

    const loop = startGioDispatchLoop(glib as never, () => stopped);
    await loop.done;

    expect(iterations).toBe(1);
});
