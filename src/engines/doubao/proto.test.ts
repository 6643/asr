import { expect, test } from "bun:test";

import { buildAsrRequest, parseResponse } from "./proto.ts";
import { isErr } from "../../util.ts";

test("parseResponse reports invalid json content", () => {
    const bytes = new Uint8Array([0x22, 0x05, 0x4f, 0x74, 0x68, 0x65, 0x72, 0x3a, 0x01, 0x7b]);
    const result = parseResponse(bytes);
    expect(isErr(result)).toBe(true);
    if (isErr(result)) {
        expect(result.error.message).toContain("Failed to parse result_json");
    }
});

test("encodeVarint rejects negative frame state values", () => {
    expect(() => buildAsrRequest(new Uint8Array([1]), "req", -1 as never, 0)).toThrow("encodeVarint expects a non-negative integer");
});
