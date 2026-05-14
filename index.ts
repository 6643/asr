#!/usr/bin/env bun

import { IBUS_XML } from "./src/runtime/ibus-meta.ts";
import { startIbusService } from "./src/runtime/ibus.ts";
import { runRuntime } from "./src/runtime/app.ts";
import { printTimedDomain, printTimedDomainError } from "./src/runtime/output.ts";
import { createDoubaoEngine } from "./src/engines/doubao/index.ts";
import { isErr, tryAsyncResult } from "./src/util.ts";

const hasArg = (value: string): boolean => process.argv.includes(value);
const isDebugEnabled = (): boolean => hasArg("--debug");

const main = async (): Promise<void> => {
    if (hasArg("--ibus-xml")) {
        process.stdout.write(IBUS_XML);
        return;
    }

    if (hasArg("--ibus")) {
        const stopIbusService = await startIbusService();
        const stopController = new AbortController();
        const stopSignal = stopController.signal;
        const shutdown = async (): Promise<void> => {
            stopController.abort();
            await stopIbusService();
        };

        process.once("SIGINT", () => {
            void shutdown().catch(() => {});
        });
        process.once("SIGTERM", () => {
            void shutdown().catch(() => {});
        });

        await new Promise<void>((resolve) => {
            if (stopSignal.aborted) {
                resolve();
                return;
            }
            stopSignal.addEventListener("abort", () => resolve(), { once: true });
        });

        await stopIbusService();
        return;
    }

    printTimedDomain("app", "ASR 启动");

    await runRuntime(createDoubaoEngine(), { debugEnabled: isDebugEnabled() });
};

const runMainSafely = async (): Promise<void> => {
    const result = await tryAsyncResult(() => main());
    if (!isErr(result)) return;
    printTimedDomainError("app", `Fatal error: ${result.error.message}`);
    process.exit(1);
};

if (import.meta.main) {
    await runMainSafely();
}
