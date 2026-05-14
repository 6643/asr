import { expect, test, beforeEach, afterEach } from "bun:test";

const originalEnv = { ...process.env };

beforeEach(() => {
    delete process.env.ASR_AUTO_SWITCH;
    delete process.env.ASR_IBUS_RPC_TIMEOUT;
    delete process.env.ASR_DEBUG;
    delete process.env.ASR_KEYBOARD_DEVICE;
    delete process.env.ASR_IBUS_COMPONENT_PATH;
    delete process.env.ASR_SAMI_APP_KEY;
    delete process.env.ASR_HKDF_INFO;
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

test("getIbusRpcTimeout returns 1500 when ASR_IBUS_RPC_TIMEOUT is invalid", async () => {
    process.env.ASR_IBUS_RPC_TIMEOUT = "invalid";
    const { getIbusRpcTimeout } = await import("./config.ts");
    expect(getIbusRpcTimeout()).toBe(1500);
});

test("getIbusRpcTimeout returns 1500 when ASR_IBUS_RPC_TIMEOUT is negative", async () => {
    process.env.ASR_IBUS_RPC_TIMEOUT = "-100";
    const { getIbusRpcTimeout } = await import("./config.ts");
    expect(getIbusRpcTimeout()).toBe(1500);
});

test("getIbusRpcTimeout returns 1500 when ASR_IBUS_RPC_TIMEOUT is zero", async () => {
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

test("isDebugEnabled returns false when ASR_DEBUG is '0'", async () => {
    process.env.ASR_DEBUG = "0";
    const { isDebugEnabled } = await import("./config.ts");
    expect(isDebugEnabled()).toBe(false);
});

test("isDebugEnabled returns false when ASR_DEBUG is 'false'", async () => {
    process.env.ASR_DEBUG = "false";
    const { isDebugEnabled } = await import("./config.ts");
    expect(isDebugEnabled()).toBe(false);
});

test("getKeyboardDevice returns undefined by default", async () => {
    const { getKeyboardDevice } = await import("./config.ts");
    expect(getKeyboardDevice()).toBeUndefined();
});

test("getKeyboardDevice returns trimmed value when ASR_KEYBOARD_DEVICE is set", async () => {
    process.env.ASR_KEYBOARD_DEVICE = "  /dev/input/event3  ";
    const { getKeyboardDevice } = await import("./config.ts");
    expect(getKeyboardDevice()).toBe("/dev/input/event3");
});

test("getIbusComponentPath returns undefined by default", async () => {
    const { getIbusComponentPath } = await import("./config.ts");
    expect(getIbusComponentPath()).toBeUndefined();
});

test("getIbusComponentPath returns trimmed value when ASR_IBUS_COMPONENT_PATH is set", async () => {
    process.env.ASR_IBUS_COMPONENT_PATH = "  /custom/path/asr.xml  ";
    const { getIbusComponentPath } = await import("./config.ts");
    expect(getIbusComponentPath()).toBe("/custom/path/asr.xml");
});

test("getSamiAppKey returns undefined by default", async () => {
    const { getSamiAppKey } = await import("./config.ts");
    expect(getSamiAppKey()).toBeUndefined();
});

test("getSamiAppKey returns trimmed value when ASR_SAMI_APP_KEY is set", async () => {
    process.env.ASR_SAMI_APP_KEY = "  test-key-123  ";
    const { getSamiAppKey } = await import("./config.ts");
    expect(getSamiAppKey()).toBe("test-key-123");
});

test("getHkdfInfo returns undefined by default", async () => {
    const { getHkdfInfo } = await import("./config.ts");
    expect(getHkdfInfo()).toBeUndefined();
});

test("getHkdfInfo returns trimmed value when ASR_HKDF_INFO is set", async () => {
    process.env.ASR_HKDF_INFO = "  4e30514609050cd3  ";
    const { getHkdfInfo } = await import("./config.ts");
    expect(getHkdfInfo()).toBe("4e30514609050cd3");
});
