import { ResponseType, type ASRAlternative, type ASRExtra, type ASRResponse, type ASRResult, type ASRWord, type OIDecodingInfo } from "./types.ts";

export const parseResponseJson = (jsonData: Record<string, unknown>): ASRResponse => {
    const resultsRaw = jsonData["results"] as Record<string, unknown>[] | undefined;
    const extraRaw = (jsonData["extra"] as Record<string, unknown>) || {};

    const extra = parseExtra(extraRaw);

    if (!resultsRaw) {
        return {
            type: ResponseType.HEARTBEAT,
            packet_number: extra?.packet_number ?? -1,
            raw_json: jsonData,
            extra,
        };
    }

    const parsedResults = resultsRaw.map((r) => parseResult(r));

    if (extraRaw["vad_start"]) {
        return {
            type: ResponseType.VAD_START,
            vad_start: true,
            raw_json: jsonData,
            results: parsedResults,
            extra,
        };
    }

    const flags = resultsRaw.reduce(collectResponseFlags, {
        text: "",
        isInterim: true,
        vadFinished: false,
        nonstreamResult: false,
    });

    if (flags.nonstreamResult || (!flags.isInterim && flags.vadFinished)) {
        return {
            type: ResponseType.FINAL_RESULT,
            text: flags.text,
            is_final: true,
            vad_finished: flags.vadFinished,
            raw_json: jsonData,
            results: parsedResults,
            extra,
        };
    }

    return {
        type: ResponseType.INTERIM_RESULT,
        text: flags.text,
        is_final: false,
        raw_json: jsonData,
        results: parsedResults,
        extra,
    };
};

const collectResponseFlags = (
    state: { text: string; isInterim: boolean; vadFinished: boolean; nonstreamResult: boolean },
    result: Record<string, unknown>,
): { text: string; isInterim: boolean; vadFinished: boolean; nonstreamResult: boolean } => ({
    text: result["text"] ? result["text"] as string : state.text,
    isInterim: result["is_interim"] === false ? false : state.isInterim,
    vadFinished: result["is_vad_finished"] ? true : state.vadFinished,
    nonstreamResult: (result["extra"] as Record<string, unknown>)?.["nonstream_result"] ? true : state.nonstreamResult,
});

export const parseResult = (data: Record<string, unknown>): ASRResult => {
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

export const parseAlternative = (data: Record<string, unknown>): ASRAlternative => {
    return {
        text: (data["text"] as string) || "",
        start_time: (data["start_time"] as number) || 0,
        end_time: (data["end_time"] as number) || 0,
        words: ((data["words"] as Record<string, unknown>[]) || []).map((w) => parseWord(w)),
        semantic_related_to_prev: data["semantic_related_to_prev"] as boolean | null,
        oi_decoding_info: parseOIDecodingInfo(data["oi_decoding_info"] as Record<string, unknown> | undefined),
    };
};

export const parseWord = (data: Record<string, unknown>): ASRWord => {
    return {
        word: (data["word"] as string) || "",
        start_time: (data["start_time"] as number) || 0,
        end_time: (data["end_time"] as number) || 0,
    };
};

export const parseOIDecodingInfo = (data: Record<string, unknown> | undefined): OIDecodingInfo | null => {
    if (!data) return null;
    return {
        oi_former_word_num: (data["oi_former_word_num"] as number) || 0,
        oi_latter_word_num: (data["oi_latter_word_num"] as number) || 0,
        oi_words: (data["oi_words"] as unknown[]) || null,
    };
};

export const parseExtra = (data: Record<string, unknown>): ASRExtra | null => {
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
