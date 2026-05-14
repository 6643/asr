import { expect, test } from "bun:test";
import { createControlLoop } from "./control.ts";

test("control loop ignores duplicate start while active and ignores stop when idle", async () => {
    const events: string[] = [];
    const activeDone = new Promise<void>(() => {});
    const controller = createControlLoop({
        releaseDelayMs: 20,
        startSession: async () => {
            events.push("startSession");
            return {
                stop: async () => {
                    events.push("stopSession");
                },
                done: activeDone,
            };
        },
    });

    await controller.signal("start");
    await controller.signal("start");
    await controller.signal("stop");
    await controller.signal("stop");

    expect(events).toEqual(["startSession"]);

    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(events).toEqual(["startSession", "stopSession"]);

    await controller.signal("stop");
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(events).toEqual(["startSession", "stopSession"]);
});

test("control loop shutdown stops active session", async () => {
    const events: string[] = [];
    const activeDone = new Promise<void>(() => {});
    const controller = createControlLoop({
        startSession: async () => {
            events.push("startSession");
            return {
                stop: async () => {
                    events.push("stopSession");
                },
                done: activeDone,
            };
        },
    });

    await controller.signal("start");
    await controller.signal("shutdown");

    expect(events).toEqual(["startSession", "stopSession"]);
});

test("control loop delays stop after release", async () => {
    const events: string[] = [];
    const activeDone = new Promise<void>(() => {});
    const controller = createControlLoop({
        releaseDelayMs: 20,
        startSession: async () => {
            events.push("startSession");
            return {
                stop: async () => {
                    events.push("stopSession");
                },
                done: activeDone,
            };
        },
    });

    await controller.signal("start");
    await controller.signal("stop");

    expect(events).toEqual(["startSession"]);

    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(events).toEqual(["startSession", "stopSession"]);
});

test("control loop invokes release callback immediately on stop", async () => {
    const events: string[] = [];
    const activeDone = new Promise<void>(() => {});
    const controller = createControlLoop({
        releaseDelayMs: 20,
        onRelease: async () => {
            events.push("release");
        },
        startSession: async () => {
            events.push("startSession");
            return {
                stop: async () => {
                    events.push("stopSession");
                },
                done: activeDone,
            };
        },
    });

    await controller.signal("start");
    await controller.signal("stop");

    expect(events).toEqual(["startSession", "release"]);
});

test("control loop releases active session immediately on stop before delayed shutdown", async () => {
    const events: string[] = [];
    const controller = createControlLoop({
        releaseDelayMs: 20,
        startSession: async () => {
            events.push("startSession");
            return {
                release: async () => {
                    events.push("releaseSession");
                },
                stop: async () => {
                    events.push("stopSession");
                },
                done: new Promise<void>(() => {}),
            };
        },
    });

    await controller.signal("start");
    await controller.signal("stop");

    expect(events).toEqual(["startSession", "releaseSession"]);

    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(events).toEqual(["startSession", "releaseSession", "stopSession"]);
});

test("control loop clears active session when startSession rejects", async () => {
    const events: string[] = [];
    const controller = createControlLoop({
        startSession: async () => {
            events.push("startSession");
            throw new Error("boom");
        },
    });

    await expect(controller.signal("start")).resolves.toBeUndefined();
    await controller.signal("start");

    expect(events).toEqual(["startSession", "startSession"]);
});

test("control loop clears active session when done resolves", async () => {
    const events: string[] = [];
    let resolveDone: (() => void) | undefined;
    const done = new Promise<void>((resolve) => {
        resolveDone = resolve;
    });
    const controller = createControlLoop({
        startSession: async () => {
            events.push("startSession");
            return {
                stop: async () => {
                    events.push("stopSession");
                    resolveDone?.();
                },
                done,
            };
        },
    });

    await controller.signal("start");
    resolveDone?.();
    await done;
    await controller.signal("start");

    expect(events).toEqual(["startSession", "startSession"]);
});

test("control loop clears active session when done is already resolved", async () => {
    const events: string[] = [];
    const controller = createControlLoop({
        startSession: async () => {
            events.push("startSession");
            return {
                stop: async () => {
                    events.push("stopSession");
                },
                done: Promise.resolve(),
            };
        },
    });

    await controller.signal("start");
    await new Promise((resolve) => setTimeout(resolve, 0));
    await controller.signal("start");

    expect(events).toEqual(["startSession", "startSession"]);
});

test("control loop stops a session that finishes starting after stop is requested", async () => {
    const events: string[] = [];
    let resolveStart: (() => void) | undefined;
    const startStarted = new Promise<void>((resolve) => {
        resolveStart = resolve;
    });
    const controller = createControlLoop({
        startSession: async () => {
            events.push("startSession");
            await startStarted;
            return {
                stop: async () => {
                    events.push("stopSession");
                },
                done: Promise.resolve(),
            };
        },
    });

    const startPromise = controller.signal("start");
    await controller.signal("stop");
    resolveStart?.();
    await startPromise;
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(events).toEqual(["startSession", "stopSession"]);
});
