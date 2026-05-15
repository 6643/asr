import { createDoubaoEngine } from "../src/engines/doubao/index.ts";
import { createMicStream } from "../src/runtime/mic.ts";
import { isErr } from "../src/util.ts";

const engine = createDoubaoEngine();
const client = engine.createClient();

console.log("准备引擎...");
const prepareResult = await engine.prepare(client);
if (isErr(prepareResult)) {
    console.error("准备失败:", prepareResult.error.message);
    process.exit(1);
}

console.log("引擎信息:");
for (const line of engine.describe(client)) {
    console.log(line);
}

console.log("\n开始识别会话...");
const sessionResult = await engine.startSession(client, { debugEnabled: true });
if (isErr(sessionResult)) {
    console.error("会话启动失败:", sessionResult.error.message);
    process.exit(1);
}

const session = sessionResult.value;

console.log("开始录音 5 秒...");
const abort = new AbortController();
setTimeout(() => {
    console.log("停止录音...");
    abort.abort();
}, 5000);

const micStream = await createMicStream({ signal: abort.signal });

const pushTask = (async () => {
    for await (const chunk of micStream) {
        const pushResult = await session.pushAudio(chunk);
        if (isErr(pushResult)) {
            console.error("推送音频失败:", pushResult.error.message);
            break;
        }
    }
    await session.close();
    console.log("音频推送完成");
})();

console.log("\n处理识别结果...");
for await (const eventResult of session.events) {
    if (isErr(eventResult)) {
        console.error("错误:", eventResult.error.message);
        continue;
    }

    const evt = eventResult.value;
    if (evt.type === "interim" || evt.type === "final") {
        console.log(`${evt.type}: "${evt.text}"`);
    } else {
        console.log(`事件: ${evt.type}`);
    }
}

await pushTask;
console.log("\n识别完成");
