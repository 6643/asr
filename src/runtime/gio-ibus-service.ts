import type { Pointer } from "bun:ffi";

import { err, isErr, ok, type Result, withFinally } from "../util.ts";
import {
    DBUS_REQUEST_NAME_FLAG_DO_NOT_QUEUE,
    closeNativeLibraries,
    createBooleanReturnTuple,
    createEmptyArrayVariant,
    createGErrorSlot,
    createGioMessageBusConnectionFlags,
    createIbusTextSignalParametersVariant,
    createObjectPathReturnTuple,
    createStringReturnTuple,
    createStringVariant,
    createTupleVariant,
    createUint32Variant,
    createVariantReturnTuple,
    cString,
    extractFirstStringFromTuple,
    isGioBusNameReplyOwned,
    loadNativeLibraries,
    readGErrorMessage,
    registerGioDbusObject,
    requestGioBusName,
    startGioDispatchLoop,
    type GioDispatchLoop,
    type GioDbusObjectRegistration,
    type GioNativeLibraries,
    type NullablePointer,
} from "./gio-dbus-native.ts";
import { resolveIbusAddress } from "./ibus-address.ts";
import {
    IBUS_BUS_NAME,
    IBUS_ENGINE_IFACE,
    IBUS_ENGINE_NAME,
    IBUS_ENGINE_PATH_PREFIX,
    IBUS_FACTORY_IFACE,
    IBUS_FACTORY_PATH,
    IBUS_SERVICE_IFACE,
    IBUS_SERVICE_PATH,
} from "./ibus-meta.ts";
import { printTimedDomain, printTimedDomainError } from "./output.ts";

interface GioIbusEngine {
    objectPath: string;
    state: {
        hasFocus: boolean;
        enabled: boolean;
    };
}

interface GioIbusServiceState {
    activeEngine: GioIbusEngine | null;
    engineId: number;
}

interface GioIbusServiceContext {
    libraries: GioNativeLibraries;
    connection: Pointer;
    registrations: GioDbusObjectRegistration[];
    state: GioIbusServiceState;
}

interface GioIbusResources {
    libraries: GioNativeLibraries;
    connection: NullablePointer;
    registrations: GioDbusObjectRegistration[];
}

const createGioIbusState = (): GioIbusServiceState => ({
    activeEngine: null,
    engineId: 0,
});

const createIbusEngineDescriptionValue = (glib: GioNativeLibraries["glib"]): Result<Pointer> => {
    const values: Array<Result<Pointer>> = [
        createStringVariant(glib, "IBusEngineDesc"),
        createEmptyArrayVariant(glib, "{sv}"),
        createStringVariant(glib, IBUS_ENGINE_NAME),
        createStringVariant(glib, "ASR"),
        createStringVariant(glib, "Commit ASR text through IBus"),
        createStringVariant(glib, "zh"),
        createStringVariant(glib, "MIT"),
        createStringVariant(glib, "_"),
        createStringVariant(glib, ""),
        createStringVariant(glib, "us"),
        createUint32Variant(glib, 0),
        createStringVariant(glib, ""),
        createStringVariant(glib, ""),
        createStringVariant(glib, ""),
        createStringVariant(glib, ""),
        createStringVariant(glib, ""),
        createStringVariant(glib, ""),
        createStringVariant(glib, ""),
        createStringVariant(glib, "ASR"),
    ];

    const children = collectVariantPointers(values);
    if (isErr(children)) return err(children.error);
    return createTupleVariant(glib, children.value);
};

const collectVariantPointers = (values: Array<Result<Pointer>>): Result<Pointer[]> => {
    return values.reduce(appendVariantPointer, ok<Pointer[]>([]));
};

const appendVariantPointer = (state: Result<Pointer[]>, value: Result<Pointer>): Result<Pointer[]> => {
    if (isErr(state)) return state;
    if (isErr(value)) return err(value.error);
    return ok([...state.value, value.value]);
};

const getGioIbusStatus = (state: GioIbusServiceState): string => {
    const engine = state.activeEngine;
    if (!engine) return "engine_not_created";
    return "ready";
};

const createGioIbusEngineXml = (): string => {
    return [
        "<node>",
        `  <interface name="${IBUS_ENGINE_IFACE}">`,
        '    <method name="FocusIn"/>',
        '    <method name="FocusOut"/>',
        '    <method name="Destroy"/>',
        '    <method name="Enable"/>',
        '    <method name="Disable"/>',
        '    <method name="ProcessKeyEvent"><arg type="u" name="keyval" direction="in"/><arg type="u" name="keycode" direction="in"/><arg type="u" name="state" direction="in"/><arg type="b" name="handled" direction="out"/></method>',
        '    <method name="SetCursorLocation"><arg type="i" name="x" direction="in"/><arg type="i" name="y" direction="in"/><arg type="i" name="w" direction="in"/><arg type="i" name="h" direction="in"/></method>',
        '    <method name="SetCursorLocationRelative"><arg type="i" name="x" direction="in"/><arg type="i" name="y" direction="in"/><arg type="i" name="w" direction="in"/><arg type="i" name="h" direction="in"/></method>',
        '    <method name="ProcessHandWritingEvent"><arg type="ad" name="coordinates" direction="in"/></method>',
        '    <method name="CancelHandWriting"><arg type="u" name="n_strokes" direction="in"/></method>',
        '    <method name="Reset"/>',
        '    <method name="SetCapabilities"><arg type="u" name="caps" direction="in"/></method>',
        '    <method name="PropertyActivate"><arg type="s" name="name" direction="in"/><arg type="u" name="state" direction="in"/></method>',
        '    <method name="SetEngine"><arg type="s" name="name" direction="in"/></method>',
        '    <method name="GetEngine"><arg type="v" name="engine" direction="out"/></method>',
        '    <method name="SetSurroundingText"><arg type="v" name="text" direction="in"/><arg type="u" name="cursor_pos" direction="in"/><arg type="u" name="anchor_pos" direction="in"/></method>',
        '    <signal name="CommitText"><arg type="v" name="text"/></signal>',
        "  </interface>",
        "</node>",
    ].join("\n");
};

const createGioIbusFactoryXml = (): string => {
    return [
        "<node>",
        `  <interface name="${IBUS_FACTORY_IFACE}">`,
        '    <method name="CreateEngine"><arg type="s" name="name" direction="in"/><arg type="o" name="engine" direction="out"/></method>',
        "  </interface>",
        "</node>",
    ].join("\n");
};

const createGioIbusServiceXml = (): string => {
    return [
        "<node>",
        `  <interface name="${IBUS_SERVICE_IFACE}">`,
        '    <method name="CommitText"><arg type="s" name="text" direction="in"/><arg type="s" name="reply" direction="out"/></method>',
        '    <method name="GetStatus"><arg type="s" name="status" direction="out"/></method>',
        "  </interface>",
        "</node>",
    ].join("\n");
};

const emitGioIbusCommitText = (
    libraries: GioNativeLibraries,
    connection: Pointer,
    objectPath: string,
    text: string,
): Result<void> => {
    const rawParameters = createIbusTextSignalParametersVariant(libraries.glib, text);
    if (isErr(rawParameters)) return err(rawParameters.error);

    const parameters = libraries.glib.symbols.g_variant_ref_sink(rawParameters.value);
    if (!parameters) return err(new Error("g_variant_ref_sink returned null for CommitText signal"));

    return withFinally(
        () => emitGioIbusCommitTextWithParameters(libraries, connection, objectPath, parameters),
        () => libraries.glib.symbols.g_variant_unref(parameters),
    );
};

const emitGioIbusCommitTextWithParameters = (
    libraries: GioNativeLibraries,
    connection: Pointer,
    objectPath: string,
    parameters: Pointer,
): Result<void> => {
    const signalError = createGErrorSlot();
    const sent = libraries.gio.symbols.g_dbus_connection_emit_signal(
        connection,
        null,
        cString(objectPath).pointer,
        cString(IBUS_ENGINE_IFACE).pointer,
        cString("CommitText").pointer,
        parameters,
        signalError.pointer,
    );
    if (!sent) return err(new Error(`CommitText signal failed: ${readGErrorMessage(libraries.glib, signalError)}`));

    const flushError = createGErrorSlot();
    const flushed = libraries.gio.symbols.g_dbus_connection_flush_sync(connection, null, flushError.pointer);
    if (!flushed) return err(new Error(`CommitText flush failed: ${readGErrorMessage(libraries.glib, flushError)}`));

    printTimedDomain("ibus", `CommitText emitted path=${objectPath}`);
    return ok(undefined);
};

const commitThroughGioIbus = (
    libraries: GioNativeLibraries,
    connection: Pointer,
    state: GioIbusServiceState,
    text: string,
): string => {
    if (!text.trim()) return "ERR empty_response";

    const engine = state.activeEngine;
    if (!engine) return "ERR engine_not_created";

    printTimedDomain(
        "ibus",
        `commit start path=${engine.objectPath} enabled=${engine.state.enabled} focused=${engine.state.hasFocus}`,
    );
    if (!engine.state.enabled && !engine.state.hasFocus) return "ERR engine_not_active";
    const committed = emitGioIbusCommitText(libraries, connection, engine.objectPath, text);
    if (isErr(committed)) {
        printTimedDomainError("ibus", committed.error.message);
        return "ERR service_unavailable";
    }

    return "OK committed";
};


const createEngineMethodHandler = (
    libraries: GioNativeLibraries,
    engine: GioIbusEngine,
) => {
    return (method: string): Result<Pointer | null> => {
        if (method === "FocusIn") {
            engine.state.hasFocus = true;
            printTimedDomain("ibus", "FocusIn");
            return ok(null);
        }
        if (method === "FocusOut") {
            engine.state.hasFocus = false;
            printTimedDomain("ibus", "FocusOut");
            return ok(null);
        }
        if (method === "Destroy") {
            engine.state.hasFocus = false;
            engine.state.enabled = false;
            printTimedDomain("ibus", "Destroy");
            return ok(null);
        }
        if (method === "Enable") {
            engine.state.enabled = true;
            printTimedDomain("ibus", "Enable");
            return ok(null);
        }
        if (method === "Disable") {
            engine.state.enabled = false;
            printTimedDomain("ibus", "Disable");
            return ok(null);
        }
        if (method === "ProcessKeyEvent") return createBooleanReturnTuple(libraries.glib, false);
        if (method !== "GetEngine") return ok(null);

        const desc = createIbusEngineDescriptionValue(libraries.glib);
        if (isErr(desc)) return err(desc.error);
        return createVariantReturnTuple(libraries.glib, desc.value);
    };
};

const registerIbusObject = (
    context: GioIbusServiceContext,
    objectPath: string,
    interfaceName: string,
    xml: string,
    handler: (method: string, parameters: Pointer) => Result<Pointer | null>,
): Result<void> => {
    const result = registerGioDbusObject(
        context.libraries,
        context.connection,
        objectPath,
        interfaceName,
        xml,
        withIbusMethodErrorLogging(handler),
    );
    if (isErr(result)) return err(result.error);

    context.registrations.push(result.value);
    return ok(undefined);
};

const logIbusMethodError = (method: string, error: Error): void => {
    printTimedDomainError("ibus", `method=${method} err ${error.message}`);
};

const withIbusMethodErrorLogging = (
    handler: (method: string, parameters: Pointer) => Result<Pointer | null>,
) => {
    return (method: string, parameters: Pointer): Result<Pointer | null> => {
        const result = handler(method, parameters);
        if (isErr(result)) logIbusMethodError(method, result.error);
        return result;
    };
};

const createFactoryMethodHandler = (context: GioIbusServiceContext) => {
    return (method: string, parameters: Pointer): Result<Pointer | null> => {
        if (method !== "CreateEngine") return createObjectPathReturnTuple(context.libraries.glib, "/");

        const engineName = extractFirstStringFromTuple(context.libraries.glib, parameters);
        if (isErr(engineName)) return err(engineName.error);
        if (engineName.value !== IBUS_ENGINE_NAME) {
            printTimedDomainError("ibus", `unsupported engine: ${engineName.value}`);
            return createObjectPathReturnTuple(context.libraries.glib, "/");
        }

        const path = `${IBUS_ENGINE_PATH_PREFIX}/${context.state.engineId++}`;
        printTimedDomain("ibus", `CreateEngine name=${engineName.value} path=${path}`);

        const engine: GioIbusEngine = { objectPath: path, state: { hasFocus: false, enabled: false } };
        const registered = registerIbusObject(
            context,
            path,
            IBUS_ENGINE_IFACE,
            createGioIbusEngineXml(),
            createEngineMethodHandler(context.libraries, engine),
        );
        if (isErr(registered)) return err(registered.error);

        context.state.activeEngine = engine;
        return createObjectPathReturnTuple(context.libraries.glib, path);
    };
};

const createServiceMethodHandler = (context: GioIbusServiceContext) => {
    return (method: string, parameters: Pointer): Result<Pointer | null> => {
        if (method === "GetStatus") {
            return createStringReturnTuple(context.libraries.glib, getGioIbusStatus(context.state));
        }
        if (method !== "CommitText") {
            return createStringReturnTuple(context.libraries.glib, "ERR unsupported_method");
        }

        const text = extractFirstStringFromTuple(context.libraries.glib, parameters);
        if (isErr(text)) return createStringReturnTuple(context.libraries.glib, "ERR invalid_text");

        return createStringReturnTuple(
            context.libraries.glib,
            commitThroughGioIbus(context.libraries, context.connection, context.state, text.value),
        );
    };
};

const closeGioIbusResources = (resources: GioIbusResources): void => {
    for (const registration of resources.registrations.toReversed()) {
        closeGioIbusRegistration(resources, registration);
    }

    if (resources.connection) resources.libraries.gobject.symbols.g_object_unref(resources.connection);
    closeNativeLibraries(resources.libraries);
};

const closeGioIbusRegistration = (resources: GioIbusResources, registration: GioDbusObjectRegistration): void => {
    if (resources.connection) {
        resources.libraries.gio.symbols.g_dbus_connection_unregister_object(resources.connection, registration.id);
    }
    registration.callback.close();
    resources.libraries.gio.symbols.g_dbus_node_info_unref(registration.nodeInfo);
};

const createGioIbusConnection = (resources: GioIbusResources, address: string): Result<Pointer> => {
    const connectionError = createGErrorSlot();
    const connection = resources.libraries.gio.symbols.g_dbus_connection_new_for_address_sync(
        cString(address).pointer,
        createGioMessageBusConnectionFlags(),
        null,
        null,
        connectionError.pointer,
    );
    if (!connection) {
        return err(new Error(`GIO DBus connection failed: ${readGErrorMessage(resources.libraries.glib, connectionError)}`));
    }

    resources.connection = connection;
    return ok(connection);
};

const logRequestNameReply = (reply: number): void => {
    if (reply === 1) {
        printTimedDomain("ibus", "requestName acquired primary ownership");
        return;
    }
    if (reply === 2) {
        printTimedDomain("ibus", "requestName returned IN_QUEUE (2)");
        return;
    }

    printTimedDomain("ibus", `requestName returned ${reply}`);
};

const assertIbusBusNameOwned = (reply: number): void => {
    if (isGioBusNameReplyOwned(reply)) return;
    throw new Error(`IBus bus name not owned: RequestName reply=${reply}`);
};

export const startGioIbusService = async (): Promise<() => Promise<void>> => {
    const ibusAddressResult = await resolveIbusAddress();
    if (isErr(ibusAddressResult)) {
        printTimedDomainError("ibus", ibusAddressResult.error.message);
        throw new Error(`IBus address resolution failed: ${ibusAddressResult.error.message}`);
    }

    const resources: GioIbusResources = {
        libraries: loadNativeLibraries(),
        connection: null,
        registrations: [],
    };
    let stopped = false;
    let dispatchLoop: GioDispatchLoop | null = null;

    try {
        const stop = await startGioIbusServiceResources(resources, ibusAddressResult.value, () => stopped);
        dispatchLoop = stop.dispatchLoop;
        return async () => {
            if (stopped) return;
            stopped = true;
            await waitGioDispatchLoop(dispatchLoop);
            closeGioIbusResources(resources);
        };
    } catch (error) {
        stopped = true;
        await waitGioDispatchLoop(dispatchLoop);
        closeGioIbusResources(resources);
        throw error;
    }
};

const startGioIbusServiceResources = async (
    resources: GioIbusResources,
    address: string,
    isStopped: () => boolean,
): Promise<{ dispatchLoop: GioDispatchLoop }> => {
    const connection = createGioIbusConnection(resources, address);
    if (isErr(connection)) throw connection.error;

    const context: GioIbusServiceContext = {
        libraries: resources.libraries,
        connection: connection.value,
        registrations: resources.registrations,
        state: createGioIbusState(),
    };

    registerRequiredIbusObjects(context);
    const requestNameReply = requestGioBusName(resources.libraries, connection.value, IBUS_BUS_NAME, 1500, DBUS_REQUEST_NAME_FLAG_DO_NOT_QUEUE);
    if (isErr(requestNameReply)) throw requestNameReply.error;

    assertIbusBusNameOwned(requestNameReply.value);
    logRequestNameReply(requestNameReply.value);
    printTimedDomain("ibus", `engine ready. name=${IBUS_ENGINE_NAME} address=${address}`);
    return { dispatchLoop: startGioDispatchLoop(resources.libraries.glib, isStopped) };
};

const registerRequiredIbusObjects = (context: GioIbusServiceContext): void => {
    const factory = registerIbusObject(
        context,
        IBUS_FACTORY_PATH,
        IBUS_FACTORY_IFACE,
        createGioIbusFactoryXml(),
        createFactoryMethodHandler(context),
    );
    if (isErr(factory)) throw factory.error;

    const service = registerIbusObject(
        context,
        IBUS_SERVICE_PATH,
        IBUS_SERVICE_IFACE,
        createGioIbusServiceXml(),
        createServiceMethodHandler(context),
    );
    if (isErr(service)) throw service.error;
};

const waitGioDispatchLoop = async (dispatchLoop: GioDispatchLoop | null): Promise<void> => {
    if (!dispatchLoop) return;
    await dispatchLoop.done;
};
