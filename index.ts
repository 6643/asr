#!/usr/bin/env bun

import { IBUS_XML, initIbusRuntime, startIbusService } from "./src/runtime/ibus.ts";
import { runRuntime } from "./src/runtime/app.ts";
import { printStartupBanner } from "./src/runtime/output.ts";
import { createDoubaoEngine } from "./src/engines/doubao/index.ts";

const hasArg = (value: string): boolean => process.argv.includes(value);
const isDebugEnabled = (): boolean => hasArg("--debug");

if (hasArg("--ibus-xml")) {
    process.stdout.write(IBUS_XML);
    process.exit(0);
}

if (hasArg("--ibus")) {
    await startIbusService();
    await new Promise(() => {});
}

const [, initError] = await initIbusRuntime();
if (initError !== null) {
    console.error(initError.message);
    process.exit(1);
}

printStartupBanner();

await runRuntime(createDoubaoEngine(), { debugEnabled: isDebugEnabled() });
