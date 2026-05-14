// Internal GIO DBus FFI implementation.
import { CString, dlopen, JSCallback, ptr, read } from "bun:ffi";
import type { Pointer } from "bun:ffi";

import { err, isErr, ok, trySyncResult, type Result, withFinally, withFinallyAsync } from "../util.ts";

export type { Pointer } from "bun:ffi";

export const GIO_LIBRARY_NAME = "libgio-2.0.so.0";
const GLIB_LIBRARY_NAME = "libglib-2.0.so.0";
const GOBJECT_LIBRARY_NAME = "libgobject-2.0.so.0";

const DBUS_SERVICE_NAME = "org.freedesktop.DBus";
const DBUS_OBJECT_PATH = "/org/freedesktop/DBus";
const DBUS_INTERFACE_NAME = "org.freedesktop.DBus";
const DBUS_GET_ID_METHOD = "GetId";
const DBUS_REQUEST_NAME_METHOD = "RequestName";
const DBUS_RELEASE_NAME_METHOD = "ReleaseName";
const DBUS_FAILED_ERROR_NAME = "org.freedesktop.DBus.Error.Failed";
const SPIKE_OBJECT_PATH = "/asr/Spike";
const SPIKE_INTERFACE_NAME = "asr.Spike";
const SPIKE_PING_METHOD = "Ping";
const SPIKE_ECHO_METHOD = "Echo";
const SPIKE_COMMIT_METHOD = "Commit";
const SPIKE_COMMIT_TEXT_SIGNAL = "CommitText";
const SPIKE_PONG_RESPONSE = "pong";
const SPIKE_COMMIT_RESPONSE = "OK committed";

const G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT = 1;
const G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION = 8;
const DBUS_REQUEST_NAME_FLAGS_NONE = 0;
export const DBUS_REQUEST_NAME_FLAG_DO_NOT_QUEUE = 4;
export const DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER = 1;
export const DBUS_REQUEST_NAME_REPLY_IN_QUEUE = 2;
export const DBUS_REQUEST_NAME_REPLY_EXISTS = 3;
export const DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER = 4;

export type NullablePointer = Pointer | null;
type CStringArg = {
    bytes: Uint8Array;
    pointer: Pointer;
};
type GErrorSlot = {
    slot: BigUint64Array;
    pointer: Pointer;
};

export interface GioDbusGetIdResult {
    address: string;
    id: string;
}

export interface GioFfiRegisterObjectSpikeResult {
    destination: string;
    pingOutput: string;
    echoOutput: string;
}

export interface GioFfiEmitSignalSpikeResult {
    destination: string;
    output: string;
}

export interface GioFfiRequestNameSpikeResult {
    name: string;
    requestReply: number;
    releaseReply: number;
}

export interface GioFfiCommitRoundTripSpikeResult {
    destination: string;
    callOutput: string;
    signalOutput: string;
}

export const createGioMessageBusConnectionFlags = (): number => {
    return G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION;
};

export const isSupportedGioDbusAddress = (address: string): boolean => {
    const trimmed = address.trim();
    if (!trimmed) return false;
    return trimmed.startsWith("unix:") || trimmed.startsWith("tcp:") || trimmed.startsWith("nonce-tcp:");
};

export const isGioBusNameReplyOwned = (reply: number): boolean => {
    return reply === DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER || reply === DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER;
};

export const createGioFfiSpikeIntrospectionXml = (): string => {
    return [
        "<node>",
        `  <interface name="${SPIKE_INTERFACE_NAME}">`,
        `    <method name="${SPIKE_PING_METHOD}">`,
        '      <arg type="s" name="reply" direction="out"/>',
        "    </method>",
        `    <method name="${SPIKE_ECHO_METHOD}">`,
        '      <arg type="s" name="text" direction="in"/>',
        '      <arg type="s" name="reply" direction="out"/>',
        "    </method>",
        `    <method name="${SPIKE_COMMIT_METHOD}">`,
        '      <arg type="s" name="text" direction="in"/>',
        '      <arg type="s" name="reply" direction="out"/>',
        "    </method>",
        `    <signal name="${SPIKE_COMMIT_TEXT_SIGNAL}">`,
        '      <arg type="v" name="text"/>',
        "    </signal>",
        "  </interface>",
        "</node>",
    ].join("\n");
};

export const createGioFfiSpikeBusName = (pid = process.pid, nonce = Date.now()): string => {
    return `asr.Spike.p${pid}_${nonce}`;
};

export const cString = (value: string): CStringArg => {
    const bytes = new TextEncoder().encode(`${value}\0`);
    return { bytes, pointer: ptr(bytes) };
};

export const loadNativeLibraries = () => {
    const gio = dlopen(GIO_LIBRARY_NAME, {
        g_dbus_connection_new_for_address_sync: {
            args: ["ptr", "u32", "ptr", "ptr", "ptr"],
            returns: "ptr",
        },
        g_dbus_connection_call_sync: {
            args: ["ptr", "ptr", "ptr", "ptr", "ptr", "ptr", "ptr", "u32", "i32", "ptr", "ptr"],
            returns: "ptr",
        },
        g_dbus_connection_emit_signal: {
            args: ["ptr", "ptr", "ptr", "ptr", "ptr", "ptr", "ptr"],
            returns: "bool",
        },
        g_dbus_connection_flush_sync: {
            args: ["ptr", "ptr", "ptr"],
            returns: "bool",
        },
        g_dbus_connection_get_unique_name: {
            args: ["ptr"],
            returns: "cstring",
        },
        g_dbus_connection_register_object: {
            args: ["ptr", "ptr", "ptr", "ptr", "ptr", "ptr", "ptr"],
            returns: "u32",
        },
        g_dbus_connection_unregister_object: {
            args: ["ptr", "u32"],
            returns: "bool",
        },
        g_dbus_method_invocation_return_value: {
            args: ["ptr", "ptr"],
            returns: "void",
        },
        g_dbus_method_invocation_return_dbus_error: {
            args: ["ptr", "ptr", "ptr"],
            returns: "void",
        },
        g_dbus_node_info_lookup_interface: {
            args: ["ptr", "ptr"],
            returns: "ptr",
        },
        g_dbus_node_info_new_for_xml: {
            args: ["ptr", "ptr"],
            returns: "ptr",
        },
        g_dbus_node_info_unref: {
            args: ["ptr"],
            returns: "void",
        },
    });

    const glib = dlopen(GLIB_LIBRARY_NAME, {
        g_variant_get_child_value: {
            args: ["ptr", "usize"],
            returns: "ptr",
        },
        g_variant_get_string: {
            args: ["ptr", "ptr"],
            returns: "cstring",
        },
        g_variant_get_uint32: {
            args: ["ptr"],
            returns: "u32",
        },
        g_variant_new_array: {
            args: ["ptr", "ptr", "usize"],
            returns: "ptr",
        },
        g_variant_new_string: {
            args: ["ptr"],
            returns: "ptr",
        },
        g_variant_new_object_path: {
            args: ["ptr"],
            returns: "ptr",
        },
        g_variant_new_uint32: {
            args: ["u32"],
            returns: "ptr",
        },
        g_variant_new_boolean: {
            args: ["bool"],
            returns: "ptr",
        },
        g_variant_new_tuple: {
            args: ["ptr", "usize"],
            returns: "ptr",
        },
        g_variant_new_variant: {
            args: ["ptr"],
            returns: "ptr",
        },
        g_variant_print: {
            args: ["ptr", "bool"],
            returns: "ptr",
        },
        g_variant_ref_sink: {
            args: ["ptr"],
            returns: "ptr",
        },
        g_variant_unref: {
            args: ["ptr"],
            returns: "void",
        },
        g_variant_type_free: {
            args: ["ptr"],
            returns: "void",
        },
        g_variant_type_new: {
            args: ["ptr"],
            returns: "ptr",
        },
        g_error_free: {
            args: ["ptr"],
            returns: "void",
        },
        g_free: {
            args: ["ptr"],
            returns: "void",
        },
        g_main_context_iteration: {
            args: ["ptr", "bool"],
            returns: "bool",
        },
    });

    const gobject = dlopen(GOBJECT_LIBRARY_NAME, {
        g_object_unref: {
            args: ["ptr"],
            returns: "void",
        },
    });

    return { gio, glib, gobject };
};

export type GioNativeLibraries = ReturnType<typeof loadNativeLibraries>;

export const closeNativeLibraries = (libraries: GioNativeLibraries): void => {
    libraries.gobject.close();
    libraries.glib.close();
    libraries.gio.close();
};

export const createGErrorSlot = (): GErrorSlot => {
    const slot = new BigUint64Array(1);
    return { slot, pointer: ptr(slot) };
};

const toPointer = (value: number): Pointer => {
    return value as Pointer;
};

export const readGErrorMessage = (
    glib: GioNativeLibraries["glib"],
    errorSlot: GErrorSlot,
): string => {
    const errorPointer = read.ptr(errorSlot.pointer);
    if (!errorPointer) return "no GError";

    return withFinally(
        () => readGErrorMessageText(errorPointer),
        () => clearGErrorSlot(glib, errorSlot, errorPointer),
    );
};

const readGErrorMessageText = (errorPointer: number): string => {
    const messagePointer = read.ptr(toPointer(errorPointer), 8);
    if (!messagePointer) return "GError has no message";
    return String(new CString(toPointer(messagePointer)));
};

const clearGErrorSlot = (glib: GioNativeLibraries["glib"], errorSlot: GErrorSlot, errorPointer: number): void => {
    glib.symbols.g_error_free(toPointer(errorPointer));
    errorSlot.slot[0] = 0n;
};

const pointerArray = (values: Pointer[]): { bytes: BigUint64Array; pointer: Pointer } => {
    const bytes = new BigUint64Array(values.map((value) => BigInt(value as number)));
    return { bytes, pointer: ptr(bytes) };
};

const createVariantType = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    signature: string,
): Result<Pointer> => {
    const type = glib.symbols.g_variant_type_new(cString(signature).pointer);
    if (!type) return err(new Error(`Failed to create GVariantType: ${signature}`));
    return ok(type);
};

export const createEmptyArrayVariant = (
    glib: GioNativeLibraries["glib"],
    childSignature: string,
): Result<Pointer> => {
    const childType = createVariantType(glib, childSignature);
    if (isErr(childType)) return err(childType.error);

    return withFinally(
        () => createEmptyArrayVariantWithType(glib, childType.value, childSignature),
        () => glib.symbols.g_variant_type_free(childType.value),
    );
};

const createEmptyArrayVariantWithType = (
    glib: GioNativeLibraries["glib"],
    childType: Pointer,
    childSignature: string,
): Result<Pointer> => {
    const array = glib.symbols.g_variant_new_array(childType, null, 0);
    if (!array) return err(new Error(`Failed to create empty GVariant array: a${childSignature}`));
    return ok(array);
};

export const createStringVariant = (glib: GioNativeLibraries["glib"], value: string): Result<Pointer> => {
    const variant = glib.symbols.g_variant_new_string(cString(value).pointer);
    if (!variant) return err(new Error("Failed to create GVariant string"));
    return ok(variant);
};

export const createUint32Variant = (glib: GioNativeLibraries["glib"], value: number): Result<Pointer> => {
    const variant = glib.symbols.g_variant_new_uint32(value);
    if (!variant) return err(new Error("Failed to create GVariant uint32"));
    return ok(variant);
};

export const createBooleanVariant = (
    glib: GioNativeLibraries["glib"],
    value: boolean,
): Result<Pointer> => {
    const variant = glib.symbols.g_variant_new_boolean(value);
    if (!variant) return err(new Error("Failed to create GVariant boolean"));
    return ok(variant);
};

export const createObjectPathVariant = (
    glib: GioNativeLibraries["glib"],
    value: string,
): Result<Pointer> => {
    const variant = glib.symbols.g_variant_new_object_path(cString(value).pointer);
    if (!variant) return err(new Error("Failed to create GVariant object path"));
    return ok(variant);
};

export const createTupleVariant = (
    glib: GioNativeLibraries["glib"],
    children: Pointer[],
): Result<Pointer> => {
    const childrenArray = pointerArray(children);
    const tuple = glib.symbols.g_variant_new_tuple(childrenArray.pointer, children.length);
    if (!tuple) return err(new Error("Failed to create GVariant tuple"));
    return ok(tuple);
};

export const createVariantWrapper = (
    glib: GioNativeLibraries["glib"],
    value: Pointer,
): Result<Pointer> => {
    const variant = glib.symbols.g_variant_new_variant(value);
    if (!variant) return err(new Error("Failed to create GVariant variant wrapper"));
    return ok(variant);
};

const createIbusAttrListVariant = (glib: ReturnType<typeof loadNativeLibraries>["glib"]): Result<Pointer> => {
    const label = createStringVariant(glib, "IBusAttrList");
    if (isErr(label)) return err(label.error);

    const properties = createEmptyArrayVariant(glib, "{sv}");
    if (isErr(properties)) return err(properties.error);

    const attrs = createEmptyArrayVariant(glib, "v");
    if (isErr(attrs)) return err(attrs.error);

    return createTupleVariant(glib, [label.value, properties.value, attrs.value]);
};

const createIbusTextStructVariant = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    text: string,
): Result<Pointer> => {
    const label = createStringVariant(glib, "IBusText");
    if (isErr(label)) return err(label.error);

    const properties = createEmptyArrayVariant(glib, "{sv}");
    if (isErr(properties)) return err(properties.error);

    const textVariant = createStringVariant(glib, text);
    if (isErr(textVariant)) return err(textVariant.error);

    const attrList = createIbusAttrListVariant(glib);
    if (isErr(attrList)) return err(attrList.error);

    const attrListVariant = createVariantWrapper(glib, attrList.value);
    if (isErr(attrListVariant)) return err(attrListVariant.error);

    return createTupleVariant(glib, [label.value, properties.value, textVariant.value, attrListVariant.value]);
};

const createIbusTextSignalArgumentVariant = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    text: string,
): Result<Pointer> => {
    const ibusText = createIbusTextStructVariant(glib, text);
    if (isErr(ibusText)) return err(ibusText.error);
    return createVariantWrapper(glib, ibusText.value);
};

export const createIbusTextSignalParametersVariant = (
    glib: GioNativeLibraries["glib"],
    text: string,
): Result<Pointer> => {
    const signalArgument = createIbusTextSignalArgumentVariant(glib, text);
    if (isErr(signalArgument)) return err(signalArgument.error);
    return createTupleVariant(glib, [signalArgument.value]);
};

export const printVariant = (glib: GioNativeLibraries["glib"], variant: Pointer): Result<string> => {
    const text = glib.symbols.g_variant_print(variant, true);
    if (!text) return err(new Error("g_variant_print returned null"));

    try {
        return ok(String(new CString(text)));
    } finally {
        glib.symbols.g_free(text);
    }
};

export const createStringTupleVariant = (
    glib: GioNativeLibraries["glib"],
    value: string,
): Result<Pointer> => {
    const text = createStringVariant(glib, value);
    if (isErr(text)) return err(text.error);
    return createTupleVariant(glib, [text.value]);
};

export const createRequestNameParametersVariant = (
    glib: GioNativeLibraries["glib"],
    name: string,
    flags = DBUS_REQUEST_NAME_FLAGS_NONE,
): Result<Pointer> => {
    const busName = createStringVariant(glib, name);
    if (isErr(busName)) return err(busName.error);

    const flagsValue = createUint32Variant(glib, flags);
    if (isErr(flagsValue)) return err(flagsValue.error);

    return createTupleVariant(glib, [busName.value, flagsValue.value]);
};

const createSpikeMethodCallback = (libraries: ReturnType<typeof loadNativeLibraries>): JSCallback => {
    return new JSCallback(
        (
            _connection: Pointer,
            _sender: Pointer,
            _objectPath: Pointer,
            _interfaceName: Pointer,
            methodName: Pointer,
            parameters: Pointer,
            invocation: Pointer,
            _userData: Pointer,
        ): void => {
            const method = String(new CString(methodName));
            const response =
                method === SPIKE_PING_METHOD
                    ? createStringTupleVariant(libraries.glib, SPIKE_PONG_RESPONSE)
                    : method === SPIKE_COMMIT_METHOD
                      ? createCommitMethodResponse(libraries, _connection, parameters)
                    : createEchoMethodResponse(libraries.glib, method, parameters);
            if (isErr(response)) return;

            libraries.gio.symbols.g_dbus_method_invocation_return_value(invocation, response.value);
        },
        {
            args: ["ptr", "ptr", "ptr", "ptr", "ptr", "ptr", "ptr", "ptr"],
            returns: "void",
        },
    );
};

const emitSpikeCommitTextSignal = (
    libraries: ReturnType<typeof loadNativeLibraries>,
    connection: Pointer,
    text: string,
): Result<void> => {
    const rawParameters = createIbusTextSignalParametersVariant(libraries.glib, text);
    if (isErr(rawParameters)) return err(rawParameters.error);

    const parameters = libraries.glib.symbols.g_variant_ref_sink(rawParameters.value);
    if (!parameters) return err(new Error("g_variant_ref_sink returned null"));

    return withFinally(
        () => emitSpikeCommitTextSignalWithParameters(libraries, connection, parameters),
        () => libraries.glib.symbols.g_variant_unref(parameters),
    );
};

const emitSpikeCommitTextSignalWithParameters = (
    libraries: ReturnType<typeof loadNativeLibraries>,
    connection: Pointer,
    parameters: Pointer,
): Result<void> => {
    const signalError = createGErrorSlot();
    const sent = libraries.gio.symbols.g_dbus_connection_emit_signal(
        connection,
        null,
        cString(SPIKE_OBJECT_PATH).pointer,
        cString(SPIKE_INTERFACE_NAME).pointer,
        cString(SPIKE_COMMIT_TEXT_SIGNAL).pointer,
        parameters,
        signalError.pointer,
    );
    if (!sent) {
        return err(new Error(`g_dbus_connection_emit_signal returned false: ${readGErrorMessage(libraries.glib, signalError)}`));
    }

    return ok(undefined);
};

const createCommitMethodResponse = (
    libraries: ReturnType<typeof loadNativeLibraries>,
    connection: Pointer,
    parameters: Pointer,
): Result<Pointer> => {
    const text = extractFirstStringFromTuple(libraries.glib, parameters);
    if (isErr(text)) return err(text.error);

    const emitted = emitSpikeCommitTextSignal(libraries, connection, text.value);
    if (isErr(emitted)) return err(emitted.error);

    return createStringTupleVariant(libraries.glib, SPIKE_COMMIT_RESPONSE);
};

const createEchoMethodResponse = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    method: string,
    parameters: Pointer,
): Result<Pointer> => {
    if (method !== SPIKE_ECHO_METHOD) return err(new Error(`unsupported spike method: ${method}`));

    const text = extractFirstStringFromTuple(glib, parameters);
    if (isErr(text)) return err(text.error);

    return createStringTupleVariant(glib, `echo:${text.value}`);
};

const runCommandAsync = async (command: string[], timeoutMs: number): Promise<Result<string>> => {
    const proc = Bun.spawn(command, { stdout: "pipe", stderr: "pipe" });
    const timeout = Bun.sleep(timeoutMs).then(() => "timeout" as const);
    const exited = proc.exited.then(() => "exited" as const);
    const status = await Promise.race([timeout, exited]);

    if (status === "timeout") {
        proc.kill("SIGTERM");
        return err(new Error(`${command.join(" ")} timed out after ${timeoutMs}ms`));
    }

    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();
    if ((await proc.exited) !== 0) {
        return err(new Error(`${command.join(" ")} failed: ${stderr.trim() || stdout.trim()}`));
    }

    return ok(stdout.trim());
};

const spinMainContextUntil = async (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    done: () => boolean,
    timeoutMs: number,
): Promise<boolean> => {
    return spinMainContextAttempt(glib, done, timeoutMs, Date.now());
};

const spinMainContextAttempt = async (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    done: () => boolean,
    timeoutMs: number,
    startedAt: number,
): Promise<boolean> => {
    if (done()) return true;
    glib.symbols.g_main_context_iteration(null, false);
    if (Date.now() - startedAt > timeoutMs) return false;
    await Bun.sleep(5);
    return spinMainContextAttempt(glib, done, timeoutMs, startedAt);
};

const runMonitorForSignal = async (
    address: string,
    destination: string,
    emitSignal: () => Result<void>,
    timeoutMs: number,
): Promise<Result<string>> => {
    const proc = Bun.spawn(
        ["gdbus", "monitor", "--address", address, "--dest", destination, "--object-path", SPIKE_OBJECT_PATH],
        { stdout: "pipe", stderr: "pipe" },
    );

    await Bun.sleep(150);

    const emitted = emitSignal();
    if (isErr(emitted)) {
        proc.kill("SIGTERM");
        return err(emitted.error);
    }

    await Bun.sleep(timeoutMs);
    proc.kill("SIGTERM");

    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();
    if (!stdout.includes(SPIKE_COMMIT_TEXT_SIGNAL)) {
        return err(new Error(`signal monitor did not observe ${SPIKE_COMMIT_TEXT_SIGNAL}: ${stderr || stdout}`));
    }

    return ok(stdout.trim());
};

export const extractFirstStringFromTuple = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    result: Pointer,
): Result<string> => {
    const child = glib.symbols.g_variant_get_child_value(result, 0);
    if (!child) return err(new Error("GVariant tuple has no first child"));

    return withFinally(
        () => extractStringFromVariant(glib, child),
        () => glib.symbols.g_variant_unref(child),
    );
};

const extractStringFromVariant = (glib: ReturnType<typeof loadNativeLibraries>["glib"], child: Pointer): Result<string> => {
    const raw = glib.symbols.g_variant_get_string(child, null);
    const value = String(raw);
    if (!value) return err(new Error("GVariant first child is an empty string"));
    return ok(value);
};

export const extractFirstUint32FromTuple = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    result: Pointer,
): Result<number> => {
    const child = glib.symbols.g_variant_get_child_value(result, 0);
    if (!child) return err(new Error("GVariant tuple has no first child"));

    return withFinally(
        () => ok(glib.symbols.g_variant_get_uint32(child)),
        () => glib.symbols.g_variant_unref(child),
    );
};

export const callDbusGetIdWithGioFfi = (address: string, timeoutMs = 1500): Result<GioDbusGetIdResult> => {
    if (!isSupportedGioDbusAddress(address)) {
        return err(new Error(`Unsupported DBus address for GIO FFI spike: ${address || "<empty>"}`));
    }

    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);

    const resources = { connection: null as NullablePointer, result: null as NullablePointer };
    return withFinally(
        () => callDbusGetIdWithLibraries(libraries.value, resources, address, timeoutMs),
        () => closeGioCallResources(libraries.value, resources),
    );
};

const loadNativeLibrariesResult = (): Result<GioNativeLibraries> => {
    const result = trySyncResult(() => loadNativeLibraries());
    if (isErr(result)) return err(new Error(`Failed to load GIO libraries: ${result.error.message}`));
    return result;
};

const closeGioCallResources = (
    libraries: GioNativeLibraries,
    resources: { connection?: NullablePointer; result?: NullablePointer; parameters?: NullablePointer },
): void => {
    unrefVariantIfPresent(libraries, resources.result ?? null);
    unrefVariantIfPresent(libraries, resources.parameters ?? null);
    unrefObjectIfPresent(libraries, resources.connection ?? null);
    closeNativeLibraries(libraries);
};

const unrefVariantIfPresent = (libraries: GioNativeLibraries, value: NullablePointer): void => {
    if (!value) return;
    libraries.glib.symbols.g_variant_unref(value);
};

const unrefObjectIfPresent = (libraries: GioNativeLibraries, value: NullablePointer): void => {
    if (!value) return;
    libraries.gobject.symbols.g_object_unref(value);
};

const callDbusGetIdWithLibraries = (
    libraries: GioNativeLibraries,
    resources: { connection: NullablePointer; result: NullablePointer },
    address: string,
    timeoutMs: number,
): Result<GioDbusGetIdResult> => {
    const connection = openGioAddressConnection(libraries, address);
    if (isErr(connection)) return err(connection.error);
    resources.connection = connection.value;

    const callError = createGErrorSlot();
    resources.result = libraries.gio.symbols.g_dbus_connection_call_sync(
        connection.value,
        cString(DBUS_SERVICE_NAME).pointer,
        cString(DBUS_OBJECT_PATH).pointer,
        cString(DBUS_INTERFACE_NAME).pointer,
        cString(DBUS_GET_ID_METHOD).pointer,
        null,
        null,
        0,
        timeoutMs,
        null,
        callError.pointer,
    );
    if (!resources.result) return err(new Error(`g_dbus_connection_call_sync returned null: ${readGErrorMessage(libraries.glib, callError)}`));

    const id = extractFirstStringFromTuple(libraries.glib, resources.result);
    if (isErr(id)) return err(id.error);

    return ok({ address, id: id.value });
};

const openGioAddressConnection = (libraries: GioNativeLibraries, address: string): Result<Pointer> => {
    const connectionError = createGErrorSlot();
    const connection = libraries.gio.symbols.g_dbus_connection_new_for_address_sync(
        cString(address).pointer,
        createGioMessageBusConnectionFlags(),
        null,
        null,
        connectionError.pointer,
    );
    if (!connection) {
        return err(
            new Error(
                `g_dbus_connection_new_for_address_sync returned null: ${readGErrorMessage(libraries.glib, connectionError)}`,
            ),
        );
    }
    return ok(connection);
};

const createStringParametersVariant = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    args: string[],
): Result<Pointer | null> => {
    if (args.length === 0) return ok(null);

    const values = args.reduce<Result<Pointer[]>>((state, value) => appendStringVariant(glib, state, value), ok([]));
    if (isErr(values)) return err(values.error);
    return createTupleVariant(glib, values.value);
};

const appendStringVariant = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    state: Result<Pointer[]>,
    value: string,
): Result<Pointer[]> => {
    if (isErr(state)) return state;
    const variant = createStringVariant(glib, value);
    if (isErr(variant)) return err(variant.error);
    return ok([...state.value, variant.value]);
};

export const callGioDbusObjectPathMethod = async (
    address: string,
    destination: string,
    objectPath: string,
    interfaceName: string,
    methodName: string,
    args: string[] = [],
    timeoutMs = 1500,
): Promise<Result<string>> => {
    if (!isSupportedGioDbusAddress(address)) {
        return err(new Error(`Unsupported DBus address for GIO DBus call: ${address || "<empty>"}`));
    }

    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);

    const resources = { connection: null as NullablePointer, parameters: null as NullablePointer, result: null as NullablePointer };
    return withFinallyAsync(
        () => callGioDbusObjectPathMethodWithLibraries(libraries.value, resources, address, destination, objectPath, interfaceName, methodName, args, timeoutMs),
        async () => closeGioCallResources(libraries.value, resources),
    );
};

const callGioDbusObjectPathMethodWithLibraries = async (
    libraries: GioNativeLibraries,
    resources: { connection: NullablePointer; parameters: NullablePointer; result: NullablePointer },
    address: string,
    destination: string,
    objectPath: string,
    interfaceName: string,
    methodName: string,
    args: string[],
    timeoutMs: number,
): Promise<Result<string>> => {
    const connection = openGioAddressConnection(libraries, address);
    if (isErr(connection)) return err(connection.error);
    resources.connection = connection.value;

    const rawParameters = createStringParametersVariant(libraries.glib, args);
    if (isErr(rawParameters)) return err(rawParameters.error);
    const parameters = refSinkOptionalVariant(libraries.glib, rawParameters.value, "g_variant_ref_sink returned null for method parameters");
    if (isErr(parameters)) return err(parameters.error);
    resources.parameters = parameters.value;

    const command = createGdbusCallCommand(address, destination, objectPath, interfaceName, methodName, args);
    const output = await runDispatchedGdbusCommand(
        libraries,
        command,
        timeoutMs,
        `Timed out while dispatching ${methodName} GDBus method callback`,
    );
    if (isErr(output)) return err(output.error);

    const parsed = parseGdbusObjectPathOutput(output.value, methodName);
    if (isErr(parsed)) return err(parsed.error);
    return ok(parsed.value);
};

const createGdbusCallCommand = (
    address: string,
    destination: string,
    objectPath: string,
    interfaceName: string,
    methodName: string,
    args: string[] = [],
): string[] => [
    "gdbus",
    "call",
    "--address",
    address,
    "--dest",
    destination,
    "--object-path",
    objectPath,
    "--method",
    `${interfaceName}.${methodName}`,
    ...args,
];

const parseGdbusObjectPathOutput = (output: string, methodName: string): Result<string> => {
    const match = output.match(/\(objectpath\s+'([^']+)'\s*,?\s*\)/);
    if (!match?.[1]) return err(new Error(`Failed to parse ${methodName} object path from gdbus output: ${output}`));
    return ok(match[1]);
};

export const callGioDbusStringMethod = (
    address: string,
    destination: string,
    objectPath: string,
    interfaceName: string,
    methodName: string,
    args: string[] = [],
    timeoutMs = 1500,
): Result<string> => {
    if (!isSupportedGioDbusAddress(address)) {
        return err(new Error(`Unsupported DBus address for GIO DBus call: ${address || "<empty>"}`));
    }

    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);

    const resources = { connection: null as NullablePointer, parameters: null as NullablePointer, result: null as NullablePointer };
    return withFinally(
        () => callGioDbusStringMethodWithLibraries(libraries.value, resources, address, destination, objectPath, interfaceName, methodName, args, timeoutMs),
        () => closeGioCallResources(libraries.value, resources),
    );
};

export const callGioDbusVoidMethod = (
    address: string,
    destination: string,
    objectPath: string,
    interfaceName: string,
    methodName: string,
    args: string[] = [],
    timeoutMs = 1500,
): Result<void> => {
    if (!isSupportedGioDbusAddress(address)) {
        return err(new Error(`Unsupported DBus address for GIO DBus call: ${address || "<empty>"}`));
    }

    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);

    const resources = { connection: null as NullablePointer, parameters: null as NullablePointer, result: null as NullablePointer };
    return withFinally(
        () => callGioDbusVoidMethodWithLibraries(libraries.value, resources, address, destination, objectPath, interfaceName, methodName, args, timeoutMs),
        () => closeGioCallResources(libraries.value, resources),
    );
};

const callGioDbusStringMethodWithLibraries = (
    libraries: GioNativeLibraries,
    resources: { connection: NullablePointer; parameters: NullablePointer; result: NullablePointer },
    address: string,
    destination: string,
    objectPath: string,
    interfaceName: string,
    methodName: string,
    args: string[],
    timeoutMs: number,
): Result<string> => {
    const connection = openGioAddressConnection(libraries, address);
    if (isErr(connection)) return err(connection.error);
    resources.connection = connection.value;

    const rawParameters = createStringParametersVariant(libraries.glib, args);
    if (isErr(rawParameters)) return err(rawParameters.error);
    const parameters = refSinkOptionalVariant(libraries.glib, rawParameters.value, "g_variant_ref_sink returned null for method parameters");
    if (isErr(parameters)) return err(parameters.error);
    resources.parameters = parameters.value;

    const callError = createGErrorSlot();
    resources.result = libraries.gio.symbols.g_dbus_connection_call_sync(
        connection.value,
        cString(destination).pointer,
        cString(objectPath).pointer,
        cString(interfaceName).pointer,
        cString(methodName).pointer,
        resources.parameters,
        null,
        0,
        timeoutMs,
        null,
        callError.pointer,
    );
    if (!resources.result) return err(new Error(`${methodName} returned null: ${readGErrorMessage(libraries.glib, callError)}`));

    return extractFirstStringFromTuple(libraries.glib, resources.result);
};

const callGioDbusVoidMethodWithLibraries = (
    libraries: GioNativeLibraries,
    resources: { connection: NullablePointer; parameters: NullablePointer; result: NullablePointer },
    address: string,
    destination: string,
    objectPath: string,
    interfaceName: string,
    methodName: string,
    args: string[],
    timeoutMs: number,
): Result<void> => {
    const connection = openGioAddressConnection(libraries, address);
    if (isErr(connection)) return err(connection.error);
    resources.connection = connection.value;

    const rawParameters = createStringParametersVariant(libraries.glib, args);
    if (isErr(rawParameters)) return err(rawParameters.error);
    const parameters = refSinkOptionalVariant(libraries.glib, rawParameters.value, "g_variant_ref_sink returned null for method parameters");
    if (isErr(parameters)) return err(parameters.error);
    resources.parameters = parameters.value;

    const callError = createGErrorSlot();
    resources.result = libraries.gio.symbols.g_dbus_connection_call_sync(
        connection.value,
        cString(destination).pointer,
        cString(objectPath).pointer,
        cString(interfaceName).pointer,
        cString(methodName).pointer,
        resources.parameters,
        null,
        0,
        timeoutMs,
        null,
        callError.pointer,
    );
    if (!resources.result) return err(new Error(`${methodName} returned null: ${readGErrorMessage(libraries.glib, callError)}`));

    return extractVoidFromTuple(libraries.glib, resources.result, methodName);
};

const extractVoidFromTuple = (
    glib: GioNativeLibraries["glib"],
    result: Pointer,
    methodName: string,
): Result<void> => {
    const printed = printVariant(glib, result);
    if (isErr(printed)) return err(printed.error);
    if (printed.value.trim() !== "()") {
        return err(new Error(`${methodName} returned unexpected non-void tuple: ${printed.value}`));
    }
    return ok(undefined);
};

const refSinkOptionalVariant = (
    glib: GioNativeLibraries["glib"],
    value: NullablePointer,
    message: string,
): Result<NullablePointer> => {
    if (!value) return ok(null);
    return refSinkVariant(glib, value, message);
};

const refSinkVariant = (glib: GioNativeLibraries["glib"], value: Pointer, message: string): Result<Pointer> => {
    const variant = glib.symbols.g_variant_ref_sink(value);
    if (!variant) return err(new Error(message));
    return ok(variant);
};

export const printIbusTextSignalArgumentWithGioFfi = (text: string): Result<string> => {
    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);
    const resources = { parameters: null as NullablePointer };
    return withFinally(
        () => printIbusTextSignalArgumentWithLibraries(libraries.value, resources, text),
        () => closeGioCallResources(libraries.value, resources),
    );
};

const printIbusTextSignalArgumentWithLibraries = (
    libraries: GioNativeLibraries,
    resources: { parameters: NullablePointer },
    text: string,
): Result<string> => {
    const variant = createIbusTextSignalArgumentVariant(libraries.glib, text);
    if (isErr(variant)) return err(variant.error);

    const signalArgument = refSinkVariant(libraries.glib, variant.value, "g_variant_ref_sink returned null");
    if (isErr(signalArgument)) return err(signalArgument.error);
    resources.parameters = signalArgument.value;

    return printVariant(libraries.glib, signalArgument.value);
};

export const printRequestNameParametersWithGioFfi = (
    name: string,
    flags = DBUS_REQUEST_NAME_FLAGS_NONE,
): Result<string> => {
    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);
    const resources = { parameters: null as NullablePointer };
    return withFinally(
        () => printRequestNameParametersWithLibraries(libraries.value, resources, name, flags),
        () => closeGioCallResources(libraries.value, resources),
    );
};

const printRequestNameParametersWithLibraries = (
    libraries: GioNativeLibraries,
    resources: { parameters: NullablePointer },
    name: string,
    flags: number,
): Result<string> => {
    const rawParameters = createRequestNameParametersVariant(libraries.glib, name, flags);
    if (isErr(rawParameters)) return err(rawParameters.error);

    const parameters = refSinkVariant(libraries.glib, rawParameters.value, "g_variant_ref_sink returned null");
    if (isErr(parameters)) return err(parameters.error);
    resources.parameters = parameters.value;

    return printVariant(libraries.glib, parameters.value);
};

export const runRegisterObjectSpikeWithGioFfi = async (
    address: string,
    timeoutMs = 1500,
): Promise<Result<GioFfiRegisterObjectSpikeResult>> => {
    if (!isSupportedGioDbusAddress(address)) {
        return err(new Error(`Unsupported DBus address for GIO FFI spike: ${address || "<empty>"}`));
    }

    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);

    const resources = createSpikeObjectResources(libraries.value);
    return withFinally(
        () => runRegisterObjectSpikeWithLibraries(libraries.value, resources, address, timeoutMs),
        () => closeSpikeObjectResources(libraries.value, resources),
    );
};

interface SpikeObjectResources {
    connection: NullablePointer;
    nodeInfo: NullablePointer;
    registrationId: number;
    methodCallback: JSCallback;
    vtableBytes: BigUint64Array;
    vtable: Pointer;
}

const createSpikeObjectResources = (libraries: GioNativeLibraries): SpikeObjectResources => {
    const methodCallback = createSpikeMethodCallback(libraries);
    const vtableBytes = new BigUint64Array([BigInt(methodCallback.ptr as number), 0n, 0n]);
    return {
        connection: null,
        nodeInfo: null,
        registrationId: 0,
        methodCallback,
        vtableBytes,
        vtable: ptr(vtableBytes),
    };
};

const closeSpikeObjectResources = (libraries: GioNativeLibraries, resources: SpikeObjectResources): void => {
    unregisterSpikeObjectIfNeeded(libraries, resources);
    resources.methodCallback.close();
    unrefNodeInfoIfPresent(libraries, resources.nodeInfo);
    unrefObjectIfPresent(libraries, resources.connection);
    closeNativeLibraries(libraries);
};

const unregisterSpikeObjectIfNeeded = (libraries: GioNativeLibraries, resources: SpikeObjectResources): void => {
    if (resources.registrationId === 0 || !resources.connection) return;
    libraries.gio.symbols.g_dbus_connection_unregister_object(resources.connection, resources.registrationId);
};

const unrefNodeInfoIfPresent = (libraries: GioNativeLibraries, value: NullablePointer): void => {
    if (!value) return;
    libraries.gio.symbols.g_dbus_node_info_unref(value);
};

const runRegisterObjectSpikeWithLibraries = async (
    libraries: GioNativeLibraries,
    resources: SpikeObjectResources,
    address: string,
    timeoutMs: number,
): Promise<Result<GioFfiRegisterObjectSpikeResult>> => {
    const registration = registerSpikeObject(libraries, resources, address);
    if (isErr(registration)) return err(registration.error);

    const pingOutput = await runDispatchedGdbusCommand(
        libraries,
        createSpikeGdbusCallCommand(address, registration.value.destination, SPIKE_PING_METHOD),
        timeoutMs,
        "Timed out while dispatching Ping GDBus method callback",
    );
    if (isErr(pingOutput)) return err(pingOutput.error);

    const echoOutput = await runDispatchedGdbusCommand(
        libraries,
        [...createSpikeGdbusCallCommand(address, registration.value.destination, SPIKE_ECHO_METHOD), "实时识别"],
        timeoutMs,
        "Timed out while dispatching Echo GDBus method callback",
    );
    if (isErr(echoOutput)) return err(echoOutput.error);

    return ok({ destination: registration.value.destination, pingOutput: pingOutput.value, echoOutput: echoOutput.value });
};

const registerSpikeObject = (
    libraries: GioNativeLibraries,
    resources: SpikeObjectResources,
    address: string,
): Result<{ destination: string }> => {
    const connection = openGioAddressConnection(libraries, address);
    if (isErr(connection)) return err(connection.error);
    resources.connection = connection.value;

    const destination = String(libraries.gio.symbols.g_dbus_connection_get_unique_name(connection.value));
    if (!destination) return err(new Error("g_dbus_connection_get_unique_name returned empty"));

    const nodeInfo = createSpikeNodeInfo(libraries);
    if (isErr(nodeInfo)) return err(nodeInfo.error);
    resources.nodeInfo = nodeInfo.value;

    const interfaceInfo = lookupSpikeInterface(libraries, nodeInfo.value);
    if (isErr(interfaceInfo)) return err(interfaceInfo.error);

    const registrationId = registerSpikeObjectPath(libraries, connection.value, interfaceInfo.value, resources.vtable);
    if (isErr(registrationId)) return err(registrationId.error);
    resources.registrationId = registrationId.value;

    return ok({ destination });
};

const createSpikeNodeInfo = (libraries: GioNativeLibraries): Result<Pointer> => {
    const xmlError = createGErrorSlot();
    const nodeInfo = libraries.gio.symbols.g_dbus_node_info_new_for_xml(
        cString(createGioFfiSpikeIntrospectionXml()).pointer,
        xmlError.pointer,
    );
    if (!nodeInfo) return err(new Error(`g_dbus_node_info_new_for_xml returned null: ${readGErrorMessage(libraries.glib, xmlError)}`));
    return ok(nodeInfo);
};

const lookupSpikeInterface = (libraries: GioNativeLibraries, nodeInfo: Pointer): Result<Pointer> => {
    const interfaceInfo = libraries.gio.symbols.g_dbus_node_info_lookup_interface(
        nodeInfo,
        cString(SPIKE_INTERFACE_NAME).pointer,
    );
    if (!interfaceInfo) return err(new Error(`Interface not found in introspection XML: ${SPIKE_INTERFACE_NAME}`));
    return ok(interfaceInfo);
};

const registerSpikeObjectPath = (
    libraries: GioNativeLibraries,
    connection: Pointer,
    interfaceInfo: Pointer,
    vtable: Pointer,
): Result<number> => {
    const registerError = createGErrorSlot();
    const registrationId = libraries.gio.symbols.g_dbus_connection_register_object(
        connection,
        cString(SPIKE_OBJECT_PATH).pointer,
        interfaceInfo,
        vtable,
        null,
        null,
        registerError.pointer,
    );
    if (registrationId === 0) {
        return err(new Error(`g_dbus_connection_register_object returned 0: ${readGErrorMessage(libraries.glib, registerError)}`));
    }
    return ok(registrationId);
};

const createSpikeGdbusCallCommand = (address: string, destination: string, method: string): string[] => [
    "gdbus",
    "call",
    "--address",
    address,
    "--dest",
    destination,
    "--object-path",
    SPIKE_OBJECT_PATH,
    "--method",
    `${SPIKE_INTERFACE_NAME}.${method}`,
];

const runDispatchedGdbusCommand = async (
    libraries: GioNativeLibraries,
    command: string[],
    timeoutMs: number,
    timeoutMessage: string,
): Promise<Result<string>> => {
    let done = false;
    const task = runCommandAsync(command, timeoutMs).finally(() => {
        done = true;
    });
    const dispatched = await spinMainContextUntil(libraries.glib, () => done, timeoutMs);
    if (!dispatched) return err(new Error(timeoutMessage));
    const output = await task;
    if (isErr(output)) return err(output.error);
    return output;
};

export const runEmitSignalSpikeWithGioFfi = async (
    address: string,
    timeoutMs = 250,
): Promise<Result<GioFfiEmitSignalSpikeResult>> => {
    if (!isSupportedGioDbusAddress(address)) {
        return err(new Error(`Unsupported DBus address for GIO FFI spike: ${address || "<empty>"}`));
    }

    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);

    const resources = { connection: null as NullablePointer, parameters: null as NullablePointer };
    return withFinally(
        () => runEmitSignalSpikeWithLibraries(libraries.value, resources, address, timeoutMs),
        () => closeGioCallResources(libraries.value, resources),
    );
};

const runEmitSignalSpikeWithLibraries = async (
    libraries: GioNativeLibraries,
    resources: { connection: NullablePointer; parameters: NullablePointer },
    address: string,
    timeoutMs: number,
): Promise<Result<GioFfiEmitSignalSpikeResult>> => {
    const connection = openGioAddressConnection(libraries, address);
    if (isErr(connection)) return err(connection.error);
    resources.connection = connection.value;

    const destination = String(libraries.gio.symbols.g_dbus_connection_get_unique_name(connection.value));
    if (!destination) return err(new Error("g_dbus_connection_get_unique_name returned empty"));

    const rawParameters = createIbusTextSignalParametersVariant(libraries.glib, "实时识别");
    if (isErr(rawParameters)) return err(rawParameters.error);
    const parameters = refSinkVariant(libraries.glib, rawParameters.value, "g_variant_ref_sink returned null");
    if (isErr(parameters)) return err(parameters.error);
    resources.parameters = parameters.value;

    const output = await runMonitorForSignal(
        address,
        destination,
        () => emitSpikeSignalAndFlush(libraries, connection.value, parameters.value),
        timeoutMs,
    );
    if (isErr(output)) return err(output.error);

    return ok({ destination, output: output.value });
};

const emitSpikeSignalAndFlush = (
    libraries: GioNativeLibraries,
    connection: Pointer,
    parameters: Pointer,
): Result<void> => {
    const signalError = createGErrorSlot();
    const sent = libraries.gio.symbols.g_dbus_connection_emit_signal(
        connection,
        null,
        cString(SPIKE_OBJECT_PATH).pointer,
        cString(SPIKE_INTERFACE_NAME).pointer,
        cString(SPIKE_COMMIT_TEXT_SIGNAL).pointer,
        parameters,
        signalError.pointer,
    );
    if (!sent) return err(new Error(`g_dbus_connection_emit_signal returned false: ${readGErrorMessage(libraries.glib, signalError)}`));

    const flushError = createGErrorSlot();
    const flushed = libraries.gio.symbols.g_dbus_connection_flush_sync(connection, null, flushError.pointer);
    if (!flushed) return err(new Error(`g_dbus_connection_flush_sync returned false: ${readGErrorMessage(libraries.glib, flushError)}`));

    return ok(undefined);
};

export const runRequestNameSpikeWithGioFfi = (address: string, timeoutMs = 1500): Result<GioFfiRequestNameSpikeResult> => {
    if (!isSupportedGioDbusAddress(address)) {
        return err(new Error(`Unsupported DBus address for GIO FFI spike: ${address || "<empty>"}`));
    }

    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);

    const resources = createRequestNameResources();
    return withFinally(
        () => runRequestNameSpikeWithLibraries(libraries.value, resources, address, timeoutMs),
        () => closeRequestNameResources(libraries.value, resources),
    );
};

interface RequestNameResources {
    connection: NullablePointer;
    requestParameters: NullablePointer;
    requestResult: NullablePointer;
    releaseParameters: NullablePointer;
    releaseResult: NullablePointer;
}

const createRequestNameResources = (): RequestNameResources => ({
    connection: null,
    requestParameters: null,
    requestResult: null,
    releaseParameters: null,
    releaseResult: null,
});

const closeRequestNameResources = (libraries: GioNativeLibraries, resources: RequestNameResources): void => {
    unrefVariantIfPresent(libraries, resources.releaseResult);
    unrefVariantIfPresent(libraries, resources.releaseParameters);
    unrefVariantIfPresent(libraries, resources.requestResult);
    unrefVariantIfPresent(libraries, resources.requestParameters);
    unrefObjectIfPresent(libraries, resources.connection);
    closeNativeLibraries(libraries);
};

const runRequestNameSpikeWithLibraries = (
    libraries: GioNativeLibraries,
    resources: RequestNameResources,
    address: string,
    timeoutMs: number,
): Result<GioFfiRequestNameSpikeResult> => {
    const name = createGioFfiSpikeBusName();
    const connection = openGioAddressConnection(libraries, address);
    if (isErr(connection)) return err(connection.error);
    resources.connection = connection.value;

    const requestReply = requestSpikeBusName(libraries, resources, connection.value, name, timeoutMs);
    if (isErr(requestReply)) return err(requestReply.error);

    const releaseReply = releaseSpikeBusName(libraries, resources, connection.value, name, timeoutMs);
    if (isErr(releaseReply)) return err(releaseReply.error);

    return ok({ name, requestReply: requestReply.value, releaseReply: releaseReply.value });
};

const requestSpikeBusName = (
    libraries: GioNativeLibraries,
    resources: RequestNameResources,
    connection: Pointer,
    name: string,
    timeoutMs: number,
): Result<number> => {
    const rawRequestParameters = createRequestNameParametersVariant(libraries.glib, name);
    if (isErr(rawRequestParameters)) return err(rawRequestParameters.error);
    const requestParameters = refSinkVariant(libraries.glib, rawRequestParameters.value, "g_variant_ref_sink returned null for RequestName parameters");
    if (isErr(requestParameters)) return err(requestParameters.error);
    resources.requestParameters = requestParameters.value;
    const requestResult = callDbusNameMethod(libraries, connection, DBUS_REQUEST_NAME_METHOD, requestParameters.value, timeoutMs, "RequestName");
    if (isErr(requestResult)) return err(requestResult.error);
    resources.requestResult = requestResult.value;
    return extractFirstUint32FromTuple(libraries.glib, resources.requestResult);
};

const releaseSpikeBusName = (
    libraries: GioNativeLibraries,
    resources: RequestNameResources,
    connection: Pointer,
    name: string,
    timeoutMs: number,
): Result<number> => {
    const rawReleaseParameters = createStringTupleVariant(libraries.glib, name);
    if (isErr(rawReleaseParameters)) return err(rawReleaseParameters.error);
    const releaseParameters = refSinkVariant(libraries.glib, rawReleaseParameters.value, "g_variant_ref_sink returned null for ReleaseName parameters");
    if (isErr(releaseParameters)) return err(releaseParameters.error);
    resources.releaseParameters = releaseParameters.value;
    const releaseResult = callDbusNameMethod(libraries, connection, DBUS_RELEASE_NAME_METHOD, releaseParameters.value, timeoutMs, "ReleaseName");
    if (isErr(releaseResult)) return err(releaseResult.error);
    resources.releaseResult = releaseResult.value;
    return extractFirstUint32FromTuple(libraries.glib, resources.releaseResult);
};

const callDbusNameMethod = (
    libraries: GioNativeLibraries,
    connection: Pointer,
    method: string,
    parameters: Pointer,
    timeoutMs: number,
    label: string,
): Result<Pointer> => {
    const callError = createGErrorSlot();
    const result = libraries.gio.symbols.g_dbus_connection_call_sync(
        connection,
        cString(DBUS_SERVICE_NAME).pointer,
        cString(DBUS_OBJECT_PATH).pointer,
        cString(DBUS_INTERFACE_NAME).pointer,
        cString(method).pointer,
        parameters,
        null,
        0,
        timeoutMs,
        null,
        callError.pointer,
    );
    if (!result) return err(new Error(`${label} returned null: ${readGErrorMessage(libraries.glib, callError)}`));
    return ok(result);
};

export const runCommitRoundTripSpikeWithGioFfi = async (
    address: string,
    timeoutMs = 1500,
): Promise<Result<GioFfiCommitRoundTripSpikeResult>> => {
    if (!isSupportedGioDbusAddress(address)) {
        return err(new Error(`Unsupported DBus address for GIO FFI spike: ${address || "<empty>"}`));
    }

    const libraries = loadNativeLibrariesResult();
    if (isErr(libraries)) return err(libraries.error);

    const resources = createSpikeObjectResources(libraries.value);
    return withFinallyAsync(
        () => runCommitRoundTripSpikeWithLibraries(libraries.value, resources, address, timeoutMs),
        () => closeSpikeObjectResources(libraries.value, resources),
    );
};

const runCommitRoundTripSpikeWithLibraries = async (
    libraries: GioNativeLibraries,
    resources: SpikeObjectResources,
    address: string,
    timeoutMs: number,
): Promise<Result<GioFfiCommitRoundTripSpikeResult>> => {
    const registration = registerSpikeObject(libraries, resources, address);
    if (isErr(registration)) return err(registration.error);

    const monitor = Bun.spawn(
        ["gdbus", "monitor", "--address", address, "--dest", registration.value.destination, "--object-path", SPIKE_OBJECT_PATH],
        { stdout: "pipe", stderr: "pipe" },
    );
    return withFinallyAsync(
        () => runCommitRoundTripMonitor(libraries, address, registration.value.destination, monitor, timeoutMs),
        () => {
            monitor.kill("SIGTERM");
        },
    );
};

const runCommitRoundTripMonitor = async (
    libraries: GioNativeLibraries,
    address: string,
    destination: string,
    monitor: ReturnType<typeof Bun.spawn>,
    timeoutMs: number,
): Promise<Result<GioFfiCommitRoundTripSpikeResult>> => {
    await Bun.sleep(150);
    const callOutput = await runDispatchedGdbusCommand(
        libraries,
        [...createSpikeGdbusCallCommand(address, destination, SPIKE_COMMIT_METHOD), "实时识别"],
        timeoutMs,
        "Timed out while dispatching Commit GDBus method callback",
    );
    await Bun.sleep(150);
    monitor.kill("SIGTERM");

    const signalOutput = await readProcessStreamText(monitor.stdout);
    const signalError = await readProcessStreamText(monitor.stderr);
    if (isErr(callOutput)) return err(callOutput.error);
    if (!signalOutput.includes(SPIKE_COMMIT_TEXT_SIGNAL)) {
        return err(new Error(`signal monitor did not observe ${SPIKE_COMMIT_TEXT_SIGNAL}: ${signalError || signalOutput}`));
    }
    return ok({ destination, callOutput: callOutput.value, signalOutput: signalOutput.trim() });
};

const readProcessStreamText = async (
    stream: ReadableStream<Uint8Array> | number | undefined,
): Promise<string> => {
    if (!stream || typeof stream === "number") return "";
    return new Response(stream).text();
};

export const createVariantReturnTuple = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    value: Pointer,
): Result<Pointer> => {
    const variant = createVariantWrapper(glib, value);
    if (isErr(variant)) return err(variant.error);
    return createTupleVariant(glib, [variant.value]);
};

export const createStringReturnTuple = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    value: string,
): Result<Pointer> => createStringTupleVariant(glib, value);

export const createObjectPathReturnTuple = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    value: string,
): Result<Pointer> => {
    const objectPath = createObjectPathVariant(glib, value);
    if (isErr(objectPath)) return err(objectPath.error);
    return createTupleVariant(glib, [objectPath.value]);
};

export const createBooleanReturnTuple = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    value: boolean,
): Result<Pointer> => {
    const bool = createBooleanVariant(glib, value);
    if (isErr(bool)) return err(bool.error);
    return createTupleVariant(glib, [bool.value]);
};

const returnGioMethodValue = (
    libraries: ReturnType<typeof loadNativeLibraries>,
    invocation: Pointer,
    result: Result<Pointer | null>,
): void => {
    if (isErr(result)) {
        libraries.gio.symbols.g_dbus_method_invocation_return_dbus_error(
            invocation,
            cString(DBUS_FAILED_ERROR_NAME).pointer,
            cString(result.error.message).pointer,
        );
        return;
    }

    libraries.gio.symbols.g_dbus_method_invocation_return_value(invocation, result.value);
};

export interface GioDbusObjectRegistration {
    id: number;
    callback: JSCallback;
    nodeInfo: Pointer;
    vtableBytes: BigUint64Array;
}

export const registerGioDbusObject = (
    libraries: ReturnType<typeof loadNativeLibraries>,
    connection: Pointer,
    objectPath: string,
    interfaceName: string,
    xml: string,
    handler: (method: string, parameters: Pointer) => Result<Pointer | null>,
): Result<GioDbusObjectRegistration> => {
    const xmlError = createGErrorSlot();
    const nodeInfo = libraries.gio.symbols.g_dbus_node_info_new_for_xml(cString(xml).pointer, xmlError.pointer);
    if (!nodeInfo) {
        return err(new Error(`g_dbus_node_info_new_for_xml returned null: ${readGErrorMessage(libraries.glib, xmlError)}`));
    }

    const interfaceInfo = libraries.gio.symbols.g_dbus_node_info_lookup_interface(nodeInfo, cString(interfaceName).pointer);
    if (!interfaceInfo) {
        libraries.gio.symbols.g_dbus_node_info_unref(nodeInfo);
        return err(new Error(`Interface not found in introspection XML: ${interfaceName}`));
    }

    const callback = new JSCallback(
        (
            _connection: Pointer,
            _sender: Pointer,
            _objectPath: Pointer,
            _interfaceName: Pointer,
            methodName: Pointer,
            parameters: Pointer,
            invocation: Pointer,
            _userData: Pointer,
        ): void => {
            const method = String(new CString(methodName));
            returnGioMethodValue(libraries, invocation, handler(method, parameters));
        },
        {
            args: ["ptr", "ptr", "ptr", "ptr", "ptr", "ptr", "ptr", "ptr"],
            returns: "void",
        },
    );
    const vtableBytes = new BigUint64Array([BigInt(callback.ptr as number), 0n, 0n]);
    const vtable = ptr(vtableBytes);

    const registerError = createGErrorSlot();
    const id = libraries.gio.symbols.g_dbus_connection_register_object(
        connection,
        cString(objectPath).pointer,
        interfaceInfo,
        vtable,
        null,
        null,
        registerError.pointer,
    );
    if (id === 0) {
        callback.close();
        libraries.gio.symbols.g_dbus_node_info_unref(nodeInfo);
        return err(new Error(`g_dbus_connection_register_object returned 0: ${readGErrorMessage(libraries.glib, registerError)}`));
    }

    return ok({ id, callback, nodeInfo, vtableBytes });
};

export const requestGioBusName = (
    libraries: ReturnType<typeof loadNativeLibraries>,
    connection: Pointer,
    name: string,
    timeoutMs: number,
    flags = DBUS_REQUEST_NAME_FLAGS_NONE,
): Result<number> => {
    const resources = { parameters: null as NullablePointer, result: null as NullablePointer };
    return withFinally(
        () => requestGioBusNameWithResources(libraries, connection, name, timeoutMs, flags, resources),
        () => {
            unrefVariantIfPresent(libraries, resources.result);
            unrefVariantIfPresent(libraries, resources.parameters);
        },
    );
};

const requestGioBusNameWithResources = (
    libraries: GioNativeLibraries,
    connection: Pointer,
    name: string,
    timeoutMs: number,
    flags: number,
    resources: { parameters: NullablePointer; result: NullablePointer },
): Result<number> => {
    const rawParameters = createRequestNameParametersVariant(libraries.glib, name, flags);
    if (isErr(rawParameters)) return err(rawParameters.error);
    const parameters = refSinkVariant(libraries.glib, rawParameters.value, "g_variant_ref_sink returned null for RequestName parameters");
    if (isErr(parameters)) return err(parameters.error);
    resources.parameters = parameters.value;

    const result = callDbusNameMethod(libraries, connection, DBUS_REQUEST_NAME_METHOD, parameters.value, timeoutMs, "RequestName");
    if (isErr(result)) return err(result.error);
    resources.result = result.value;

    return extractFirstUint32FromTuple(libraries.glib, result.value);
};

export interface GioDispatchLoop {
    done: Promise<void>;
}

export const startGioDispatchLoop = (
    glib: ReturnType<typeof loadNativeLibraries>["glib"],
    isStopped: () => boolean,
): GioDispatchLoop => {
    const done = (async (): Promise<void> => {
        while (!isStopped()) {
            glib.symbols.g_main_context_iteration(null, false);
            await Bun.sleep(5);
        }
    })();

    return { done };
};
