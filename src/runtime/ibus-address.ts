import fs from "fs";

import { err, isErr, ok, type Result, runCommand } from "../util.ts";

const extractUnixSocketPath = (address: string): string | null => {
    const match = address.match(/unix:path=([^,]+)/);
    return match?.[1] || null;
};

export const getIbusSocketPath = (address: string): string | null => extractUnixSocketPath(address);

export const parseIbusAddressCandidates = (address: string | undefined): string[] => {
    if (!address?.trim()) return [];
    return [address.trim()];
};

export const pickIbusAddressCandidate = (directAddress: string, envAddress: string): string => {
    if (directAddress) return directAddress;
    if (envAddress) return envAddress;
    return "";
};

export const isIbusAddressReady = (address: string): boolean => {
    const socketPath = extractUnixSocketPath(address);
    if (!socketPath) return true;
    return fs.existsSync(socketPath);
};

export const readCurrentIbusAddress = (): string => {
    const result = runCommand("ibus", ["address"], { timeoutMs: 1_000 });
    const directAddress = isErr(result) ? "" : result.value.stdout.trim();
    const envAddress = process.env.DBUS_SESSION_BUS_ADDRESS?.trim() || "";
    const candidate = pickIbusAddressCandidate(directAddress, envAddress);
    return candidate && isIbusAddressReady(candidate) ? candidate : "";
};

export const resolveIbusAddress = async (): Promise<Result<string>> => {
    return resolveIbusAddressAttempt([], 0);
};

const resolveIbusAddressAttempt = async (seenAddresses: string[], attempt: number): Promise<Result<string>> => {
    if (attempt >= 20) return err(new Error(`IBUS_ADDRESS is invalid after retries: ${seenAddresses.join(" | ")}`));

    const candidates = [readCurrentIbusAddress(), ...parseIbusAddressCandidates(process.env.IBUS_ADDRESS)].filter(
        (value): value is string => !!value,
    );
    recordSeenIbusAddresses(seenAddresses, candidates);

    const readyAddress = candidates.find(isIbusAddressReady);
    if (readyAddress) return ok(readyAddress);

    await Bun.sleep(500);
    return resolveIbusAddressAttempt(seenAddresses, attempt + 1);
};

const recordSeenIbusAddresses = (seenAddresses: string[], candidates: string[]): void => {
    for (const address of candidates) {
        recordSeenIbusAddress(seenAddresses, address);
    }
};

const recordSeenIbusAddress = (seenAddresses: string[], address: string): void => {
    if (seenAddresses.includes(address)) return;
    seenAddresses.push(address);
};
