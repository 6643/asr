# Shared Util + Doubao Types Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep `Result` and command execution helpers shared in `src/util.ts`, move all Doubao-specific types under `src/doubao/`, and update imports so the project boundary matches the actual architecture.

**Architecture:** `src/util.ts` becomes the shared helper module for `Result` and Bun-first command execution. All ASR protocol, response, session, and credential types move into `src/doubao/types.ts`. General runtime helpers stay in `src/`, while Doubao-specific audio, client, config, wave, proto, and device code stays in `src/doubao/`.

**Tech Stack:** Bun, TypeScript, `dbus-next`.

---

### Task 1: Split shared util helpers from Doubao domain types

**Files:**
- Create: `src/doubao/types.ts`
- Create: `src/util.ts`
- Modify: `src/result.ts`

- [ ] **Step 1: Move Doubao-only types into `src/doubao/types.ts`**

Create `src/doubao/types.ts` with the ASR domain types currently mixed into `src/result.ts`:

```ts
export enum ResponseType {
  TASK_STARTED = "TASK_STARTED",
  SESSION_STARTED = "SESSION_STARTED",
  SESSION_FINISHED = "SESSION_FINISHED",
  VAD_START = "VAD_START",
  INTERIM_RESULT = "INTERIM_RESULT",
  FINAL_RESULT = "FINAL_RESULT",
  HEARTBEAT = "HEARTBEAT",
  ERROR = "ERROR",
  UNKNOWN = "UNKNOWN",
}

export enum FrameState {
  FRAME_STATE_UNSPECIFIED = 0,
  FRAME_STATE_FIRST = 1,
  FRAME_STATE_MIDDLE = 3,
  FRAME_STATE_LAST = 9,
}

export interface AudioInfo {
  channel: number;
  format: string;
  sample_rate: number;
}

export interface SessionExtraConfig {
  app_name: string;
  cell_compress_rate: number;
  did: string;
  enable_asr_threepass: boolean;
  enable_asr_twopass: boolean;
  input_mode: string;
}

export interface SessionConfig {
  audio_info: AudioInfo;
  enable_punctuation: boolean;
  enable_speech_rejection: boolean;
  extra: SessionExtraConfig;
}

export type AudioChunk = Uint8Array;

export interface ASRWord {
  word: string;
  start_time: number;
  end_time: number;
}

export interface OIDecodingInfo {
  oi_former_word_num: number;
  oi_latter_word_num: number;
  oi_words: unknown[] | null;
}

export interface ASRAlternative {
  text: string;
  start_time: number;
  end_time: number;
  words: ASRWord[];
  semantic_related_to_prev: boolean | null;
  oi_decoding_info: OIDecodingInfo | null;
}

export interface ASRResult {
  text: string;
  start_time: number;
  end_time: number;
  confidence: number;
  alternatives: ASRAlternative[];
  is_interim: boolean;
  is_vad_finished: boolean;
  index: number;
}

export interface ASRExtra {
  audio_duration: number | null;
  model_avg_rtf: number | null;
  model_send_first_response: number | null;
  speech_adaptation_version: string | null;
  model_total_process_time: number | null;
  packet_number: number | null;
  vad_start: boolean | null;
  req_payload: Record<string, unknown> | null;
}

export interface ASRResponse {
  type: ResponseType;
  text?: string;
  is_final?: boolean;
  vad_start?: boolean;
  vad_finished?: boolean;
  packet_number?: number;
  error_msg?: string;
  raw_json?: Record<string, unknown> | null;
  results?: ASRResult[];
  extra?: ASRExtra | null;
}

export interface DeviceCredentials {
  device_id: string | null;
  install_id: string | null;
  cdid: string | null;
  openudid: string | null;
  clientudid: string | null;
  token: string;
  sami_token: string | null;
  wave_session: Record<string, unknown> | null;
}

export interface WaveSession {
  ticket: string;
  ticket_long: string;
  encryption_key: Uint8Array;
  client_random: Uint8Array;
  server_random: Uint8Array;
  shared_key: Uint8Array;
  ticket_exp: number;
  ticket_long_exp: number;
  expires_at: number;
}
```

- [ ] **Step 2: Replace `src/result.ts` with a compatibility re-export**

Keep `src/result.ts` as a thin compatibility shim so any old imports still work during the refactor:

```ts
export * from "./util.ts";
```

- [ ] **Step 3: Add `src/util.ts` as the shared helper module**

Create `src/util.ts` with the shared result wrapper and command helper:

```ts
export type Ok<T> = { readonly ok: true; readonly value: T };
export type Err<E> = { readonly ok: false; readonly error: E };

export type Result<T, E = Error> = Ok<T> | Err<E>;

export const ok = <T>(value: T): Result<T> => ({ ok: true, value });
export const err = <E = Error>(error: E): Result<never, E> => ({ ok: false, error });

export const toResult = <T, E = Error>(input: Promise<T> | (() => T)) => {
  const handleError = (e: unknown): Result<T, E> =>
    err(e instanceof Error ? e : new Error(String(e))) as Result<T, E>;

  if (typeof input === "function") {
    try {
      return ok((input as () => T)()) as Result<T, E>;
    } catch (e) {
      return handleError(e);
    }
  }

  return (input as Promise<T>)
    .then((value) => ok(value) as Result<T, E>)
    .catch(handleError);
};

export interface RunCommandOptions {
  timeoutMs?: number;
  stdin?: string;
}

export interface RunCommandResult {
  success: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
}

export const runCommand = async (
  command: string,
  args: string[] = [],
  options: RunCommandOptions = {},
): Promise<Result<RunCommandResult>> => {
  try {
    const proc = Bun.spawn([command, ...args], {
      stdin: options.stdin ? "pipe" : "inherit",
      stdout: "pipe",
      stderr: "pipe",
    });

    if (options.stdin) {
      const writer = proc.stdin?.getWriter();
      if (writer) {
        await writer.write(new TextEncoder().encode(options.stdin));
        await writer.close();
      }
    }

    const timer = options.timeoutMs ? setTimeout(() => proc.kill(), options.timeoutMs) : null;
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);

    if (timer) clearTimeout(timer);

    return ok({ success: exitCode === 0, exitCode, stdout, stderr });
  } catch (error) {
    return err(error instanceof Error ? error : new Error(String(error)));
  }
};
```

- [ ] **Step 4: Update ASR imports to use the new split**

Update every ASR module to import shared helpers from `../util.ts` and ASR types from `./types.ts`:

```ts
// src/doubao/client.ts
import { ok, err, toResult, type Result } from "../util.ts";
import { ResponseType, FrameState, type ASRResponse, type SessionConfig } from "./types.ts";

// src/doubao/config.ts
import type { WaveSession, SessionConfig, DeviceCredentials, Result } from "./types.ts";
import { ok, err, toResult } from "../util.ts";

// src/doubao/device.ts
import type { DeviceCredentials } from "./types.ts";

// src/doubao/wave.ts
import type { WaveSession } from "./types.ts";

// src/doubao/proto.ts
import { FrameState, ResponseType, ok, err, toResult, type ASRResponse, type SessionConfig, type Result } from "./types.ts";

// src/doubao/audio.ts
import type { Config } from "./config.ts";

// src/doubao/sami.ts
import { ... } from "./constants.ts";
```

### Task 2: Restore shared command wrapper and remove ad hoc shell layers

**Files:**
- Create: `src/run.ts`
- Modify: `src/commit.ts`
- Modify: `src/ibus.ts`
- Modify: `src/mic.ts`
- Modify: `src/mute.ts`
- Modify: `src/doubao/*` only if they still import the old path

- [ ] **Step 1: Add a Bun-first `runCommand` helper**

Create `src/run.ts` with a Bun-based command wrapper that returns `Result` and avoids `execFileSync`:

```ts
import { err, ok, type Result } from "./result.ts";

export interface RunCommandOptions {
  timeoutMs?: number;
  stdin?: string;
}

export interface RunCommandResult {
  success: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
}

export const runCommand = async (
  command: string,
  args: string[] = [],
  options: RunCommandOptions = {},
): Promise<Result<RunCommandResult>> => {
  try {
    const proc = Bun.spawn([command, ...args], {
      stdin: options.stdin ? "pipe" : "inherit",
      stdout: "pipe",
      stderr: "pipe",
    });

    if (options.stdin) {
      const writer = proc.stdin?.getWriter();
      if (writer) {
        await writer.write(new TextEncoder().encode(options.stdin));
        writer.close();
      }
    }

    const timer = options.timeoutMs
      ? setTimeout(() => proc.kill(), options.timeoutMs)
      : null;

    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);

    if (timer) clearTimeout(timer);

    return ok({ success: exitCode === 0, exitCode, stdout, stderr });
  } catch (error) {
    return err(error instanceof Error ? error : new Error(String(error)));
  }
};
```

- [ ] **Step 2: Point callers at the shared helper**

Update `src/commit.ts`, `src/ibus.ts`, `src/mute.ts` to import `runCommand` from `./run.ts` and use `Result` from `./result.ts`.

- [ ] **Step 3: Keep the public behavior unchanged**

Do not reintroduce clipboard or ydotool fallback. Keep `wpctl` only for mute control and keep IBus installation behavior intact.

### Task 3: Normalize imports and arrow functions in the touched modules

**Files:**
- Modify: `index.ts`
- Modify: `src/commit.ts`
- Modify: `src/ibus.ts`
- Modify: `src/key.ts`
- Modify: `src/mic.ts`
- Modify: `src/mute.ts`
- Modify: `src/doubao/client.ts`
- Modify: `src/doubao/config.ts`
- Modify: `src/doubao/device.ts`
- Modify: `src/doubao/wave.ts`
- Modify: `src/doubao/proto.ts`
- Modify: `src/doubao/audio.ts`
- Modify: `src/doubao/sami.ts`

- [ ] **Step 1: Update `index.ts` imports to the final split**

Use `src/doubao/*` only for Doubao ASR logic, and root `src/*` for `IBus`, `key`, `mic`, `mute`, `commit`, `run`, and `result`.

- [ ] **Step 2: Convert modified named functions to arrow functions**

Apply arrow function style to functions already touched in the split, especially helpers in `src/result.ts`, `src/run.ts`, `src/commit.ts`, `src/ibus.ts`, `src/key.ts`, `src/mic.ts`, and `src/mute.ts`.

- [ ] **Step 3: Keep the ASR protocol files inside `src/doubao/`**

Leave `client.ts`, `config.ts`, `constants.ts`, `device.ts`, `proto.ts`, `sami.ts`, `wave.ts`, `audio.ts`, and the new `types.ts` inside `src/doubao/`.

### Task 4: Verify the split with typecheck and import smoke tests

**Files:**
- Test only, no code changes

- [ ] **Step 1: Run TypeScript check**

Run:

```bash
bun tsc --noEmit
```

Expected:

```text
0 errors
```

- [ ] **Step 2: Run import smoke test**

Run:

```bash
bun --eval "await import('./index.ts'); await import('./src/result.ts'); await import('./src/run.ts'); await import('./src/doubao/client.ts'); console.log('imports-ok')"
```

Expected:

```text
imports-ok
```

- [ ] **Step 3: Verify file placement**

Run:

```bash
find src -maxdepth 2 -type f | sort
```

Expected top-level split:

```text
src/commit.ts
src/ibus.ts
src/key.ts
src/mic.ts
src/mute.ts
src/result.ts
src/run.ts
src/doubao/audio.ts
src/doubao/client.ts
src/doubao/config.ts
src/doubao/constants.ts
src/doubao/device.ts
src/doubao/proto.ts
src/doubao/sami.ts
src/doubao/types.ts
src/doubao/wave.ts
```

### Self-Review

- Shared `Result` is isolated in `src/result.ts`.
- ASR domain types are isolated in `src/doubao/types.ts`.
- All command execution flows go through `src/run.ts`.
- No clipboard or ydotool paths are reintroduced.
- The file layout matches the requested boundary: generic infra at `src/`, Doubao-only code at `src/doubao/`.
