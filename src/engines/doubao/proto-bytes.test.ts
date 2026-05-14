import { expect, test } from "bun:test";

import { concatBytes, decodeString, decodeVarint, encodeStringField, encodeVarint, skipField } from "./proto-bytes.ts";

test("encodeVarint rejects negative frame state values", () => {
    expect(() => encodeVarint(-1)).toThrow();
});

test("concatBytes joins arrays in order", () => {
    expect(Array.from(concatBytes([new Uint8Array([1, 2]), new Uint8Array([3])]))).toEqual([1, 2, 3]);
});

test("decodeVarint reads single byte values", () => {
    expect(decodeVarint(new Uint8Array([0x2a]), 0)).toEqual({ value: 42, bytesRead: 1 });
});

test("decodeString reads length prefixed bytes", () => {
    const encoded = encodeStringField(1, "hi");
    const payload = encoded.slice(1);
    expect(decodeString(payload, 0)).toEqual({ value: "hi", bytesRead: 3 });
});

test("skipField skips varint and length-delimited fields", () => {
    expect(skipField(new Uint8Array([0x01]), 0, 0)).toBe(1);
    expect(skipField(new Uint8Array([0x02, 0x01, 0x00]), 0, 2)).toBe(3);
});
