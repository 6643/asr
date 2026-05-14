// Re-export Result types and helpers from result.ts
import { ok, err, tryAsyncResult, trySyncResult, isOk, isErr, type Result } from "./result.ts";

export { ok, err, tryAsyncResult, trySyncResult, isOk, isErr, type Result };

export const ignoreError = (fn: () => void): void => {
    try {
        fn();
    } catch {
        // ignore cleanup errors
    }
};

export const withFinally = <T>(run: () => T, cleanup: () => void): T => {
    try {
        return run();
    } finally {
        cleanup();
    }
};

export const withFinallyAsync = async <T>(
    run: () => Promise<T>,
    cleanup: () => Promise<void> | void,
): Promise<T> => {
    try {
        return await run();
    } finally {
        await cleanup();
    }
};

// 通用异步队列
export const createAsyncQueue = <T>(maxItems = Infinity) => {
    const items: T[] = [];
    let closed = false;
    let wake: (() => void) | null = null;

    const push = (value: T): boolean => {
        if (closed) return false;
        if (items.length >= maxItems) return false;
        items.push(value);
        wake?.();
        wake = null;
        return true;
    };

    const close = (): void => {
        closed = true;
        wake?.();
        wake = null;
    };

    const waitForItem = async (): Promise<void> => {
        await new Promise<void>((resolve) => {
            wake = resolve;
        });
    };

    const readNext = async (): Promise<IteratorResult<T>> => {
        if (items.length > 0) return { done: false, value: items.shift() as T };
        if (closed) return { done: true, value: undefined };
        await waitForItem();
        return readNext();
    };

    const createIterator = async function* (): AsyncGenerator<T> {
        const next = await readNext();
        if (next.done) return;
        yield next.value;
        yield* createIterator();
    };

    const iterator = createIterator();

    return {
        push,
        close,
        iterator,
        get length() {
            return items.length;
        },
        get isClosed() {
            return closed;
        },
    };
};

export interface RunCommandOptions {
    timeoutMs?: number;
    stdin?: string;
    env?: Record<string, string>;
}

export interface RunCommandResult {
    exitCode: number;
    stdout: string;
    stderr: string;
}

export const runCommand = (command: string, args: string[] = [], options: RunCommandOptions = {}): Result<RunCommandResult> => {
    const resolvedCommand = Bun.which(command);
    if (!resolvedCommand) {
        return err(new Error(`Command not found: ${command}`));
    }

    const env = options.env ? { ...process.env, ...options.env } : process.env;

    const proc = Bun.spawnSync({
        cmd: [resolvedCommand, ...args],
        stdin: options.stdin ? new TextEncoder().encode(options.stdin) : "inherit",
        stdout: "pipe",
        stderr: "pipe",
        env,
        timeout: options.timeoutMs,
    });
    const stdout = new TextDecoder().decode(proc.stdout);
    const stderr = new TextDecoder().decode(proc.stderr);

    if (!proc.success) return err(createRunCommandError(command, args, options, proc.exitCode));

    return ok({
        exitCode: proc.exitCode,
        stdout,
        stderr,
    });
};

const createRunCommandError = (
    command: string,
    args: string[],
    options: RunCommandOptions,
    exitCode: number | null,
): Error => {
    if (exitCode === null && options.timeoutMs !== undefined) {
        return new Error(`${command} ${args.join(" ")} timed out after ${options.timeoutMs}ms`);
    }
    return new Error(`${command} ${args.join(" ")} exited with ${exitCode}`);
};

// Uint8Array <-> base64 helpers (Bun-compatible, avoids Node.js Buffer)
export const uint8ArrayToBase64 = (arr: Uint8Array): string => {
    return Buffer.from(arr).toString('base64');
};

export const base64ToUint8Array = (b64: string): Uint8Array => {
    return new Uint8Array(Buffer.from(b64, 'base64'));
};
