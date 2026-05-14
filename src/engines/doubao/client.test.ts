import { expect, test } from "bun:test";

import { createWebSocketStreams, formatSenderSummary } from "./client.ts";

test("websocket stream cleanup removes listeners on close", () => {
    const events = new Map<string, Set<(...args: unknown[]) => void>>();
    const ws = {
        addEventListener(type: string, handler: (...args: unknown[]) => void) {
            if (!events.has(type)) events.set(type, new Set());
            events.get(type)!.add(handler);
        },
        removeEventListener(type: string, handler: (...args: unknown[]) => void) {
            events.get(type)?.delete(handler);
        },
        close() {},
        send() {},
    } as unknown as WebSocket;

    createWebSocketStreams(ws);
    expect(events.get("message")?.size).toBe(1);
    expect(events.get("error")?.size).toBe(1);
    expect(events.get("close")?.size).toBe(1);

    const closeHandler = events.get("close")?.values().next().value;
    expect(closeHandler).toBeDefined();
    closeHandler?.({});

    expect(events.get("message")?.size ?? 0).toBe(0);
    expect(events.get("error")?.size ?? 0).toBe(0);
    expect(events.get("close")?.size ?? 0).toBe(0);
});

test("sender summary reports audio frames and bytes", () => {
    expect(formatSenderSummary(2, 6400)).toBe("sender frames=2 bytes=6400");
});
