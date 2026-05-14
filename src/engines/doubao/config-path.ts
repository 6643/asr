import path from "node:path";

export const DEFAULT_CREDENTIAL_PATH = "config/doubao.json";

export const getDefaultCredentialPath = (): string => {
    return path.resolve(process.cwd(), DEFAULT_CREDENTIAL_PATH);
};

export const resolveCredentialPath = (credentialPath: string): string => {
    const home = process.env.HOME || "";
    const defaultCredentialPath = path.normalize(getDefaultCredentialPath());
    const relativePart = credentialPath.startsWith("~/") ? credentialPath.slice(2) : credentialPath;
    const relativeSegments = relativePart.split(/[\\/]+/);

    if (relativeSegments.includes("..")) {
        throw new Error(`Credential path contains traversal segments: ${credentialPath}`);
    }

    const expanded = credentialPath.startsWith("~/")
        ? path.join(home, relativePart)
        : credentialPath;
    const normalized = path.normalize(expanded);

    if (path.isAbsolute(normalized) && normalized !== defaultCredentialPath) {
        throw new Error(`Credential path must be relative or use the default location: ${credentialPath}`);
    }

    return path.isAbsolute(normalized) ? normalized : path.resolve(process.cwd(), normalized);
};
