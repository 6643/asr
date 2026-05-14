// 系统音频输出静音控制

import fs from "fs";

import { isErr, runCommand } from "../util.ts";

let mutedByUs = false;

const hasCommand = (command: string): boolean => {
    const pathList = (process.env.PATH || "").split(":");
    return pathList.some((dir) => fs.existsSync(`${dir}/${command}`));
};

const hasWpctl = hasCommand("wpctl");

const isMuted = (): boolean => {
    if (!hasWpctl) return false;
    const output = runCommand("wpctl", ["get-volume", "@DEFAULT_AUDIO_SINK@"], { timeoutMs: 1000 });
    return !isErr(output) && output.value.stdout.includes("[MUTED]");
};

const runMute = (mute: boolean): boolean => {
    if (!hasWpctl) return false;
    const result = runCommand("wpctl", ["set-mute", "@DEFAULT_AUDIO_SINK@", mute ? "1" : "0"], { timeoutMs: 1000 });
    return !isErr(result);
};

export const muteSpeaker = (): void => {
    if (!hasWpctl || mutedByUs || isMuted()) return;
    mutedByUs = runMute(true);
};

export const unmuteSpeaker = (): void => {
    if (!hasWpctl || !mutedByUs) return;
    mutedByUs = !runMute(false);
};

export const resetMuteState = (): void => {
    mutedByUs = false;
};
