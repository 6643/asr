const MIC_READY_SOUND_PATH = "/usr/share/sounds/freedesktop/stereo/bell.oga";

export const playMicReadyNotification = async (): Promise<void> => {
    const player = Bun.which("pw-play");
    if (!player) return;

    const proc = Bun.spawn([player, MIC_READY_SOUND_PATH], {
        stdout: "ignore",
        stderr: "ignore",
    });
    await proc.exited.catch(() => {}); // optional notification, failure is acceptable
};
