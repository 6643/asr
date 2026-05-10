// 系统音频输出静音控制

import fs from "fs";

import { runCommand } from "../util.ts";

let mutedByUs = false;

const hasCommand = (command: string): boolean => {
    const pathList = (process.env.PATH || "").split(":");
    return pathList.some((dir) => fs.existsSync(`${dir}/${command}`));
};

const hasWpctl = hasCommand("wpctl");

const isMuted = (): boolean => {
    if (!hasWpctl) return false;
    const [output, outputError] = runCommand("wpctl", ["get-volume", "@DEFAULT_AUDIO_SINK@"], { timeoutMs: 1000 });
    return outputError === null && output.stdout.includes("[MUTED]");
};

const runMute = (mute: boolean): boolean => {
    if (!hasWpctl) return false;
    const [, error] = runCommand("wpctl", ["set-mute", "@DEFAULT_AUDIO_SINK@", mute ? "1" : "0"], { timeoutMs: 1000 });
    return error === null;
};

export const muteSpeaker = (): void => {
    if (!hasWpctl || mutedByUs || isMuted()) return;
    mutedByUs = runMute(true);
};

export const unmuteSpeaker = (): void => {
    if (!hasWpctl || !mutedByUs) return;
    mutedByUs = !runMute(false);
};
