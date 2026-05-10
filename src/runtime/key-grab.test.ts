import { expect, test } from "bun:test";

import { KEY_RIGHT_ALT, shouldTriggerSession } from "./key.ts";

test("insert trigger is still single-key only", () => {
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT])).toBe(true);
    expect(shouldTriggerSession(KEY_RIGHT_ALT, [KEY_RIGHT_ALT, 30])).toBe(false);
});
