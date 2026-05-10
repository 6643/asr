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
import { ok, err, tryResult, type Result } from "../../util.ts";

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

    const [jsonData, jsonError] = tryResult(() => JSON.parse(resultJson) as Record<string, unknown>);
    if (jsonError !== null) {
        return err(jsonError);
    }

    return ok(parseResponseJson(jsonData, parsed));
};

const parseResponseJson = (jsonData: Record<string, unknown>, raw: Record<string, unknown>): ASRResponse => {
    const resultsRaw = jsonData["results"] as Record<string, unknown>[] | undefined;
    const extraRaw = (jsonData["extra"] as Record<string, unknown>) || {};

    // 解析附加信息
    const extra = parseExtra(extraRaw);

    // 无 results，可能是心跳包
    if (!resultsRaw) {
        return {
            type: ResponseType.HEARTBEAT,
            packet_number: extra?.packet_number ?? -1,
            raw_json: jsonData,
            extra,
        };
    }

    // 解析 results
    const parsedResults = resultsRaw.map((r) => parseResult(r));

    // VAD 开始
    if (extraRaw["vad_start"]) {
        return {
            type: ResponseType.VAD_START,
            vad_start: true,
            raw_json: jsonData,
            results: parsedResults,
            extra,
        };
    }

    // 解析识别结果
    let text = "";
    let isInterim = true;
    let vadFinished = false;
    let nonstreamResult = false;

    for (const r of resultsRaw) {
        if (r["text"]) text = r["text"] as string;
        if (r["is_interim"] === false) isInterim = false;
        if (r["is_vad_finished"]) vadFinished = true;
        if ((r["extra"] as Record<string, unknown>)?.["nonstream_result"]) {
            nonstreamResult = true;
        }
    }

    // 最终结果
    if (nonstreamResult || (!isInterim && vadFinished)) {
        return {
            type: ResponseType.FINAL_RESULT,
            text,
            is_final: true,
            vad_finished: vadFinished,
            raw_json: jsonData,
            results: parsedResults,
            extra,
        };
    }

    // 中间结果
    return {
        type: ResponseType.INTERIM_RESULT,
        text,
        is_final: false,
        raw_json: jsonData,
        results: parsedResults,
        extra,
    };
};

const parseResult = (data: Record<string, unknown>): ASRResult => {
    return {
        text: (data["text"] as string) || "",
        start_time: (data["start_time"] as number) || 0,
        end_time: (data["end_time"] as number) || 0,
        confidence: (data["confidence"] as number) || 0,
        alternatives: ((data["alternatives"] as Record<string, unknown>[]) || []).map((a) => parseAlternative(a)),
        is_interim: (data["is_interim"] as boolean) ?? true,
        is_vad_finished: (data["is_vad_finished"] as boolean) || false,
        index: (data["index"] as number) || 0,
    };
};

const parseAlternative = (data: Record<string, unknown>): ASRAlternative => {
    return {
        text: (data["text"] as string) || "",
        start_time: (data["start_time"] as number) || 0,
        end_time: (data["end_time"] as number) || 0,
        words: ((data["words"] as Record<string, unknown>[]) || []).map((w) => parseWord(w)),
        semantic_related_to_prev: data["semantic_related_to_prev"] as boolean | null,
        oi_decoding_info: parseOIDecodingInfo(data["oi_decoding_info"] as Record<string, unknown> | undefined),
    };
};

const parseWord = (data: Record<string, unknown>): ASRWord => {
    return {
        word: (data["word"] as string) || "",
        start_time: (data["start_time"] as number) || 0,
        end_time: (data["end_time"] as number) || 0,
    };
};

const parseOIDecodingInfo = (data: Record<string, unknown> | undefined): OIDecodingInfo | null => {
    if (!data) return null;
    return {
        oi_former_word_num: (data["oi_former_word_num"] as number) || 0,
        oi_latter_word_num: (data["oi_latter_word_num"] as number) || 0,
        oi_words: (data["oi_words"] as unknown[]) || null,
    };
};

const parseExtra = (data: Record<string, unknown>): ASRExtra | null => {
    return {
        audio_duration: data["audio_duration"] as number | null,
        model_avg_rtf: data["model_avg_rtf"] as number | null,
        model_send_first_response: data["model_send_first_response"] as number | null,
        speech_adaptation_version: data["speech_adaptation_version"] as string | null,
        model_total_process_time: data["model_total_process_time"] as number | null,
        packet_number: data["packet_number"] as number | null,
        vad_start: data["vad_start"] as boolean | null,
        req_payload: data["req_payload"] as Record<string, unknown> | null,
    };
};

// =============
// 底层编解码函数
// =============

const decodeAsrResponseRaw = (data: Uint8Array): Record<string, unknown> => {
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    let offset = 0;

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

    while (offset < data.length) {
        const decoded = decodeVarint(data, offset);
        if (decoded.bytesRead === 0) break; // йҳІжӯўз•ёеҪўж•°жҚ®еҜјиҮҙжӯ»еҫӘзҺҜ
        const tag = decoded.value;
        offset += decoded.bytesRead;
        const fieldNumber = tag >>> 3;
        const wireType = tag & 0x7;

        switch (fieldNumber) {
            case RES_FIELDS.REQUEST_ID:
                if (wireType === 2) {
                    const { value, bytesRead: br } = decodeString(data, offset);
                    result["request_id"] = value;
                    offset += br;
                }
                break;
            case RES_FIELDS.TASK_ID:
                if (wireType === 2) {
                    const { value, bytesRead: br } = decodeString(data, offset);
                    result["task_id"] = value;
                    offset += br;
                }
                break;
            case RES_FIELDS.SERVICE_NAME:
                if (wireType === 2) {
                    const { value, bytesRead: br } = decodeString(data, offset);
                    result["service_name"] = value;
                    offset += br;
                }
                break;
            case RES_FIELDS.MESSAGE_TYPE:
                if (wireType === 2) {
                    const { value, bytesRead: br } = decodeString(data, offset);
                    result["message_type"] = value;
                    offset += br;
                }
                break;
            case RES_FIELDS.STATUS_CODE:
                if (wireType === 0) {
                    const { value, bytesRead: br } = decodeVarint(data, offset);
                    result["status_code"] = value;
                    offset += br;
                }
                break;
            case RES_FIELDS.STATUS_MESSAGE:
                if (wireType === 2) {
                    const { value, bytesRead: br } = decodeString(data, offset);
                    result["status_message"] = value;
                    offset += br;
                }
                break;
            case RES_FIELDS.RESULT_JSON:
                if (wireType === 2) {
                    const { value, bytesRead: br } = decodeString(data, offset);
                    result["result_json"] = value;
                    offset += br;
                }
                break;
            case RES_FIELDS.UNKNOWN_FIELD_9:
                if (wireType === 0) {
                    const { value, bytesRead: br } = decodeVarint(data, offset);
                    result["unknown_field_9"] = value;
                    offset += br;
                }
                break;
            default:
                offset += skipField(data, offset, wireType);
                break;
        }
    }

    return result;
};

const encodeVarint = (value: number): Uint8Array => {
    const bytes: number[] = [];
    while (value > 0x7f) {
        bytes.push((value & 0x7f) | 0x80);
        value >>>= 7;
    }
    bytes.push(value);
    return new Uint8Array(bytes);
};

const encodeVarintField = (fieldNumber: number, value: number): Uint8Array => {
    const tag = encodeVarint((fieldNumber << 3) | 0);
    const val = encodeVarint(value);
    return concatBytes([tag, val]);
};

const encodeStringField = (fieldNumber: number, value: string): Uint8Array => {
    const tag = encodeVarint((fieldNumber << 3) | 2);
    const strBytes = new TextEncoder().encode(value);
    const len = encodeVarint(strBytes.length);
    return concatBytes([tag, len, strBytes]);
};

const encodeBytesField = (fieldNumber: number, value: Uint8Array): Uint8Array => {
    const tag = encodeVarint((fieldNumber << 3) | 2);
    const len = encodeVarint(value.length);
    return concatBytes([tag, len, value]);
};

const concatBytes = (arrays: Uint8Array[]): Uint8Array => {
    const totalLength = arrays.reduce((sum, arr) => sum + arr.length, 0);
    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (const arr of arrays) {
        result.set(arr, offset);
        offset += arr.length;
    }
    return result;
};

const decodeVarint = (data: Uint8Array, offset: number): { value: number; bytesRead: number } => {
    let value = 0;
    let bytesRead = 0;
    let shift = 0;
    let byte: number | undefined;

    do {
        byte = data[offset + bytesRead];
        if (byte === undefined) break;
        value |= (byte & 0x7f) << shift;
        shift += 7;
        bytesRead++;
    } while (byte & 0x80);

    return { value, bytesRead };
};

const decodeString = (data: Uint8Array, offset: number): { value: string; bytesRead: number } => {
    const { value: len, bytesRead: lenBytes } = decodeVarint(data, offset);
    offset += lenBytes;
    const strBytes = data.slice(offset, offset + len);
    return { value: new TextDecoder().decode(strBytes), bytesRead: lenBytes + (len || 0) };
};

const skipField = (data: Uint8Array, offset: number, wireType: number): number => {
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
