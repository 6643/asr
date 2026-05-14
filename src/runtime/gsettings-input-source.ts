export interface GsettingsInputSource {
    backend: string;
    id: string;
}

export const parseGsettingsInputSources = (value: string): GsettingsInputSource[] => {
    const pattern = /\('([^']*)',\s*'([^']*)'\)/g;
    return Array.from(value.matchAll(pattern)).flatMap(parseGsettingsInputSourceMatch);
};

const parseGsettingsInputSourceMatch = (match: RegExpMatchArray): GsettingsInputSource[] => {
    const backend = match[1]?.trim();
    const id = match[2]?.trim();
    if (!backend || !id) return [];
    return [{ backend, id }];
};

export const normalizeGsettingsInputSources = (value: string): string => {
    return value.replace(/\('ibus',\s*'doubao-asr'\)/g, "('ibus', 'asr')");
};

const parseGsettingsCurrentIndex = (value: string): number | null => {
    const match = value.match(/uint32\s+(\d+)/);
    if (!match?.[1]) return null;
    const parsed = Number(match[1]);
    return Number.isFinite(parsed) ? parsed : null;
};

export const isInputSourceSelected = (sourcesValue: string, currentValue: string, engineName: string): boolean => {
    const sources = parseGsettingsInputSources(sourcesValue);
    const currentIndex = parseGsettingsCurrentIndex(currentValue);
    if (currentIndex === null) return false;

    const currentSource = sources[currentIndex];
    return currentSource?.backend === "ibus" && currentSource.id === engineName;
};

export const normalizeGsettingsInputSourcesState = (
    sourcesValue: string,
    currentValue: string,
): { sources: string; current: string } => {
    return {
        sources: normalizeGsettingsInputSources(sourcesValue),
        current: currentValue,
    };
};

const formatGsettingsInputSources = (sources: GsettingsInputSource[]): string => {
    return `[${sources.map((source) => `('${source.backend}', '${source.id}')`).join(", ")}]`;
};

export const selectGsettingsInputSourceState = (
    sourcesValue: string,
    currentValue: string,
    engineName: string,
): { sources: string; current: string } => {
    const normalizedSourcesValue = normalizeGsettingsInputSources(sourcesValue);
    const sources = parseGsettingsInputSources(normalizedSourcesValue);
    if (sources.length === 0) {
        return { sources: normalizedSourcesValue, current: currentValue };
    }

    let targetIndex = sources.findIndex((source) => source.backend === "ibus" && source.id === engineName);
    if (targetIndex < 0) {
        targetIndex = sources.length;
        sources.push({ backend: "ibus", id: engineName });
    }

    return {
        sources: formatGsettingsInputSources(sources),
        current: `uint32 ${targetIndex}`,
    };
};
