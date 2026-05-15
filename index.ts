#!/usr/bin/env bun

import { IBUS_XML } from "./src/runtime/ibus-meta.ts";
import { startIbusService } from "./src/runtime/ibus.ts";
import { runRuntime } from "./src/runtime/app.ts";
import { printTimedDomain, printTimedDomainError, setLogLevel, LogLevel } from "./src/runtime/output.ts";
import { createDoubaoEngine } from "./src/engines/doubao/index.ts";
import { isErr, tryAsyncResult } from "./src/util.ts";

const hasArg = (value: string): boolean => process.argv.includes(value);
const isDebugEnabled = (): boolean => hasArg("--debug");

const parseLogLevel = (): LogLevel => {
    const level = process.env.LOG_LEVEL?.toUpperCase();
    switch (level) {
        case "ERROR": return LogLevel.ERROR;
        case "WARN": return LogLevel.WARN;
        case "INFO": return LogLevel.INFO;
        case "DEBUG": return LogLevel.DEBUG;
        default: return isDebugEnabled() ? LogLevel.DEBUG : LogLevel.INFO;
    }
};

const main = async (): Promise<void> => {
    setLogLevel(parseLogLevel());

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
