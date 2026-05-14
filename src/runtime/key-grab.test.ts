import { expect, test } from "bun:test";

import { KEY_RIGHT_ALT, shouldTriggerSession } from "./key.ts";

test("right alt trigger is not gated by other pressed keys", () => {
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT])).toBe(true);
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT, 30])).toBe(true);
});
