import { expect, mock, test } from "bun:test";
import { err, isErr, ok, type Result } from "../../util.ts";

test("doubao session starts the live stream before events are consumed", async () => {
    let calls = 0;

    const { createDoubaoSession } = await import("./session.ts");
    const sessionResult = createDoubaoSession({} as never, {
        transcribeRealtime: async function* () {
            calls++;
            yield err(new Error("ERR timeout"));
        },
    });

    expect(isErr(sessionResult)).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(calls).toBe(1);
});

test("doubao session rejects audio after the bounded queue is full", async () => {
    const { createDoubaoSession } = await import("./session.ts");
    const sessionResult = createDoubaoSession({} as never, {
        transcribeRealtime: async function* () {
            await new Promise(() => {});
        },
    });

    expect(isErr(sessionResult)).toBe(false);
    if (isErr(sessionResult)) return;
    const session = sessionResult.value;

    const chunk = new Uint8Array([1]);
    let pushResult: Result<void> = err(new Error("not called"));
    for (let i = 0; i < 512; i++) {
        pushResult = await session.pushAudio(chunk);
        expect(isErr(pushResult)).toBe(false);
    }

    pushResult = await session.pushAudio(chunk);
    expect(isErr(pushResult)).toBe(true);
    if (isErr(pushResult)) expect(pushResult.error.message).toBe("Audio queue is full or closed");
    await session.close();
});
