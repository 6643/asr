export const encodeVarint = (value: number): Uint8Array => {
    if (!Number.isInteger(value) || value < 0) {
        throw new Error(`encodeVarint expects a non-negative integer, got ${value}`);
    }
    const bytes: number[] = [];
    while (value > 0x7f) {
        bytes.push((value & 0x7f) | 0x80);
        value >>>= 7;
    }
    bytes.push(value);
    return new Uint8Array(bytes);
};

export const concatBytes = (arrays: Uint8Array[]): Uint8Array => {
    const totalLength = arrays.reduce((sum, arr) => sum + arr.length, 0);
    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (const arr of arrays) {
        result.set(arr, offset);
        offset += arr.length;
    }
    return result;
};

export const encodeVarintField = (fieldNumber: number, value: number): Uint8Array => {
    const tag = encodeVarint((fieldNumber << 3) | 0);
    const val = encodeVarint(value);
    return concatBytes([tag, val]);
};

export const encodeStringField = (fieldNumber: number, value: string): Uint8Array => {
    const tag = encodeVarint((fieldNumber << 3) | 2);
    const strBytes = new TextEncoder().encode(value);
    const len = encodeVarint(strBytes.length);
    return concatBytes([tag, len, strBytes]);
};

export const encodeBytesField = (fieldNumber: number, value: Uint8Array): Uint8Array => {
    const tag = encodeVarint((fieldNumber << 3) | 2);
    const len = encodeVarint(value.length);
    return concatBytes([tag, len, value]);
};

export const decodeVarint = (data: Uint8Array, offset: number): { value: number; bytesRead: number } => {
    return decodeVarintStep(data, offset, { value: 0, bytesRead: 0, shift: 0 });
};

const decodeVarintStep = (
    data: Uint8Array,
    offset: number,
    state: { value: number; bytesRead: number; shift: number },
): { value: number; bytesRead: number } => {
    if (offset + state.bytesRead >= data.length) return toDecodedVarint(state);
    const byte = data[offset + state.bytesRead];
    if (byte === undefined) return toDecodedVarint(state);
    const next = {
        value: state.value | ((byte & 0x7f) << state.shift),
        bytesRead: state.bytesRead + 1,
        shift: state.shift + 7,
    };
    if (!(byte & 0x80) || next.shift >= 32) return toDecodedVarint(next);
    return decodeVarintStep(data, offset, next);
};

const toDecodedVarint = (state: { value: number; bytesRead: number }): { value: number; bytesRead: number } => ({
    value: state.value,
    bytesRead: state.bytesRead,
});

export const decodeString = (data: Uint8Array, offset: number): { value: string; bytesRead: number } => {
    const { value: len, bytesRead: lenBytes } = decodeVarint(data, offset);
    offset += lenBytes;
    const strBytes = data.slice(offset, offset + len);
    return { value: new TextDecoder().decode(strBytes), bytesRead: lenBytes + (len || 0) };
};

export const skipField = (data: Uint8Array, offset: number, wireType: number): number => {
    switch (wireType) {
        case 0: {
            const { bytesRead } = decodeVarint(data, offset);
            return bytesRead;
        }
        case 2: {
            const { value: len } = decodeVarint(data, offset);
            const { bytesRead: lenBytes } = decodeVarint(data, offset);
            return lenBytes + len;
        }
        case 1:
            return 8;
        case 5:
            return 4;
        default:
            return 0;
    }
};
