// Linux input_event 结构: timeval(16) + type(2) + code(2) + value(4) = 24 bytes
import { ignoreError, isErr, tryAsyncResult } from "../util.ts";
import { getKeyboardDevice } from "./config.ts";

const INPUT_EVENT_SIZE = 24;

// 键码常量
export const KEY_RIGHT_ALT = 100;
export const EV_KEY = 1;
const EV_SYN = 0;
const SYN_REPORT = 0;

export type KeyEvent = "press" | "release";

export const shouldTriggerSession = (pressedKeyCode: number, _pressedKeys: number[]): boolean => {
    return pressedKeyCode === KEY_RIGHT_ALT;
};

export interface KeyStreamState {
    pressedKeys: Set<number>;
    keyState: number | null;
    emittedState: number | null;
}

export const createKeyStreamState = (): KeyStreamState => ({
    pressedKeys: new Set<number>(),
    keyState: null,
    emittedState: null,
});

export const updateKeyStreamState = (
    state: KeyStreamState,
    eventType: number,
    eventCode: number,
    eventValue: number,
    keyCode: number,
): { state: KeyStreamState; event: KeyEvent | null } => {
    const targetKeyEvent = updateTargetKeyState(state, eventType, eventCode, eventValue, keyCode);
    if (targetKeyEvent !== null) return { state, event: targetKeyEvent };

    updatePressedKeys(state, eventType, eventCode, eventValue);

    if (eventType !== EV_SYN || eventCode !== SYN_REPORT) {
        return { state, event: null };
    }

    if (state.keyState === state.emittedState) {
        return { state, event: null };
    }

    state.emittedState = state.keyState;

    if (state.keyState === 1) {
        return { state, event: shouldTriggerSession(keyCode, [...state.pressedKeys]) ? "press" : null };
    }

    if (state.keyState === 0) {
        return { state, event: "release" };
    }

    return { state, event: null };
};

const updateTargetKeyState = (
    state: KeyStreamState,
    eventType: number,
    eventCode: number,
    eventValue: number,
    keyCode: number,
): KeyEvent | null => {
    if (eventType !== EV_KEY || eventCode !== keyCode) return null;
    state.keyState = eventValue;
    if (eventValue === 1) return emitKeyState(state, 1, "press");
    if (eventValue === 0) return emitKeyState(state, 0, "release");
    return null;
};

const emitKeyState = (state: KeyStreamState, emittedState: number, event: KeyEvent): KeyEvent => {
    state.emittedState = emittedState;
    return event;
};

const updatePressedKeys = (state: KeyStreamState, eventType: number, eventCode: number, eventValue: number): void => {
    if (eventType !== EV_KEY) return;
    if (eventValue === 1) state.pressedKeys.add(eventCode);
    if (eventValue === 0) state.pressedKeys.delete(eventCode);
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
        ignoreError(() => {
            void reader.cancel().catch(() => {}); // reader may already be closed
        });
    };

    if (signal) {
        signal.addEventListener("abort", abort, { once: true });
    }

    const streamState = createKeyStreamState();

    try {
        yield* readKeyEvents(reader, buffer, offset, streamState, keyCode);
    } finally {
        releaseKeyReader(reader);
        signal?.removeEventListener("abort", abort);
    }
};

const readKeyEvents = async function* (
    reader: ReadableStreamDefaultReader<Uint8Array>,
    buffer: Uint8Array,
    offset: number,
    streamState: KeyStreamState,
    keyCode: number,
): AsyncGenerator<KeyEvent> {
    const chunk = await reader.read();
    if (chunk.done) return;
    const parsed = parseKeyChunk(chunk.value, buffer, offset, streamState, keyCode);
    yield* parsed.events;
    yield* readKeyEvents(reader, buffer, parsed.offset, streamState, keyCode);
};

const parseKeyChunk = (
    value: Uint8Array,
    buffer: Uint8Array,
    offset: number,
    streamState: KeyStreamState,
    keyCode: number,
): { offset: number; events: KeyEvent[] } => {
    return Array.from(value).reduce(
        (state, byte) => appendKeyByte(state, byte, buffer, streamState, keyCode),
        { offset, events: [] as KeyEvent[] },
    );
};

const appendKeyByte = (
    state: { offset: number; events: KeyEvent[] },
    byte: number,
    buffer: Uint8Array,
    streamState: KeyStreamState,
    keyCode: number,
): { offset: number; events: KeyEvent[] } => {
    buffer[state.offset] = byte;
    const offset = state.offset + 1;
    if (offset !== INPUT_EVENT_SIZE) return { ...state, offset };
    const event = parseKeyInputEvent(buffer, streamState, keyCode);
    return { offset: 0, events: event === null ? state.events : [...state.events, event] };
};

const parseKeyInputEvent = (buffer: Uint8Array, streamState: KeyStreamState, keyCode: number): KeyEvent | null => {
    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    const type = view.getUint16(16, true);
    const code = view.getUint16(18, true);
    const value = view.getUint32(20, true);
    return updateKeyStreamState(streamState, type, code, value, keyCode).event;
};

const releaseKeyReader = (reader: ReadableStreamDefaultReader<Uint8Array>): void => {
    ignoreError(() => {
        reader.releaseLock();
    });
};

// 自动查找键盘设备, 支持环境变量覆盖
export const findKeyboardDevice = async (): Promise<string | null> => {
    const envDevice = getKeyboardDevice();
    if (envDevice) return envDevice;

    const devices = await tryAsyncResult(() => Bun.file("/proc/bus/input/devices").text());
    if (isErr(devices)) return null;
    return findKeyboardDeviceInBlocks(devices.value.split("\n\n"));
};

const findKeyboardDeviceInBlocks = (blocks: string[]): string | null => {
    const block = blocks.find(isKeyboardDeviceBlock);
    if (!block) return null;
    return getInputEventPath(block);
};

const isKeyboardDeviceBlock = (block: string): boolean => {
    const name = block.match(/N: Name="(.+)"/)?.[1]?.toLowerCase();
    if (!name) return false;
    return name.includes("keyboard") || name.includes("atkbd") || name.includes("kbd");
};

const getInputEventPath = (block: string): string | null => {
    const eventMatch = block.match(/event(\d+)/);
    if (!eventMatch) return null;
    return `/dev/input/event${eventMatch[1]}`;
};
