import { expect, test } from "bun:test";

import { resolveSamiAppKey } from "./sami-app-key.ts";
import { isErr } from "../../util.ts";

test("production mode requires sami app key", () => {
    const result = resolveSamiAppKey("", true);
    expect(isErr(result)).toBe(true);
    if (isErr(result)) expect(result.error.message).toBe("ASR_SAMI_APP_KEY is required in production");
});

test("non production mode falls back to default sami app key", () => {
    expect(resolveSamiAppKey("", false)).toEqual({ ok: true, value: "SYlxZr6LnvBaIVmF" });
    expect(resolveSamiAppKey("custom", false)).toEqual({ ok: true, value: "custom" });
});
