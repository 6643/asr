import { expect, test } from "bun:test";

import { getMicFrameBytes } from "./mic.ts";

test("mic frame bytes follow sample rate and channel options", () => {
    expect(getMicFrameBytes(16000, 1)).toBe(3200);
    expect(getMicFrameBytes(48000, 2)).toBe(19200);
});
