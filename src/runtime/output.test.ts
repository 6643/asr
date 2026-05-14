import { expect, mock, test } from "bun:test";

test("key press feedback is concise", async () => {
    const lines: string[] = [];
    const log = mock((line: string) => {
        lines.push(line);
    });
    const originalLog = console.log;
    console.log = log;

    try {
        const { printKeyboardEvent, printKeyboardWait } = await import("./output.ts");
        printKeyboardWait("down", "RightAlt");
        printKeyboardEvent("press");
        printKeyboardEvent("release");
    } finally {
        console.log = originalLog;
    }

    expect(log).toHaveBeenCalledTimes(3);
    expect(lines[0]).toContain("[kbd] wait down RightAlt");
    expect(lines[1]).toContain("[kbd] down RightAlt");
    expect(lines[2]).toContain("[kbd] up RightAlt");
});

test("doubao events are tagged", async () => {
    const lines: string[] = [];
    const log = mock((line: string) => {
        lines.push(line);
    });
    const originalLog = console.log;
    console.log = log;

    try {
        const { printSessionStart, printInterim, printFinal } = await import("./output.ts");
        printSessionStart();
        printInterim("语音识别");
        printFinal("语音识别测试。");
    } finally {
        console.log = originalLog;
    }

    expect(log).toHaveBeenCalledTimes(3);
    expect(lines[0]).toContain("[doubao] 🎤");
    expect(lines[1]).toContain("[doubao] 🎤 语音识别");
    expect(lines[2]).toContain("[doubao] 🚀 语音识别测试。");
});
