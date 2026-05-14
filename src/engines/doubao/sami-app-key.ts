import { err, ok, type Result } from "../../util.ts";

export const resolveSamiAppKey = (
    rawAppKey: string | undefined,
    productionMode: boolean,
): Result<string> => {
    const value = rawAppKey?.trim() || "";
    if (value) return ok(value);
    if (productionMode) return err(new Error("ASR_SAMI_APP_KEY is required in production"));
    return ok("SYlxZr6LnvBaIVmF");
};
