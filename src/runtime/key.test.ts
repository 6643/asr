import { expect, test } from "bun:test";

import { KEY_RIGHT_ALT, shouldTriggerSession } from "./key.ts";

test("right alt only triggers when it is the sole pressed key", () => {
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT])).toBe(true);
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT, 30])).toBe(false);
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [30])).toBe(false);
});
