import { createConfig, ensureCredentials, getSessionConfig } from "../src/engines/doubao/config.ts";
import { isErr } from "../src/util.ts";

const config = createConfig();
const prepareResult = await ensureCredentials(config);
if (isErr(prepareResult)) {
    console.error("准备失败:", prepareResult.error.message);
    process.exit(1);
}

const sessionConfigResult = getSessionConfig(config);
if (isErr(sessionConfigResult)) {
    console.error("获取配置失败:", sessionConfigResult.error.message);
    process.exit(1);
}

console.log("会话配置:");
console.log(JSON.stringify(sessionConfigResult.value, null, 2));
