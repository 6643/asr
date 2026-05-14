import { expect, test } from "bun:test";
import fs from "fs";

import { readWavPcm } from "./audio.ts";
import { ignoreError, isErr } from "../../util.ts";

test("readWavPcm rejects short wav files", async () => {
    const path = "/tmp/asr-short.wav";
    try {
        await Bun.write(path, new Uint8Array([1, 2, 3]));

        const result = await readWavPcm(path);
        expectShortWavError(result);
    } finally {
        ignoreError(() => fs.unlinkSync(path));
    }
});

const expectShortWavError = (result: Awaited<ReturnType<typeof readWavPcm>>): void => {
    expect(isErr(result)).toBe(true);
    if (!isErr(result)) return;
    expect(result.error.message).toContain("too short");
};
