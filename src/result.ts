// Go 风格 Result 元组: [data, error]
// 成功时 error 为 null; 失败时 data 为 null, error 非 null.
export type Result<T> = [T, Error | null];

// 构造成功 Result
export const ok = <T>(value: T): Result<T> => [value, null];

export const err = (error: Error): Result<never> => [null as never, error];

export const isOk = (result: Result<unknown>): result is [unknown, null] => result[1] === null;

export const isErr = (result: Result<unknown>): result is [null, Error] => result[1] !== null;

export const tryResult = async <T>(input: () => T | Promise<T>): Promise<Result<T>> => {
    try {
        const result = input();
        if (result instanceof Promise) {
            return result.then(ok).catch((e) => err(e instanceof Error ? e : new Error(String(e))));
        }
        return ok(result as T);
    } catch (e) {
        return err(e instanceof Error ? e : new Error(String(e)));
    }
};
