import { isErr } from "../util.ts";
import { callIbusServiceStringMethod } from "./ibus-rpc.ts";

interface IbusRpcWorkerRequest {
    methodName: string;
    args: string[];
}

type IbusRpcWorkerResponse =
    | { ok: true; value: string }
    | { ok: false; message: string };

interface IbusRpcWorkerGlobal {
    onmessage: ((event: MessageEvent<IbusRpcWorkerRequest>) => void) | null;
    postMessage: (message: IbusRpcWorkerResponse) => void;
}

const worker = globalThis as unknown as IbusRpcWorkerGlobal;

worker.onmessage = (event: MessageEvent<IbusRpcWorkerRequest>): void => {
    void (async () => {
        const result = await callIbusServiceStringMethod(event.data.methodName, event.data.args);
        if (isErr(result)) {
            worker.postMessage({ ok: false, message: result.error.message });
            return;
        }

        worker.postMessage({ ok: true, value: result.value });
    })();
};
