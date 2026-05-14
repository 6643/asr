import { expect, test } from "bun:test";
import fs from "fs";
import path from "node:path";

import { createConfig, ensureCredentials } from "./config.ts";
import { ignoreError, isErr } from "../../util.ts";

test("default credential path points to project config directory", () => {
    const config = createConfig();
    expect(config.credentialPath).toBe(path.resolve(process.cwd(), "config/doubao.json"));
});

test("credential path rejects traversal segments", async () => {
    const result = await ensureCredentials(createConfig({ credentialPath: "~/../../etc/passwd" }));
    expect(isErr(result)).toBe(true);
    if (isErr(result)) {
        expect(result.error.message).toContain("Credential path contains traversal segments");
    }
});

test("credential path rejects absolute user-provided paths", async () => {
    const result = await ensureCredentials(createConfig({ credentialPath: "/tmp/asr-credentials.json" }));
    expect(isErr(result)).toBe(true);
    if (isErr(result)) {
        expect(result.error.message).toContain("must be relative or use the default location");
    }
});

test("credential file may be group writable and still load", async () => {
    const tmpPath = "config/doubao.json.testtmp";
    try {
        await Bun.write(tmpPath, JSON.stringify({
            device_id: "1",
            install_id: "2",
            cdid: "3",
            openudid: "4",
            clientudid: "5",
            token: "6",
            sami_token: null,
            wave_session: null,
        }, null, 2));
        fs.chmodSync(tmpPath, 0o600);

        const result = await ensureCredentials(createConfig({ credentialPath: tmpPath }));
        expect(isErr(result)).toBe(false);
    } finally {
        ignoreError(() => fs.unlinkSync(tmpPath));
    }
});
