import { expect, test } from "bun:test";

import { isIbusCacheRefreshNeeded, isIbusRestartFailureFatal } from "./ibus-install.ts";

test("ibus cache refresh is skipped when component xml is unchanged", () => {
    expect(isIbusCacheRefreshNeeded({ path: "/tmp/asr.xml", changed: false })).toBe(false);
});

test("ibus cache refresh is required when component xml changed", () => {
    expect(isIbusCacheRefreshNeeded({ path: "/tmp/asr.xml", changed: true })).toBe(true);
});

test("ibus restart timeout is non-fatal because readiness is checked later", () => {
    expect(isIbusRestartFailureFatal("ibus restart timed out after 3000ms")).toBe(false);
    expect(isIbusRestartFailureFatal("ibus restart exited with null")).toBe(false);
    expect(isIbusRestartFailureFatal("ibus restart exited with 1")).toBe(true);
});
