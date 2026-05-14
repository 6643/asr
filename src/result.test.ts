import { expect, test } from "bun:test";

import { err, isErr, isOk, ok, tryAsyncResult, trySyncResult, type Err, type Ok, type Result } from "./result.ts";

declare const looseThenable: { then: (resolve: (value: string) => void) => void };

if (false) {
    const typeCheckOk: Ok<string> = ok("value");
    const typeCheckErr: Err = err("boom");
    const typeCheckSync: Result<string> = trySyncResult(() => "value");
    const typeCheckLooseThenable: Promise<Result<string>> = tryAsyncResult(() => looseThenable);

    void typeCheckOk;
    void typeCheckErr;
    void typeCheckSync;
    void typeCheckLooseThenable;
    // @ts-expect-error tryAsyncResult requires a thenable return value.
    tryAsyncResult(() => "value");
}

test("result accepts non-error success values", () => {
    const result: Result<string> = ok("value");

    expect(result).toEqual({ ok: true, value: "value" });
    expect(isOk(result)).toBe(true);
    expect(isErr(result)).toBe(false);
});

test("result accepts Error as a success value", () => {
    const value = new Error("success error value");
    const result: Result<Error> = ok(value);

    expect(isOk(result)).toBe(true);
    if (!isOk(result)) return;
    expect(result.value).toBe(value);
});

test("result wraps thrown errors", () => {
    const result = trySyncResult(() => {
        throw new Error("boom");
    });

    expect(isErr(result)).toBe(true);
    if (!isErr(result)) return;
    expect(result.error.message).toBe("boom");
});

test("err normalizes non-error failures", () => {
    const result = err("boom");

    expect(result.ok).toBe(false);
    expect(result.error).toBeInstanceOf(Error);
    expect(result.error.message).toBe("boom");
});

test("tryAsyncResult wraps async rejections", async () => {
    const result = await tryAsyncResult(async () => {
        throw "boom";
    });

    expect(isErr(result)).toBe(true);
    if (!isErr(result)) return;
    expect(result.error.message).toBe("boom");
});

test("tryAsyncResult accepts function thenables", async () => {
    const thenable = Object.assign(() => {}, {
        then: (resolve: (value: string) => void) => resolve("value"),
    });

    const result = await tryAsyncResult(() => thenable as unknown as Promise<string>);

    expect(result).toEqual({ ok: true, value: "value" });
});

test("tryAsyncResult assimilates thenables that return undefined from then", async () => {
    const thenable = {
        then: (resolve: (value: string) => void) => {
            resolve("value");
        },
    };

    const result = await tryAsyncResult(() => thenable);

    expect(result).toEqual({ ok: true, value: "value" });
});
