import { expect, test } from "bun:test";
import {
    createRecognitionTranscriptState,
    createDoubaoLifecycleState,
    createMicLifecycleState,
    recordFinalTranscript,
    recordInterimTranscript,
    recordRecognitionError,
    createSpeakerLifecycleState,
    markDoubaoFinished,
    markDoubaoStarted,
    markDoubaoStarting,
    markMicClosed,
    markMicOpened,
    markMicReady,
    markSessionStarted,
    requestSpeakerMute,
    requestSpeakerRelease,
    settlePendingSpeakerMute,
} from "./session-state.ts";

test("recognition transcript state tracks events independently", () => {
    const start = createRecognitionTranscriptState();
    const interim = recordInterimTranscript(start, "中间");
    const final = recordFinalTranscript(interim, "最终");
    const errored = recordRecognitionError(final);

    expect(start.sawAnyResult).toBe(false);
    expect(interim.sawAnyResult).toBe(true);
    expect(interim.latestInterimText).toBe("中间");
    expect(final.finalText).toBe("最终");
    expect(errored.sawRecognitionError).toBe(true);
});

test("speaker lifecycle mutes only after session starts", () => {
    const beforeStart = requestSpeakerMute(createSpeakerLifecycleState());
    expect(beforeStart.shouldMute).toBe(false);
    expect(beforeStart.state.speakerMutePending).toBe(true);
    expect(beforeStart.state.speakerMuted).toBe(false);

    const started = markSessionStarted(beforeStart.state);
    const muted = settlePendingSpeakerMute(started);
    expect(muted.shouldMute).toBe(true);
    expect(muted.state.speakerMuted).toBe(true);
    expect(muted.state.speakerMutePending).toBe(false);
});

test("speaker release clears mute state", () => {
    const started = markSessionStarted(createSpeakerLifecycleState());
    const muted = settlePendingSpeakerMute({ ...started, speakerMutePending: false, speakerMuted: true });
    const released = requestSpeakerRelease(muted.state);

    expect(released.shouldUnmute).toBe(true);
    expect(released.state.speakerMuted).toBe(false);
});

test("mic lifecycle tracks open ready close", () => {
    const opened = markMicOpened(createMicLifecycleState());
    const ready = markMicReady(opened);
    const closed = markMicClosed(ready);

    expect(opened.opened).toBe(true);
    expect(ready.ready).toBe(true);
    expect(closed.closed).toBe(true);
});

test("doubao lifecycle tracks starting started finished", () => {
    const starting = markDoubaoStarting(createDoubaoLifecycleState());
    const started = markDoubaoStarted(starting);
    const finished = markDoubaoFinished(started);

    expect(starting.starting).toBe(true);
    expect(started.started).toBe(true);
    expect(finished.finished).toBe(true);
});
