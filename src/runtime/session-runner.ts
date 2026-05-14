import { createMicStream } from "./mic.ts";
import { commitText } from "./commit.ts";
import { muteSpeaker, unmuteSpeaker } from "./mute.ts";
import { playMicReadyNotification } from "./notify.ts";
import { startMicLifecycle } from "./session-mic.ts";
import { startDoubaoLifecycle } from "./session-doubao.ts";
import {
    createRecognitionTranscriptState,
    createDoubaoLifecycleState,
    createMicLifecycleState,
    createSpeakerLifecycleState,
    markDoubaoFinished,
    markDoubaoStarted,
    markDoubaoStarting,
    markMicClosed,
    markMicOpened,
    markMicReady,
    markSessionStarted,
    recordFinalTranscript,
    recordInterimTranscript,
    recordRecognitionError,
    requestSpeakerMute,
    requestSpeakerRelease,
    settlePendingSpeakerMute,
} from "./session-state.ts";
import {
    printAsrError,
    printIbusCommitFailure,
    printIbusCommitSuccess,
    printFinal,
    printRecognitionError,
    printInterim,
    printSessionStart,
    printTimedDomain,
} from "./output.ts";
import type { RecognitionEngine } from "./recognition.ts";
import { isErr, createAsyncQueue, tryAsyncResult, withFinallyAsync } from "../util.ts";

const sanitizeAsrText = (text: string): string => {
    if (!text) return "";
    const sanitized = text.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "").trim();
    return sanitized.length > 4096 ? sanitized.slice(0, 4096) : sanitized;
};

type SessionRunnerDeps = {
    createMicStream: typeof createMicStream;
    commitText: typeof commitText;
    muteSpeaker: typeof muteSpeaker;
    unmuteSpeaker: typeof unmuteSpeaker;
    playMicReadyNotification: typeof playMicReadyNotification;
};

const defaultSessionRunnerDeps: SessionRunnerDeps = {
    createMicStream,
    commitText,
    muteSpeaker,
    unmuteSpeaker,
    playMicReadyNotification,
};

type SessionContext = {
    sessionId: string;
    audioQueue: ReturnType<typeof createAsyncQueue<Uint8Array>>;
    transcriptState: ReturnType<typeof createRecognitionTranscriptState>;
    speakerState: ReturnType<typeof createSpeakerLifecycleState>;
    doubaoState: ReturnType<typeof createDoubaoLifecycleState>;
    micState: ReturnType<typeof createMicLifecycleState>;
    sawAudioChunk: boolean;
    micFailure: Error | null;
};

let nextSessionId = 0;
let commitQueueTail: Promise<void> = Promise.resolve();

const createSessionId = (): string => `session-${++nextSessionId}`;

const createSessionContext = (): SessionContext => ({
    sessionId: createSessionId(),
    audioQueue: createAsyncQueue<Uint8Array>(),
    transcriptState: createRecognitionTranscriptState(),
    speakerState: createSpeakerLifecycleState(),
    doubaoState: createDoubaoLifecycleState(),
    micState: createMicLifecycleState(),
    sawAudioChunk: false,
    micFailure: null,
});

const enqueueCommitTask = (task: () => Promise<void>): void => {
    const runTask = async (): Promise<void> => {
        await tryAsyncResult(task);
    };

    commitQueueTail = commitQueueTail.then(runTask, runTask);
};

const startRecognizedTextCommit = (
    text: string,
    deps: SessionRunnerDeps,
    debugEnabled: boolean,
    sessionId: string,
): void => {
    printFinal(text);
    enqueueCommitTask(() => commitRecognizedText(text, deps, debugEnabled, sessionId));
};

const commitRecognizedText = async (
    text: string,
    deps: SessionRunnerDeps,
    debugEnabled: boolean,
    sessionId: string,
): Promise<void> => {
    const result = await tryAsyncResult(() => deps.commitText(text));
    if (isErr(result)) return handleCommitFailure(result.error.message, debugEnabled, sessionId);
    if (result.value.success) return printIbusCommitSuccess();
    handleCommitFailure(result.value.message, debugEnabled, sessionId);
};

const handleCommitFailure = (message: string, debugEnabled: boolean, sessionId: string): void => {
    if (debugEnabled) printTimedDomain("ibus", `commit err session=${sessionId} ${message}`);
    printIbusCommitFailure(message);
};

const handleRecognitionEvent = async (
    resp: Parameters<NonNullable<Parameters<typeof startDoubaoLifecycle>[5]["onEvent"]>>[0],
    state: {
        transcriptState: ReturnType<typeof createRecognitionTranscriptState>;
        doubaoState: ReturnType<typeof createDoubaoLifecycleState>;
    },
    debugEnabled: boolean,
    deps: SessionRunnerDeps,
    context: SessionContext,
): Promise<void> => {
    if (resp.type === "interim") return handleInterimEvent(resp.text || "", state, context);
    if (resp.type === "final") return handleFinalEvent(resp.text || "", state, context, deps, debugEnabled);
    if (resp.type === "error") return handleErrorEvent(resp.message || "Unknown error", state, context, debugEnabled);
    if (resp.type === "vad") return debugDoubaoEvent(debugEnabled, "vad");
    handleSessionFinishedEvent(state, context, debugEnabled);
};

const handleInterimEvent = (
    rawText: string,
    state: { transcriptState: ReturnType<typeof createRecognitionTranscriptState> },
    context: SessionContext,
): void => {
    const text = sanitizeAsrText(rawText);
    state.transcriptState = recordInterimTranscript(state.transcriptState, text);
    context.transcriptState = state.transcriptState;
    printInterim(text);
};

const handleFinalEvent = (
    rawText: string,
    state: { transcriptState: ReturnType<typeof createRecognitionTranscriptState> },
    context: SessionContext,
    deps: SessionRunnerDeps,
    debugEnabled: boolean,
): void => {
    const text = sanitizeAsrText(rawText);
    state.transcriptState = recordFinalTranscript(state.transcriptState, text);
    context.transcriptState = state.transcriptState;
    startRecognizedTextCommit(text, deps, debugEnabled, context.sessionId);
};

const handleErrorEvent = (
    message: string,
    state: { transcriptState: ReturnType<typeof createRecognitionTranscriptState> },
    context: SessionContext,
    debugEnabled: boolean,
): void => {
    state.transcriptState = recordRecognitionError(state.transcriptState);
    context.transcriptState = state.transcriptState;
    debugDoubaoEvent(debugEnabled, `error ${message}`);
    printAsrError(message);
};

const handleSessionFinishedEvent = (
    state: { doubaoState: ReturnType<typeof createDoubaoLifecycleState> },
    context: SessionContext,
    debugEnabled: boolean,
): void => {
    state.doubaoState = markDoubaoFinished(state.doubaoState);
    context.doubaoState = state.doubaoState;
    debugDoubaoEvent(debugEnabled, "session_finished");
};

const debugDoubaoEvent = (debugEnabled: boolean, message: string): void => {
    if (!debugEnabled) return;
    printTimedDomain("doubao", message);
};

export const runRecognitionSession = async <TClient>(
    engine: RecognitionEngine<TClient>,
    client: TClient,
    stopSignal: AbortSignal,
    options: { debugEnabled?: boolean; deps?: Partial<SessionRunnerDeps>; releaseSignal?: AbortSignal } = {},
): Promise<void> => {
    const debugEnabled = options.debugEnabled ?? false;
    const deps = { ...defaultSessionRunnerDeps, ...options.deps };
    const context = createSessionContext();
    let transcriptState = context.transcriptState;
    let speakerState = context.speakerState;
    let doubaoState = context.doubaoState;
    let speakerReleaseCalled = false;
    const releaseSpeaker = (): void => {
        if (speakerReleaseCalled) return;
        const transition = requestSpeakerRelease(context.speakerState);
        speakerState = transition.state;
        context.speakerState = speakerState;
        speakerReleaseCalled = true;
        if (transition.shouldUnmute && debugEnabled) printTimedDomain("speaker", "unmute");
        deps.unmuteSpeaker();
    };
    const onRelease = (): void => {
        releaseSpeaker();
    };

    if (options.releaseSignal) {
        options.releaseSignal.addEventListener("abort", onRelease, { once: true });
    }

    await deps.playMicReadyNotification();
    if (stopSignal.aborted || options.releaseSignal?.aborted) return;

    const micLifecycle = startMicLifecycle(
        { createMicStream: deps.createMicStream },
        stopSignal,
        {
            onOpen: () => {
                context.micState = markMicOpened(context.micState);
                if (debugEnabled) printTimedDomain("mic", "open");
            },
            onReady: async () => {
                context.micState = markMicReady(context.micState);
                if (debugEnabled) printTimedDomain("mic", "ready");
                if (options.releaseSignal?.aborted) return;
                printSessionStart();
                const transition = requestSpeakerMute(context.speakerState);
                speakerState = transition.state;
                context.speakerState = speakerState;
                muteSpeakerIfRequested(transition.shouldMute, debugEnabled, deps);
            },
            onChunk: (chunk) => {
                context.sawAudioChunk = true;
                context.audioQueue.push(chunk);
            },
            onClose: (summary) => {
                context.micState = markMicClosed(context.micState);
                if (debugEnabled) printTimedDomain("mic", `close chunks=${summary.chunkCount} bytes=${summary.byteCount} peak=${summary.peak}`);
                context.audioQueue.close();
            },
            onFailure: (error) => {
                context.micFailure = error;
            },
        },
    );
    const cleanup = async (): Promise<void> => {
        context.audioQueue.close();
        micLifecycle.stop();
        await micLifecycle.task.catch(() => {}); // cleanup must complete even if mic task failed
        releaseSpeaker();
        if (options.releaseSignal) {
            options.releaseSignal.removeEventListener("abort", onRelease);
        }
    };
    const doubaoTask = startDoubaoLifecycle(
        engine,
        client,
        context.audioQueue,
        stopSignal,
        { debugEnabled },
        {
            onSessionStart: () => {
                doubaoState = markDoubaoStarting(doubaoState);
                context.doubaoState = doubaoState;
                if (debugEnabled) printTimedDomain("doubao", "session start");
            },
            onSessionStartFailed: (message) => {
                if (debugEnabled) printTimedDomain("doubao", `session start failed: ${message}`);
                printRecognitionError(message);
            },
            onSessionStarted: () => {
                doubaoState = markDoubaoStarted(doubaoState);
                context.doubaoState = doubaoState;
                speakerState = markSessionStarted(speakerState);
                const settled = settlePendingSpeakerMute(speakerState);
                speakerState = settled.state;
                context.speakerState = speakerState;
                muteSpeakerIfRequested(settled.shouldMute, debugEnabled, deps);
                if (debugEnabled) printTimedDomain("doubao", "session started");
            },
            onWriterOpen: () => {
                if (debugEnabled) printTimedDomain("doubao", "writer open");
            },
            onWriterClose: () => {
                if (debugEnabled) printTimedDomain("doubao", "writer close");
            },
            onPushFailed: (message) => {
                if (debugEnabled) printTimedDomain("doubao", `push failed: ${message}`);
            },
            onEvent: async (resp) => {
                await handleRecognitionEvent(
                    resp,
                    { transcriptState, doubaoState },
                    debugEnabled,
                    deps,
                    context,
                );
                transcriptState = context.transcriptState;
                doubaoState = context.doubaoState;
            },
        },
    );

    await withFinallyAsync(() => finishRecognitionSession(doubaoTask, micLifecycle.task, context, debugEnabled), cleanup);
};

const muteSpeakerIfRequested = (shouldMute: boolean, debugEnabled: boolean, deps: SessionRunnerDeps): void => {
    if (!shouldMute) return;
    if (debugEnabled) printTimedDomain("speaker", "mute");
    deps.muteSpeaker();
};

const finishRecognitionSession = async (
    doubaoTask: Promise<void>,
    micTask: Promise<void>,
    context: SessionContext,
    debugEnabled: boolean,
): Promise<void> => {
    await doubaoTask;
    await micTask;
    if (context.micFailure !== null) return reportMicFailure(context.micFailure, debugEnabled);
    reportMissingResultIfNeeded(context, debugEnabled);
};

const reportMicFailure = (error: Error, debugEnabled: boolean): void => {
    debugDoubaoEvent(debugEnabled, `error ${error.message}`);
    printRecognitionError(error.message);
};

const reportMissingResultIfNeeded = (context: SessionContext, debugEnabled: boolean): void => {
    if (context.transcriptState.sawAnyResult || context.transcriptState.sawRecognitionError) return;
    debugDoubaoEvent(debugEnabled, "no-result");
    printRecognitionError(context.sawAudioChunk ? "未收到识别结果" : "未收到音频");
};
