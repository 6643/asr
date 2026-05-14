import type { Result } from "../util.ts";
import type { RecognitionSession } from "./session.ts";

export type RecognitionEvent =
    | { type: "interim"; text: string }
    | { type: "final"; text: string }
    | { type: "error"; message: string }
    | { type: "vad" }
    | { type: "session_finished" };

export interface RecognitionEngine<TClient> {
    name: string;
    createClient: () => TClient;
    prepare: (client: TClient) => Promise<Result<void>>;
    describe: (client: TClient) => string[];
    startSession: (client: TClient, options?: { debugEnabled?: boolean }) => Promise<Result<RecognitionSession>>;
}
