import { expect, test, beforeEach, afterEach } from "bun:test";

const originalEnv = { ...process.env };

beforeEach(() => {
    delete process.env.ASR_AUTO_SWITCH;
    delete process.env.ASR_IBUS_RPC_TIMEOUT;
    delete process.env.ASR_DEBUG;
});

afterEach(() => {
    process.env = { ...originalEnv };
});

test("isAutoSwitchEnabled returns true by default", async () => {
    const { isAutoSwitchEnabled } = await import("./config.ts");
    expect(isAutoSwitchEnabled()).toBe(true);
});

test("isAutoSwitchEnabled returns false when ASR_AUTO_SWITCH is 'false'", async () => {
    process.env.ASR_AUTO_SWITCH = "false";
    const { isAutoSwitchEnabled } = await import("./config.ts");
    expect(isAutoSwitchEnabled()).toBe(false);
});

test("isAutoSwitchEnabled returns false when ASR_AUTO_SWITCH is '0'", async () => {
    process.env.ASR_AUTO_SWITCH = "0";
    const { isAutoSwitchEnabled } = await import("./config.ts");
    expect(isAutoSwitchEnabled()).toBe(false);
});

test("isAutoSwitchEnabled returns true when ASR_AUTO_SWITCH is 'true'", async () => {
    process.env.ASR_AUTO_SWITCH = "true";
    const { isAutoSwitchEnabled } = await import("./config.ts");
    expect(isAutoSwitchEnabled()).toBe(true);
});

test("isAutoSwitchEnabled returns true when ASR_AUTO_SWITCH is '1'", async () => {
    process.env.ASR_AUTO_SWITCH = "1";
    const { isAutoSwitchEnabled } = await import("./config.ts");
    expect(isAutoSwitchEnabled()).toBe(true);
});

test("getIbusRpcTimeout returns 1500 by default", async () => {
    const { getIbusRpcTimeout } = await import("./config.ts");
    expect(getIbusRpcTimeout()).toBe(1500);
});

test("getIbusRpcTimeout returns parsed value when ASR_IBUS_RPC_TIMEOUT is valid", async () => {
    process.env.ASR_IBUS_RPC_TIMEOUT = "3000";
    const { getIbusRpcTimeout } = await import("./config.ts");
    expect(getIbusRpcTimeout()).toBe(3000);
});

test("getIbusRpcTimeout returns default when ASR_IBUS_RPC_TIMEOUT is invalid", async () => {
    process.env.ASR_IBUS_RPC_TIMEOUT = "invalid";
    const { getIbusRpcTimeout } = await import("./config.ts");
    expect(getIbusRpcTimeout()).toBe(1500);
});

test("getIbusRpcTimeout returns default when ASR_IBUS_RPC_TIMEOUT is negative", async () => {
    process.env.ASR_IBUS_RPC_TIMEOUT = "-100";
    const { getIbusRpcTimeout } = await import("./config.ts");
    expect(getIbusRpcTimeout()).toBe(1500);
});

test("getIbusRpcTimeout returns default when ASR_IBUS_RPC_TIMEOUT is zero", async () => {
    process.env.ASR_IBUS_RPC_TIMEOUT = "0";
    const { getIbusRpcTimeout } = await import("./config.ts");
    expect(getIbusRpcTimeout()).toBe(1500);
});

test("isDebugEnabled returns false by default", async () => {
    const { isDebugEnabled } = await import("./config.ts");
    expect(isDebugEnabled()).toBe(false);
});

test("isDebugEnabled returns true when ASR_DEBUG is '1'", async () => {
    process.env.ASR_DEBUG = "1";
    const { isDebugEnabled } = await import("./config.ts");
    expect(isDebugEnabled()).toBe(true);
});

test("isDebugEnabled returns true when ASR_DEBUG is 'true'", async () => {
    process.env.ASR_DEBUG = "true";
    const { isDebugEnabled } = await import("./config.ts");
    expect(isDebugEnabled()).toBe(true);
});

test("isDebugEnabled returns false when ASR_DEBUG is 'false'", async () => {
    process.env.ASR_DEBUG = "false";
    const { isDebugEnabled } = await import("./config.ts");
    expect(isDebugEnabled()).toBe(false);
});

test("isDebugEnabled returns false when ASR_DEBUG is '0'", async () => {
    process.env.ASR_DEBUG = "0";
    const { isDebugEnabled } = await import("./config.ts");
    expect(isDebugEnabled()).toBe(false);
});
