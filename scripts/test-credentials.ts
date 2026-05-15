#!/usr/bin/env bun

import { createConfig, ensureCredentials, getSamiTokenFromConfig, getSessionConfig } from "../src/engines/doubao/config.ts";
import { isErr } from "../src/util.ts";

const testCredentials = async () => {
    console.log("Creating config...");
    const config = createConfig();

    console.log("Ensuring credentials...");
    const ensureResult = await ensureCredentials(config);
    if (isErr(ensureResult)) {
        console.error("Failed to ensure credentials:", ensureResult.error.message);
        return;
    }
    console.log("✓ Credentials initialized");
    console.log("  Device ID:", config.deviceId);
    console.log("  Token:", config.token ? `${config.token.slice(0, 20)}...` : "null");

    console.log("\nGetting SAMI token...");
    const samiResult = await getSamiTokenFromConfig(config);
    if (isErr(samiResult)) {
        console.error("Failed to get SAMI token:", samiResult.error.message);
        return;
    }
    console.log("✓ SAMI token obtained:", samiResult.value.slice(0, 50) + "...");

    console.log("\nGetting session config...");
    const sessionResult = await getSessionConfig(config);
    if (isErr(sessionResult)) {
        console.error("Failed to get session config:", sessionResult.error.message);
        return;
    }
    console.log("✓ Session config obtained");

    console.log("\n✓ All credentials obtained successfully");
};

testCredentials().catch(console.error);
