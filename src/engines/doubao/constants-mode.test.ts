import { expect, test } from "bun:test";

import { isProductionMode, shouldRequireSamiAppKey } from "./constants-mode.ts";

test("production mode is detected from NODE_ENV", () => {
    const prev = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    expect(isProductionMode()).toBe(true);
    expect(shouldRequireSamiAppKey()).toBe(true);
    if (prev === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = prev;
});

test("non production mode does not require sami app key", () => {
    const prev = process.env.NODE_ENV;
    process.env.NODE_ENV = "development";
    expect(isProductionMode()).toBe(false);
    expect(shouldRequireSamiAppKey()).toBe(false);
    if (prev === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = prev;
});
