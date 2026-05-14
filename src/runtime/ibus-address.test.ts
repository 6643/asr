import { expect, test } from "bun:test";

import { pickIbusAddressCandidate } from "./ibus-address.ts";

test("ibus address selection falls back to env address when direct address is empty", () => {
    expect(pickIbusAddressCandidate("", "unix:path=/tmp/asr-dbus.sock")).toBe("unix:path=/tmp/asr-dbus.sock");
});

test("ibus address selection prefers direct address when ready", () => {
    expect(pickIbusAddressCandidate("unix:path=/tmp/direct.sock", "unix:path=/tmp/env.sock")).toBe(
        "unix:path=/tmp/direct.sock",
    );
});
