// Linux 键盘事件监听（通过 /dev/input）

// Linux input_event 结构: timeval(16) + type(2) + code(2) + value(4) = 24 bytes
const INPUT_EVENT_SIZE = 24;

// 键码常量
export const KEY_RIGHT_ALT = 100;
export const EV_KEY = 1;
const EV_SYN = 0;
const SYN_REPORT = 0;

export type KeyEvent = "press" | "release";

export const shouldTriggerSession = (pressedKeyCode: number, pressedKeys: number[]): boolean => {
    return pressedKeyCode === KEY_RIGHT_ALT && pressedKeys.length === 1 && pressedKeys[0] === KEY_RIGHT_ALT;
};

// 从指定输入设备读取键盘事件
export const createKeyStream = async function* (
    devicePath: string,
    keyCode: number,
    signal?: AbortSignal,
): AsyncGenerator<KeyEvent> {
    const file = Bun.file(devicePath);
    const stream = file.stream();
    const reader = stream.getReader();
    const buffer = new Uint8Array(INPUT_EVENT_SIZE);
    let offset = 0;

    const abort = () => {
        try {
            void reader.cancel().catch(() => {});
        } catch {
            // ignore
        }
    };

    if (signal) {
        signal.addEventListener("abort", abort, { once: true });
    }

    // 状态追踪：只检测 SYN_REPORT 后的最终状态
    let keyState: number | null = null;
    let emittedState: number | null = null;
    const pressedKeys = new Set<number>();

    try {
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;

            for (const byte of value) {
                buffer[offset] = byte;
                offset++;

                if (offset === INPUT_EVENT_SIZE) {
                    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
                    const type = view.getUint16(16, true);
                    const code = view.getUint16(18, true);
                    const value = view.getUint32(20, true);

                    if (type === EV_KEY) {
                        if (value === 1) {
                            pressedKeys.add(code);
                        } else if (value === 0) {
                            pressedKeys.delete(code);
                        }
                    }

                    if (type === EV_KEY && code === keyCode) {
                        keyState = value;
                    }

                    if (type === EV_SYN && code === SYN_REPORT) {
                        if (keyState === emittedState) {
                            offset = 0;
                            continue;
                        }

                        emittedState = keyState;

                        if (keyState === 1) {
                            if (shouldTriggerSession(keyCode, [...pressedKeys])) {
                                yield "press";
                            }
                        } else if (keyState === 0) {
                            yield "release";
                        }
                    }

                    offset = 0;
                }
            }
        }
    } finally {
        try {
            reader.releaseLock();
        } catch {
            // ignore
        }
        if (signal) {
            signal.removeEventListener("abort", abort);
        }
    }
};

// 列出所有输入设备
export const listInputDevices = async (): Promise<void> => {
    try {
        const devices = await Bun.file("/proc/bus/input/devices").text();
        const blocks = devices.split("\n\n");
        for (const block of blocks) {
            const name = block.match(/N: Name="(.+)"/)?.[1];
            const handlers = block.match(/H: Handlers=(.+)/)?.[1];
            if (name && handlers) {
                console.log(`  ${handlers} -> ${name}`);
            }
        }
    } catch (e) {
        console.error("无法读取设备列表:", e);
    }
};

// 自动查找键盘设备, 支持环境变量覆盖
export const findKeyboardDevice = async (): Promise<string | null> => {
    const envDevice = process.env.ASR_KEYBOARD_DEVICE?.trim();
    if (envDevice) return envDevice;

    try {
        const devices = await Bun.file("/proc/bus/input/devices").text();
        const blocks = devices.split("\n\n");
        for (const block of blocks) {
            const name = block.match(/N: Name="(.+)"/)?.[1]?.toLowerCase();
            if (name && (name.includes("keyboard") || name.includes("atkbd") || name.includes("kbd"))) {
                const eventMatch = block.match(/event(\d+)/);
                if (eventMatch) {
                    return `/dev/input/event${eventMatch[1]}`;
                }
            }
        }
    } catch {
        // ignore
    }
    return null;
};
