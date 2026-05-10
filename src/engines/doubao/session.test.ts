import { expect, mock, test } from "bun:test";
import { err } from "../../util.ts";

test("doubao session does not retry the live stream on retryable startup errors", async () => {
    let calls = 0;

    mock.module("./client.ts", () => ({
        transcribeRealtime: mock(async function* () {
            calls++;
            yield err(new Error("ERR timeout"));
        }),
    }));

    const { createDoubaoSession } = await import("./session.ts");
    const [session, sessionError] = createDoubaoSession({} as never);

    expect(sessionError).toBeNull();

    const iterator = session.events[Symbol.asyncIterator]();
    const first = await iterator.next();

    expect(calls).toBe(1);
    expect(first.done).toBe(false);
    expect(first.value?.[1]?.message).toBe("ERR timeout");
});
