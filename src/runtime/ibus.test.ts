import { expect, test } from "bun:test";

import { getIbusComponentXml, getIbusEnginesXml } from "./ibus.ts";

test("ibus component xml uses inline engine definitions", () => {
    const xml = getIbusComponentXml();

    expect(xml).toContain("<engines>");
    expect(xml).toContain("<engine>");
    expect(xml).toContain("<name>asr</name>");
    expect(xml).toContain("<longname>ZH</longname>");
    expect(xml).toContain("<symbol>asr</symbol>");
    expect(xml).toContain("<exec>/home/_/Public/doubao_asr/bin/asr-service</exec>");
});

test("ibus engines xml exposes a fragment for legacy exec mode", () => {
    const xml = getIbusEnginesXml();

    expect(xml).toContain("<engines>");
    expect(xml).toContain("<name>asr</name>");
    expect(xml).toContain("<longname>ZH</longname>");
    expect(xml).toContain("<symbol>asr</symbol>");
    expect(xml).not.toContain("<component>");
});
