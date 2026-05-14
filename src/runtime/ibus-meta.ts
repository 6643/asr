export const IBUS_ENGINE_NAME = "asr";
export const IBUS_BUS_NAME = "org.freedesktop.IBus.ASR";
export const IBUS_ENGINE_PATH_PREFIX = "/org/freedesktop/IBus/Engine/ASR";
export const IBUS_FACTORY_PATH = "/org/freedesktop/IBus/Factory";
export const IBUS_FACTORY_IFACE = "org.freedesktop.IBus.Factory";
export const IBUS_ENGINE_IFACE = "org.freedesktop.IBus.Engine";
export const IBUS_SERVICE_PATH = "/org/freedesktop/IBus/ASR";
export const IBUS_SERVICE_IFACE = "org.freedesktop.IBus.ASR";
export const IBUS_COMPONENT_NAME = "asr.xml";

export const getIbusComponentXml = (): string => `<?xml version="1.0" encoding="utf-8"?>
<component>
 <name>${IBUS_BUS_NAME}</name>
 <description>ASR IBus Engine</description>
 <exec>asr</exec>
 <version>0.1.0</version>
 <author>_</author>
 <license>MIT</license>
 <homepage>https://example.invalid/asr</homepage>
 <textdomain>asr</textdomain>
 <engines>
 <engine>
 <name>${IBUS_ENGINE_NAME}</name>
 <longname>ZH</longname>
 <language>zh</language>
 <license>MIT</license>
 <author>_</author>
 <icon></icon>
 <layout>us</layout>
 <symbol>asr</symbol>
 <description>Commit ASR text through IBus</description>
 <setup></setup>
 <rank>80</rank>
 </engine>
 </engines>
</component>
`;

export const getIbusEnginesXml = (): string => `<?xml version="1.0" encoding="utf-8"?>
<engines>
 <engine>
 <name>${IBUS_ENGINE_NAME}</name>
 <longname>ZH</longname>
 <language>zh</language>
 <license>MIT</license>
 <author>_</author>
 <icon></icon>
 <layout>us</layout>
 <symbol>asr</symbol>
 <description>Commit ASR text through IBus</description>
 <setup></setup>
 <rank>80</rank>
 </engine>
</engines>
`;

export const IBUS_COMPONENT_XML = getIbusComponentXml();
export const IBUS_XML = IBUS_COMPONENT_XML;
