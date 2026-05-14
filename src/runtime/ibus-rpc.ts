import { err, isErr, ok, type Result } from "../util.ts";
import { callGioDbusStringMethod } from "./gio-dbus.ts";
import { resolveIbusAddress } from "./ibus-address.ts";
import {
    IBUS_BUS_NAME,
    IBUS_SERVICE_IFACE,
    IBUS_SERVICE_PATH,
} from "./ibus-meta.ts";

export const callIbusServiceStringMethod = async (
    methodName: string,
    args: string[] = [],
): Promise<Result<string>> => {
    const addressResult = await resolveIbusAddress();
    if (isErr(addressResult)) return err(addressResult.error);

    const result = callGioDbusStringMethod(
        addressResult.value,
        IBUS_BUS_NAME,
        IBUS_SERVICE_PATH,
        IBUS_SERVICE_IFACE,
        methodName,
        args,
    );
    if (isErr(result)) return err(new Error(`Failed to call IBus DBus service: ${result.error.message}`));

    return ok(result.value);
};
