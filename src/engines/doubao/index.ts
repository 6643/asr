import { createClient } from "./client.ts";
import { ensureCredentials } from "./config.ts";
import { createDoubaoSession } from "./session.ts";
import type { RecognitionEngine } from "../../runtime/recognition.ts";

export const createDoubaoEngine = (): RecognitionEngine<ReturnType<typeof createClient>> => ({
    name: "doubao",
    createClient: () => createClient(),
    prepare: async (client) => ensureCredentials(client.config),
    describe: (client) => [`[doubao] ${client.config.deviceId}`],
    startSession: async (client, options) => createDoubaoSession(client, options),
});
