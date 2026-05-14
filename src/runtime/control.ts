import { isErr, tryAsyncResult, withFinallyAsync } from "../util.ts";

export type ControlSignal = "start" | "stop" | "shutdown";

export interface ActiveSessionHandle {
    release?: () => Promise<void> | void;
    stop: () => Promise<void>;
    done: Promise<void>;
}

export interface ControlState {
    active: ActiveSessionHandle | null;
    starting: boolean;
    stopRequestedWhileStarting: boolean;
}

export const createControlState = (): ControlState => ({
    active: null,
    starting: false,
    stopRequestedWhileStarting: false,
});

export const clearActiveSession = (state: ControlState): ControlState => ({
    ...state,
    active: null,
});

export const scheduleStopAfterRelease = (
    state: ControlState,
    releaseDelayMs: number,
    signal: (event: ControlSignal) => Promise<void>,
): { state: ControlState; timer: ReturnType<typeof setTimeout> } => {
    const timer = setTimeout(() => {
        void signal("shutdown");
    }, releaseDelayMs);
    return { state, timer };
};

export const createControlLoop = (deps: {
    startSession: () => Promise<ActiveSessionHandle>;
    releaseDelayMs?: number;
    onRelease?: () => void | Promise<void>;
}) => {
    let state: ControlState = createControlState();
    let releaseTimer: ReturnType<typeof setTimeout> | null = null;
    const releaseDelayMs = deps.releaseDelayMs ?? 300;

    const clearReleaseTimer = (): void => {
        if (releaseTimer !== null) {
            clearTimeout(releaseTimer);
            releaseTimer = null;
        }
    };

    const scheduleRelease = (): void => {
        clearReleaseTimer();
        releaseTimer = scheduleStopAfterRelease(state, releaseDelayMs, signal).timer;
    };

    const releaseActiveSession = async (): Promise<void> => {
        if (state.active === null) return;
        await state.active.release?.();
    };

    const stopActiveSession = async (): Promise<void> => {
        if (state.active === null) return;
        await state.active.stop();
        state = clearActiveSession(state);
    };

    const invokeReleaseCallback = async (): Promise<void> => {
        await deps.onRelease?.();
    };

    const clearStartedSession = (started: ActiveSessionHandle): void => {
        if (state.active !== started) return;
        state = clearActiveSession(state);
        clearReleaseTimer();
    };

    const attachSessionDoneCleanup = (started: ActiveSessionHandle): void => {
        const clearActive = (): void => clearStartedSession(started);
        void started.done.then(clearActive, clearActive);
    };

    const stopStartedSessionIfRequested = async (started: ActiveSessionHandle): Promise<void> => {
        if (!state.stopRequestedWhileStarting) return;
        await started.stop();
        state = clearActiveSession(state);
    };

    const finishStartAttempt = async (run: () => Promise<void>): Promise<void> => {
        await withFinallyAsync(async () => {
            const result = await tryAsyncResult(run);
            if (isErr(result)) state = clearActiveSession(state);
        }, () => {
            state = { ...state, starting: false };
        });
    };

    const startSession = async (): Promise<void> => {
        clearReleaseTimer();
        if (state.active !== null || state.starting) return;
        state = { ...state, starting: true, stopRequestedWhileStarting: false };
        await finishStartAttempt(async () => {
            const started = await deps.startSession();
            state = { ...state, active: started };
            attachSessionDoneCleanup(started);
            await stopStartedSessionIfRequested(started);
        });
    };

    const stopSession = async (): Promise<void> => {
        if (state.active !== null) return stopActiveAfterRelease();
        if (state.starting) return markStopRequestedWhileStarting();
    };

    const stopActiveAfterRelease = async (): Promise<void> => {
        await releaseActiveSession();
        await invokeReleaseCallback();
        scheduleRelease();
    };

    const markStopRequestedWhileStarting = async (): Promise<void> => {
        await invokeReleaseCallback();
        state = { ...state, stopRequestedWhileStarting: true };
    };

    const shutdown = async (): Promise<void> => {
        clearReleaseTimer();
        await stopActiveSession();
    };

    const signal = async (event: ControlSignal): Promise<void> => {
        if (event === "shutdown") return shutdown();
        if (event === "start") return startSession();
        await stopSession();
    };

    return { signal };
};
