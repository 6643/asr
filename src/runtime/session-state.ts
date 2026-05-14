export interface RecognitionTranscriptState {
    sawAnyResult: boolean;
    sawRecognitionError: boolean;
    latestInterimText: string;
    finalText: string;
}

export const createRecognitionTranscriptState = (): RecognitionTranscriptState => ({
    sawAnyResult: false,
    sawRecognitionError: false,
    latestInterimText: "",
    finalText: "",
});

export const recordInterimTranscript = (state: RecognitionTranscriptState, text: string): RecognitionTranscriptState => ({
    ...state,
    sawAnyResult: true,
    latestInterimText: text,
});

export const recordFinalTranscript = (state: RecognitionTranscriptState, text: string): RecognitionTranscriptState => ({
    ...state,
    sawAnyResult: true,
    finalText: text,
});

export const recordRecognitionError = (state: RecognitionTranscriptState): RecognitionTranscriptState => ({
    ...state,
    sawRecognitionError: true,
});

export interface SpeakerLifecycleState {
    sessionStarted: boolean;
    speakerMuted: boolean;
    speakerMutePending: boolean;
}

export interface SpeakerMuteTransition {
    state: SpeakerLifecycleState;
    shouldMute: boolean;
}

export interface SpeakerReleaseTransition {
    state: SpeakerLifecycleState;
    shouldUnmute: boolean;
}

export const createSpeakerLifecycleState = (): SpeakerLifecycleState => ({
    sessionStarted: false,
    speakerMuted: false,
    speakerMutePending: false,
});

export const markSessionStarted = (state: SpeakerLifecycleState): SpeakerLifecycleState => ({
    ...state,
    sessionStarted: true,
});

export const requestSpeakerMute = (state: SpeakerLifecycleState): SpeakerMuteTransition => {
    if (state.speakerMuted) {
        return { state, shouldMute: false };
    }
    if (!state.sessionStarted) {
        return { state: { ...state, speakerMutePending: true }, shouldMute: false };
    }
    return { state: { ...state, speakerMuted: true }, shouldMute: true };
};

export const settlePendingSpeakerMute = (state: SpeakerLifecycleState): SpeakerMuteTransition => {
    if (!state.speakerMutePending || state.speakerMuted || !state.sessionStarted) {
        return { state, shouldMute: false };
    }
    return {
        state: { ...state, speakerMuted: true, speakerMutePending: false },
        shouldMute: true,
    };
};

export const requestSpeakerRelease = (state: SpeakerLifecycleState): SpeakerReleaseTransition => {
    if (!state.speakerMuted) {
        return {
            state: { ...state, speakerMutePending: false },
            shouldUnmute: false,
        };
    }

    return {
        state: { ...state, speakerMuted: false, speakerMutePending: false },
        shouldUnmute: true,
    };
};

export interface MicLifecycleState {
    opened: boolean;
    ready: boolean;
    closed: boolean;
}

export const createMicLifecycleState = (): MicLifecycleState => ({
    opened: false,
    ready: false,
    closed: false,
});

export const markMicOpened = (state: MicLifecycleState): MicLifecycleState => ({
    ...state,
    opened: true,
});

export const markMicReady = (state: MicLifecycleState): MicLifecycleState => ({
    ...state,
    ready: true,
});

export const markMicClosed = (state: MicLifecycleState): MicLifecycleState => ({
    ...state,
    closed: true,
});

export interface DoubaoLifecycleState {
    starting: boolean;
    started: boolean;
    finished: boolean;
}

export const createDoubaoLifecycleState = (): DoubaoLifecycleState => ({
    starting: false,
    started: false,
    finished: false,
});

export const markDoubaoStarting = (state: DoubaoLifecycleState): DoubaoLifecycleState => ({
    ...state,
    starting: true,
});

export const markDoubaoStarted = (state: DoubaoLifecycleState): DoubaoLifecycleState => ({
    ...state,
    starting: false,
    started: true,
});

export const markDoubaoFinished = (state: DoubaoLifecycleState): DoubaoLifecycleState => ({
    ...state,
    finished: true,
});
