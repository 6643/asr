import { expect, test } from "bun:test";

import { createKeyStreamState, EV_KEY, KEY_RIGHT_ALT, updateKeyStreamState, shouldTriggerSession } from "./key.ts";

test("right alt triggers session regardless of other pressed keys", () => {
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT])).toBe(true);
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT, 30])).toBe(true);
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT, 29])).toBe(true);
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [30])).toBe(true);
});

test("right alt press is emitted immediately on key down", () => {
    const state = createKeyStreamState();
    const next = updateKeyStreamState(state, EV_KEY, KEY_RIGHT_ALT, 1, KEY_RIGHT_ALT);
    expect(next.event).toBe("press");
});

test("right alt release is emitted immediately on key up", () => {
    const state = createKeyStreamState();
    const next = updateKeyStreamState(state, EV_KEY, KEY_RIGHT_ALT, 0, KEY_RIGHT_ALT);
    expect(next.event).toBe("release");
});
