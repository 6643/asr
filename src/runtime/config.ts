export const isAutoSwitchEnabled = (): boolean => {
    const env = process.env.ASR_AUTO_SWITCH;
    if (env === undefined) return true;
    return env !== "false" && env !== "0";
};

export const getIbusRpcTimeout = (): number => {
    const env = process.env.ASR_IBUS_RPC_TIMEOUT;
    if (env === undefined) return 1500;
    const parsed = Number.parseInt(env, 10);
    return Number.isNaN(parsed) || parsed <= 0 ? 1500 : parsed;
};

export const isDebugEnabled = (): boolean => {
    const env = process.env.ASR_DEBUG;
    return env === "1" || env === "true";
};
