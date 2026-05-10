import { expect, test } from "bun:test";

import { buildWebSocketInit } from "./client.ts";

test("websocket init carries doubao handshake headers", () => {
    const headers = {
        "User-Agent": "ua",
        "proto-version": "v2",
        "x-custom-keepalive": "true",
    };

    expect(buildWebSocketInit(headers)).toEqual({ headers });
});
