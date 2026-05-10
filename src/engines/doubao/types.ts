export enum ResponseType {
    TASK_STARTED = "TASK_STARTED",
    SESSION_STARTED = "SESSION_STARTED",
    SESSION_FINISHED = "SESSION_FINISHED",
    VAD_START = "VAD_START",
    INTERIM_RESULT = "INTERIM_RESULT",
    FINAL_RESULT = "FINAL_RESULT",
    HEARTBEAT = "HEARTBEAT",
    ERROR = "ERROR",
    UNKNOWN = "UNKNOWN",
}

export enum FrameState {
    FRAME_STATE_UNSPECIFIED = 0,
    FRAME_STATE_FIRST = 1,
    FRAME_STATE_MIDDLE = 3,
    FRAME_STATE_LAST = 9,
}

export interface AudioInfo {
    channel: number;
    format: string;
    sample_rate: number;
}

export interface SessionExtraConfig {
    app_name: string;
    cell_compress_rate: number;
    did: string;
    enable_asr_threepass: boolean;
    enable_asr_twopass: boolean;
    input_mode: string;
}

export interface SessionConfig {
    audio_info: AudioInfo;
    enable_punctuation: boolean;
    enable_speech_rejection: boolean;
    extra: SessionExtraConfig;
}

export type AudioChunk = Uint8Array;

export interface ASRWord {
    word: string;
    start_time: number;
    end_time: number;
}

export interface OIDecodingInfo {
    oi_former_word_num: number;
    oi_latter_word_num: number;
    oi_words: unknown[] | null;
}

export interface ASRAlternative {
    text: string;
    start_time: number;
    end_time: number;
    words: ASRWord[];
    semantic_related_to_prev: boolean | null;
    oi_decoding_info: OIDecodingInfo | null;
}

export interface ASRResult {
    text: string;
    start_time: number;
    end_time: number;
    confidence: number;
    alternatives: ASRAlternative[];
    is_interim: boolean;
    is_vad_finished: boolean;
    index: number;
}

export interface ASRExtra {
    audio_duration: number | null;
    model_avg_rtf: number | null;
    model_send_first_response: number | null;
    speech_adaptation_version: string | null;
    model_total_process_time: number | null;
    packet_number: number | null;
    vad_start: boolean | null;
    req_payload: Record<string, unknown> | null;
}

export interface ASRResponse {
    type: ResponseType;
    text?: string;
    is_final?: boolean;
    vad_start?: boolean;
    vad_finished?: boolean;
    packet_number?: number;
    error_msg?: string;
    raw_json?: Record<string, unknown> | null;
    results?: ASRResult[];
    extra?: ASRExtra | null;
}

export interface DeviceCredentials {
    device_id: string | null;
    install_id: string | null;
    cdid: string | null;
    openudid: string | null;
    clientudid: string | null;
    token: string;
    sami_token: string | null;
    wave_session: Record<string, unknown> | null;
}

export interface WaveSession {
    ticket: string;
    ticket_long: string;
    encryption_key: Uint8Array;
    client_random: Uint8Array;
    server_random: Uint8Array;
    shared_key: Uint8Array;
    ticket_exp: number;
    ticket_long_exp: number;
    expires_at: number;
}
