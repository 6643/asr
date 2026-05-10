export type ControlSignal = "start" | "stop" | "shutdown";

export interface ActiveSessionHandle {
    stop: () => Promise<void>;
    done: Promise<void>;
}

export const createControlLoop = (deps: {
    startSession: () => Promise<ActiveSessionHandle>;
    releaseDelayMs?: number;
}) => {
    let active: ActiveSessionHandle | null = null;
    let starting = false;
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
        releaseTimer = setTimeout(() => {
            releaseTimer = null;
            void signal("shutdown");
        }, releaseDelayMs);
    };

    const signal = async (event: ControlSignal): Promise<void> => {
        if (event === "shutdown") {
            clearReleaseTimer();
            if (active !== null) {
                await active.stop();
                active = null;
            }
            return;
        }

        if (event === "start") {
            clearReleaseTimer();
            if (active !== null || starting) return;
            starting = true;
            try {
                const started = await deps.startSession();
                active = started;
                void started.done.finally(() => {
                    if (active === started) {
                        active = null;
                        clearReleaseTimer();
                    }
                });
            } finally {
                starting = false;
            }
            return;
        }

        if (active !== null) {
            scheduleRelease();
        }
    };

    return { signal };
};
