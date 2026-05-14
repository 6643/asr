import { err, isErr, isOk, ok, type Result, runCommand } from "../util.ts";
import {
    isInputSourceSelected,
    normalizeGsettingsInputSources,
    selectGsettingsInputSourceState,
} from "./gsettings-input-source.ts";
import { callIbusServiceStringMethodInWorker } from "./ibus-rpc-worker-client.ts";
import { IBUS_ENGINE_NAME } from "./ibus-meta.ts";
import { getIbusRpcTimeout } from "./config.ts";

export { startIbusService } from "./ibus-service.ts";

export {
    getIbusSocketPath,
    isIbusAddressReady,
    parseIbusAddressCandidates,
    pickIbusAddressCandidate,
    readCurrentIbusAddress,
    resolveIbusAddress,
} from "./ibus-address.ts";

export {
    ensureIbusComponentInstalled,
    ensureIbusDaemonRunning,
    initIbusRuntime,
    isIbusDaemonRunning,
    refreshIbusCache,
    resolveIbusComponentPath,
} from "./ibus-install.ts";

export {
    getIbusComponentXml,
    getIbusEnginesXml,
    IBUS_BUS_NAME,
    IBUS_COMPONENT_NAME,
    IBUS_COMPONENT_XML,
    IBUS_ENGINE_IFACE,
    IBUS_ENGINE_NAME,
    IBUS_ENGINE_PATH_PREFIX,
    IBUS_FACTORY_IFACE,
    IBUS_FACTORY_PATH,
    IBUS_SERVICE_IFACE,
    IBUS_SERVICE_PATH,
    IBUS_XML,
} from "./ibus-meta.ts";

type IBusRuntimeStatus = string;

const IBUS_SERVICE_RPC_TIMEOUT_MS = getIbusRpcTimeout();

const waitForReady = async (
    isReady: () => Promise<boolean> | boolean,
    attempts: number,
    delayMs: number,
): Promise<boolean> => {
    return waitForReadyAttempt(isReady, attempts, delayMs, 0);
};

const waitForReadyAttempt = async (
    isReady: () => Promise<boolean> | boolean,
    attempts: number,
    delayMs: number,
    attempt: number,
): Promise<boolean> => {
    if (attempt >= attempts) return false;
    if (await isReady()) return true;
    await Bun.sleep(delayMs);
    return waitForReadyAttempt(isReady, attempts, delayMs, attempt + 1);
};

export const readIbusServiceStatus = async (): Promise<Result<IBusRuntimeStatus>> => {
    return callIbusServiceStringMethodInWorker("GetStatus", [], IBUS_SERVICE_RPC_TIMEOUT_MS);
};

export const invokeIbusCommitText = async (text: string): Promise<Result<string>> => {
    return callIbusServiceStringMethodInWorker("CommitText", [text], IBUS_SERVICE_RPC_TIMEOUT_MS);
};

export const isIbusRuntimeStatusReady = (status: IBusRuntimeStatus): boolean => {
    return status === "ready";
};

export const isIbusServiceStatusAvailable = (statusResult: Result<IBusRuntimeStatus>): boolean => {
    return isOk(statusResult) || (isErr(statusResult) && statusResult.error.message.includes("engine_not"));
};

export const isIbusEngineReady = async (): Promise<boolean> => {
    const statusResult = await readIbusServiceStatus();
    return !isErr(statusResult) && isIbusRuntimeStatusReady(statusResult.value);
};

export const isIbusServiceReady = async (): Promise<boolean> => {
    return isIbusServiceStatusAvailable(await readIbusServiceStatus());
};

const readGsettingsInputSourceState = (): Result<{ sources: string; current: string }> => {
    const sourcesResult = runCommand("gsettings", ["get", "org.gnome.desktop.input-sources", "sources"], {
        timeoutMs: 1000,
    });
    if (isErr(sourcesResult)) {
        return err(new Error(`Failed to read input sources: ${sourcesResult.error.message}`));
    }

    const currentResult = runCommand("gsettings", ["get", "org.gnome.desktop.input-sources", "current"], {
        timeoutMs: 1000,
    });
    if (isErr(currentResult)) {
        return err(new Error(`Failed to read current input source: ${currentResult.error.message}`));
    }

    return ok({
        sources: sourcesResult.value.stdout.trim(),
        current: currentResult.value.stdout.trim(),
    });
};

const writeGsettingsInputSourceState = (state: { sources: string; current: string }): Result<void> => {
    const sourcesResult = runCommand("gsettings", ["set", "org.gnome.desktop.input-sources", "sources", state.sources], {
        timeoutMs: 1000,
    });
    if (isErr(sourcesResult)) {
        return err(new Error(`Failed to update input sources: ${sourcesResult.error.message}`));
    }

    const currentResult = runCommand(
        "gsettings",
        ["set", "org.gnome.desktop.input-sources", "current", state.current.replace(/^uint32\s+/, "")],
        { timeoutMs: 1000 },
    );
    if (isErr(currentResult)) {
        return err(new Error(`Failed to update current input source: ${currentResult.error.message}`));
    }

    return ok(undefined);
};

const isAsrInputSourceSelected = (state: { sources: string; current: string }): boolean => {
    return isInputSourceSelected(normalizeGsettingsInputSources(state.sources), state.current, IBUS_ENGINE_NAME);
};

const selectAsrInputSource = (): Result<void> => {
    const rawState = readGsettingsInputSourceState();
    if (isErr(rawState)) return err(rawState.error);

    const selectedState = selectGsettingsInputSourceState(rawState.value.sources, rawState.value.current, IBUS_ENGINE_NAME);
    if (rawState.value.sources === selectedState.sources && rawState.value.current === selectedState.current) {
        return ok(undefined);
    }

    const writeResult = writeGsettingsInputSourceState(selectedState);
    if (isErr(writeResult)) return err(writeResult.error);

    const confirmState = readGsettingsInputSourceState();
    if (isErr(confirmState)) return err(confirmState.error);
    if (isAsrInputSourceSelected(confirmState.value)) return ok(undefined);

    return err(new Error("Failed to select ASR input source"));
};

export const ensureIbusServiceRunning = async (): Promise<Result<void>> => {
    return (await isIbusServiceReady()) ? ok(undefined) : err(new Error("IBus service is not ready"));
};

export const ensureIbusEngineSelected = async (): Promise<Result<void>> => {
    const initialState = readGsettingsInputSourceState();
    if (isErr(initialState)) {
        return err(new Error(`IBus engine is not available: ${initialState.error.message}`));
    }

    if (isAsrInputSourceSelected(initialState.value)) {
        return ok(undefined);
    }

    const selectResult = selectAsrInputSource();
    if (isErr(selectResult)) {
        return err(new Error(`IBus engine is not available: ${selectResult.error.message}`));
    }

    if (await waitForReady(() => {
        const state = readGsettingsInputSourceState();
        return !isErr(state) && isAsrInputSourceSelected(state.value);
    }, 20, 250)) {
        return ok(undefined);
    }

    return err(new Error(`IBus engine did not become ready after selecting ${IBUS_ENGINE_NAME}`));
};

export const waitForIbusRuntimeReady = async (): Promise<Result<void>> => {
    if (await waitForReady(() => isIbusEngineReady(), 20, 250)) {
        return ok(undefined);
    }

    return err(new Error("IBus runtime did not become ready"));
};
