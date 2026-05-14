export const isProductionMode = (): boolean => {
    const value = (process.env.NODE_ENV || process.env.BUN_ENV || "").trim().toLowerCase();
    return value === "production";
};

export const shouldRequireSamiAppKey = (): boolean => isProductionMode();
