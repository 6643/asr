import { err, ok, type Result } from "../util.ts";

interface IbusRpcWorkerRequest {
    methodName: string;
    args: string[];
}

type IbusRpcWorkerResponse =
    | { ok: true; value: string }
    | { ok: false; message: string };

const createIbusRpcWorker = (): Worker => {
    return new Worker(new URL("./ibus-rpc-worker.ts", import.meta.url).href, { type: "module" });
};

const isIbusRpcWorkerResponse = (value: unknown): value is IbusRpcWorkerResponse => {
    if (!value || typeof value !== "object") return false;
    if (!("ok" in value)) return false;
    const response = value as Partial<IbusRpcWorkerResponse>;
    return response.ok === true || response.ok === false;
};

export const callIbusServiceStringMethodInWorker = (
    methodName: string,
    args: string[] = [],
    timeoutMs = 1500,
): Promise<Result<string>> => {
    const request: IbusRpcWorkerRequest = { methodName, args };
    const worker = createIbusRpcWorker();

    return new Promise<Result<string>>((resolve) => {
        let settled = false;
        let timer: ReturnType<typeof setTimeout> | null = null;

        const finish = (result: Result<string>): void => {
            if (settled) return;
            settled = true;
            if (timer) clearTimeout(timer);
            worker.terminate();
            resolve(result);
        };

        timer = setTimeout(() => {
            finish(err(new Error("ERR timeout")));
        }, timeoutMs);

        worker.addEventListener(
            "message",
            (event: MessageEvent<unknown>) => {
                const response = event.data;
                if (!isIbusRpcWorkerResponse(response)) {
                    finish(err(new Error("ERR invalid_worker_response")));
                    return;
                }

                finish(response.ok ? ok(response.value) : err(new Error(response.message)));
            },
            { once: true },
        );

        worker.addEventListener(
            "error",
            (event) => {
                finish(err(new Error(`ERR worker_error ${event.message}`)));
            },
            { once: true },
        );

        worker.postMessage(request);
    });
};
