// Re-export Result types and helpers from result.ts
import { ok, err, tryResult, isOk, isErr, type Result } from "./result.ts";

export { ok, err, tryResult, isOk, isErr, type Result };

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

    if (!proc.success) {
        return err(new Error(`${command} ${args.join(" ")} exited with ${proc.exitCode}`));
    }

    return ok({
        exitCode: proc.exitCode,
        stdout,
        stderr,
    });
};
