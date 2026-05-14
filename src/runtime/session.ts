import type { Result } from "../util.ts";
import type { RecognitionEvent } from "./recognition.ts";

export interface RecognitionSession {
    pushAudio: (chunk: Uint8Array) => Promise<Result<void>>;
    close: () => Promise<void>;
    events: AsyncGenerator<Result<RecognitionEvent>>;
}
