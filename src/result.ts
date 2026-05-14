// Rust-style Result. The tag, not the value type, distinguishes success from failure.

export interface Ok<T> {
    readonly ok: true;
    readonly value: T;
}

export interface Err {
    readonly ok: false;
    readonly error: Error;
}

export type Result<T> = Ok<T> | Err;

type LooseThenable<T> = {
    then: (resolve: (value: T) => unknown, reject?: (reason: unknown) => unknown) => unknown;
};

const toError = (error: unknown): Error => {
    if (error instanceof Error) return error;
    return new Error(typeof error === "string" ? error : String(error));
};

export const ok = <T>(value: T): Ok<T> => ({ ok: true, value });

export const err = (error: unknown): Err => ({ ok: false, error: toError(error) });

export const isOk = <T>(result: Result<T>): result is Ok<T> => result.ok;

export const isErr = <T>(result: Result<T>): result is Err => !result.ok;

export const trySyncResult = <T>(fn: () => T): Result<T> => {
    try {
        return ok(fn());
    } catch (error) {
        return err(error);
    }
};

export const tryAsyncResult = async <T>(fn: () => LooseThenable<T>): Promise<Result<T>> => {
    try {
        return ok(await Promise.resolve(fn()));
    } catch (error) {
        return err(error);
    }
};
