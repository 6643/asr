// ASR Protobuf 消息编解码
// 手动实现 AsrRequest 和 AsrResponse 的序列化/反序列化

import {
    FrameState,
    ResponseType,
    type ASRAlternative,
    type ASRExtra,
    type ASRResponse,
    type ASRResult,
    type ASRWord,
    type OIDecodingInfo,
    type SessionConfig,
} from "./types.ts";
import { ok, err, isErr, trySyncResult, type Result } from "../../util.ts";
import { parseResponseJson } from "./proto-parse.ts";
import {
    concatBytes,
    decodeString,
    decodeVarint,
    encodeBytesField,
    encodeStringField,
    encodeVarint,
    encodeVarintField,
    skipField,
} from "./proto-bytes.ts";

// Protobuf 字段号常量
const REQ_FIELDS = {
    TOKEN: 2,
    SERVICE_NAME: 3,
    METHOD_NAME: 5,
    PAYLOAD: 6,
    AUDIO_DATA: 7,
    REQUEST_ID: 8,
    FRAME_STATE: 9,
} as const;

const RES_FIELDS = {
    REQUEST_ID: 1,
    TASK_ID: 2,
    SERVICE_NAME: 3,
    MESSAGE_TYPE: 4,
    STATUS_CODE: 5,
    STATUS_MESSAGE: 6,
    RESULT_JSON: 7,
    UNKNOWN_FIELD_9: 9,
} as const;

export const buildStartTask = (requestId: string, token: string): Uint8Array => {
    return encodeAsrRequest({
        token,
        service_name: "ASR",
        method_name: "StartTask",
        request_id: requestId,
    });
};

export const buildStartSession = (requestId: string, token: string, sessionConfig: SessionConfig): Uint8Array => {
    return encodeAsrRequest({
        token,
        service_name: "ASR",
        method_name: "StartSession",
        request_id: requestId,
        payload: JSON.stringify(sessionConfig),
    });
};

export const buildFinishTask = (requestId: string, token: string): Uint8Array => {
    return encodeAsrRequest({
        token,
        service_name: "ASR",
        method_name: "FinishTask",
        request_id: requestId,
    });
};

export const buildFinishSession = (requestId: string, token: string): Uint8Array => {
    return encodeAsrRequest({
        token,
        service_name: "ASR",
        method_name: "FinishSession",
        request_id: requestId,
    });
};

export const buildAsrRequest = (
    audioData: Uint8Array,
    requestId: string,
    frameState: FrameState,
    timestampMs: number,
): Uint8Array => {
    const metadata = JSON.stringify({ extra: {}, timestamp_ms: timestampMs });

    return encodeAsrRequest({
        service_name: "ASR",
        method_name: "TaskRequest",
        payload: metadata,
        audio_data: audioData,
        request_id: requestId,
        frame_state: frameState,
    });
};

// =============
// AsrRequest 编解码
// =============

export const encodeAsrRequest = (data: {
    token?: string;
    service_name?: string;
    method_name?: string;
    payload?: string;
    audio_data?: Uint8Array;
    request_id?: string;
    frame_state?: FrameState;
}): Uint8Array => {
    const parts: Uint8Array[] = [];

    if (data.token !== undefined) {
        parts.push(encodeStringField(REQ_FIELDS.TOKEN, data.token));
    }
    if (data.service_name !== undefined) {
        parts.push(encodeStringField(REQ_FIELDS.SERVICE_NAME, data.service_name));
    }
    if (data.method_name !== undefined) {
        parts.push(encodeStringField(REQ_FIELDS.METHOD_NAME, data.method_name));
    }
    if (data.payload !== undefined) {
        parts.push(encodeStringField(REQ_FIELDS.PAYLOAD, data.payload));
    }
    if (data.audio_data !== undefined) {
        parts.push(encodeBytesField(REQ_FIELDS.AUDIO_DATA, data.audio_data));
    }
    if (data.request_id !== undefined) {
        parts.push(encodeStringField(REQ_FIELDS.REQUEST_ID, data.request_id));
    }
    if (data.frame_state !== undefined) {
        parts.push(encodeVarintField(REQ_FIELDS.FRAME_STATE, data.frame_state));
    }

    return concatBytes(parts);
};

// =============
// AsrResponse 解码
// =============

export const parseResponse = (data: Uint8Array): Result<ASRResponse> => {
    const parsed = decodeAsrResponseRaw(data);

    const messageType = parsed.message_type as string;
    const resultJson: unknown = parsed.result_json;

    if (typeof resultJson !== "string") {
        return err(new Error("result_json is not a string"));
    }

    const statusMessage = parsed.status_message as string;

    // 根据 message_type 判断响应类型
    if (messageType === "TaskStarted") {
        return ok({ type: ResponseType.TASK_STARTED });
    }

    if (messageType === "SessionStarted") {
        return ok({ type: ResponseType.SESSION_STARTED });
    }

    if (messageType === "SessionFinished") {
        return ok({ type: ResponseType.SESSION_FINISHED });
    }

    if (messageType === "TaskFailed" || messageType === "SessionFailed") {
        return ok({
            type: ResponseType.ERROR,
            error_msg: statusMessage,
        });
    }

    // 识别结果在 result_json 字段
    if (!resultJson) {
        return ok({ type: ResponseType.UNKNOWN });
    }

    const jsonData = trySyncResult(() => JSON.parse(resultJson) as Record<string, unknown>);
    if (isErr(jsonData)) {
        return err(new Error(`Failed to parse result_json: ${jsonData.error.message}; content=${resultJson.slice(0, 200)}`));
    }

    return ok(parseResponseJson(jsonData.value));
};

// =============
// 底层编解码函数
// =============

const decodeAsrResponseRaw = (data: Uint8Array): Record<string, unknown> => {
    const result: Record<string, unknown> = {
        request_id: "",
        task_id: "",
        service_name: "",
        message_type: "",
        status_code: 0,
        status_message: "",
        result_json: "",
        unknown_field_9: 0,
    };
    return decodeAsrResponseRawStep(data, { offset: 0, result });
};

interface DecodeAsrRawState {
    offset: number;
    result: Record<string, unknown>;
}

const decodeAsrResponseRawStep = (data: Uint8Array, state: DecodeAsrRawState): Record<string, unknown> => {
    if (state.offset >= data.length) return state.result;
    const decoded = decodeVarint(data, state.offset);
    if (decoded.bytesRead === 0) return state.result;
    const offset = state.offset + decoded.bytesRead;
    const tag = decoded.value;
    const next = applyAsrResponseField(data, {
        offset,
        result: state.result,
        fieldNumber: tag >>> 3,
        wireType: tag & 0x7,
    });
    return decodeAsrResponseRawStep(data, next);
};

interface ApplyAsrFieldState extends DecodeAsrRawState {
    fieldNumber: number;
    wireType: number;
}

const applyAsrResponseField = (data: Uint8Array, state: ApplyAsrFieldState): DecodeAsrRawState => {
    const reader = ASR_FIELD_READERS[state.fieldNumber];
    if (!reader) return skipAsrResponseField(data, state);
    return reader(data, state);
};

type AsrFieldReader = (data: Uint8Array, state: ApplyAsrFieldState) => DecodeAsrRawState;

const readStringAsrField = (key: string): AsrFieldReader => (data, state) => {
    if (state.wireType !== 2) return state;
    const { value, bytesRead } = decodeString(data, state.offset);
    state.result[key] = value;
    return { offset: state.offset + bytesRead, result: state.result };
};

const readVarintAsrField = (key: string): AsrFieldReader => (data, state) => {
    if (state.wireType !== 0) return state;
    const { value, bytesRead } = decodeVarint(data, state.offset);
    state.result[key] = value;
    return { offset: state.offset + bytesRead, result: state.result };
};

const skipAsrResponseField = (data: Uint8Array, state: ApplyAsrFieldState): DecodeAsrRawState => ({
    offset: state.offset + skipField(data, state.offset, state.wireType),
    result: state.result,
});

const ASR_FIELD_READERS: Record<number, AsrFieldReader> = {
    [RES_FIELDS.REQUEST_ID]: readStringAsrField("request_id"),
    [RES_FIELDS.TASK_ID]: readStringAsrField("task_id"),
    [RES_FIELDS.SERVICE_NAME]: readStringAsrField("service_name"),
    [RES_FIELDS.MESSAGE_TYPE]: readStringAsrField("message_type"),
    [RES_FIELDS.STATUS_CODE]: readVarintAsrField("status_code"),
    [RES_FIELDS.STATUS_MESSAGE]: readStringAsrField("status_message"),
    [RES_FIELDS.RESULT_JSON]: readStringAsrField("result_json"),
    [RES_FIELDS.UNKNOWN_FIELD_9]: readVarintAsrField("unknown_field_9"),
};
