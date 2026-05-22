const std = @import("std");

pub const gio_library_name = "libgio-2.0.so.0";
pub const glib_library_name = "libglib-2.0.so.0";
pub const gobject_library_name = "libgobject-2.0.so.0";

pub const dbus_service_name = "org.freedesktop.DBus";
pub const dbus_object_path = "/org/freedesktop/DBus";
pub const dbus_interface_name = "org.freedesktop.DBus";
pub const dbus_request_name_method = "RequestName";
pub const dbus_request_name_flag_do_not_queue: u32 = 4;
pub const dbus_request_name_reply_primary_owner: u32 = 1;
pub const dbus_request_name_reply_already_owner: u32 = 4;

pub const Connection = *anyopaque;
pub const Variant = *anyopaque;
pub const NodeInfo = *anyopaque;
pub const InterfaceInfo = *anyopaque;
pub const MethodInvocation = *anyopaque;

pub const Error = error{
    LibraryOpenFailed,
    MissingSymbol,
    NullResult,
    InvalidUtf8,
    MissingChild,
    DBusCallFailed,
    DBusRegisterFailed,
    BusNameRequestFailed,
    UnsupportedMethod,
};

pub const MethodHandler = *const fn (
    ctx: *anyopaque,
    method_name: []const u8,
    parameters: Variant,
) anyerror!?Variant;

const GError = extern struct {
    domain: u32,
    code: i32,
    message: [*c]u8,
};

const DBusInterfaceVTable = extern struct {
    method_call: ?*const fn (
        connection: Connection,
        sender: ?[*:0]const u8,
        object_path: [*:0]const u8,
        interface_name: ?[*:0]const u8,
        method_name: [*:0]const u8,
        parameters: Variant,
        invocation: MethodInvocation,
        user_data: ?*anyopaque,
    ) callconv(.c) void,
    get_property: ?*const anyopaque = null,
    set_property: ?*const anyopaque = null,
};

const RegistrationState = struct {
    handler_ctx: *anyopaque,
    handler: MethodHandler,
};

pub const Registration = struct {
    id: u32,
    node_info: NodeInfo,
    state: *RegistrationState,
};

pub const Symbols = struct {
    g_dbus_connection_new_for_address_sync: *const fn (
        address: [*:0]const u8,
        flags: u32,
        observer: ?*anyopaque,
        cancellable: ?*anyopaque,
        err: *?*GError,
    ) callconv(.c) ?Connection,
    g_dbus_connection_call_sync: *const fn (
        connection: Connection,
        bus_name: [*:0]const u8,
        object_path: [*:0]const u8,
        interface_name: [*:0]const u8,
        method_name: [*:0]const u8,
        parameters: ?Variant,
        reply_type: ?*anyopaque,
        flags: u32,
        timeout_msec: i32,
        cancellable: ?*anyopaque,
        err: *?*GError,
    ) callconv(.c) ?Variant,
    g_dbus_connection_emit_signal: *const fn (
        connection: Connection,
        destination_bus_name: ?[*:0]const u8,
        object_path: [*:0]const u8,
        interface_name: [*:0]const u8,
        signal_name: [*:0]const u8,
        parameters: ?Variant,
        err: *?*GError,
    ) callconv(.c) c_int,
    g_dbus_connection_flush_sync: *const fn (
        connection: Connection,
        cancellable: ?*anyopaque,
        err: *?*GError,
    ) callconv(.c) c_int,
    g_dbus_connection_register_object: *const fn (
        connection: Connection,
        object_path: [*:0]const u8,
        interface_info: InterfaceInfo,
        vtable: *const DBusInterfaceVTable,
        user_data: ?*anyopaque,
        user_data_free_func: ?*const anyopaque,
        err: *?*GError,
    ) callconv(.c) u32,
    g_dbus_connection_unregister_object: *const fn (connection: Connection, registration_id: u32) callconv(.c) c_int,
    g_dbus_method_invocation_return_value: *const fn (invocation: MethodInvocation, parameters: ?Variant) callconv(.c) void,
    g_dbus_method_invocation_return_dbus_error: *const fn (
        invocation: MethodInvocation,
        error_name: [*:0]const u8,
        error_message: [*:0]const u8,
    ) callconv(.c) void,
    g_dbus_node_info_lookup_interface: *const fn (
        info: NodeInfo,
        name: [*:0]const u8,
    ) callconv(.c) ?InterfaceInfo,
    g_dbus_node_info_new_for_xml: *const fn (xml_data: [*:0]const u8, err: *?*GError) callconv(.c) ?NodeInfo,
    g_dbus_node_info_unref: *const fn (info: NodeInfo) callconv(.c) void,
    g_variant_get_child_value: *const fn (value: Variant, index_: usize) callconv(.c) ?Variant,
    g_variant_get_string: *const fn (value: Variant, length: ?*usize) callconv(.c) ?[*:0]const u8,
    g_variant_get_uint32: *const fn (value: Variant) callconv(.c) u32,
    g_variant_new_array: *const fn (
        child_type: ?*const anyopaque,
        children: ?[*]const Variant,
        n_children: usize,
    ) callconv(.c) ?Variant,
    g_variant_new_boolean: *const fn (value: c_int) callconv(.c) ?Variant,
    g_variant_new_object_path: *const fn (value: [*:0]const u8) callconv(.c) ?Variant,
    g_variant_new_string: *const fn (value: [*:0]const u8) callconv(.c) ?Variant,
    g_variant_new_tuple: *const fn (children: [*]const Variant, n_children: usize) callconv(.c) ?Variant,
    g_variant_new_uint32: *const fn (value: u32) callconv(.c) ?Variant,
    g_variant_new_variant: *const fn (value: Variant) callconv(.c) ?Variant,
    g_variant_print: *const fn (value: Variant, type_annotate: c_int) callconv(.c) ?[*:0]u8,
    g_variant_ref_sink: *const fn (value: Variant) callconv(.c) ?Variant,
    g_variant_unref: *const fn (value: Variant) callconv(.c) void,
    g_variant_type_free: *const fn (variant_type: *anyopaque) callconv(.c) void,
    g_variant_type_new: *const fn (type_string: [*:0]const u8) callconv(.c) ?*anyopaque,
    g_error_free: *const fn (err: *GError) callconv(.c) void,
    g_free: *const fn (ptr: ?*anyopaque) callconv(.c) void,
    g_main_context_iteration: *const fn (context: ?*anyopaque, may_block: c_int) callconv(.c) c_int,
    g_object_unref: *const fn (object: *anyopaque) callconv(.c) void,
};

pub const Libraries = struct {
    gio: std.DynLib,
    glib: std.DynLib,
    gobject: std.DynLib,
    symbols: Symbols,

    pub fn close(libs: *Libraries) void {
        libs.gobject.close();
        libs.glib.close();
        libs.gio.close();
    }
};

const method_vtable = DBusInterfaceVTable{
    .method_call = onMethodCall,
};

const CStringSet4 = struct {
    a: [:0]u8,
    b: [:0]u8,
    c: [:0]u8,
    d: [:0]u8,
};

pub fn loadLibraries() !Libraries {
    var gio = std.DynLib.open(gio_library_name) catch return Error.LibraryOpenFailed;
    errdefer gio.close();
    var glib = std.DynLib.open(glib_library_name) catch return Error.LibraryOpenFailed;
    errdefer glib.close();
    var gobject = std.DynLib.open(gobject_library_name) catch return Error.LibraryOpenFailed;
    errdefer gobject.close();

    return .{
        .gio = gio,
        .glib = glib,
        .gobject = gobject,
        .symbols = .{
            .g_dbus_connection_new_for_address_sync = lookup(&gio, Symbols, "g_dbus_connection_new_for_address_sync"),
            .g_dbus_connection_call_sync = lookup(&gio, Symbols, "g_dbus_connection_call_sync"),
            .g_dbus_connection_emit_signal = lookup(&gio, Symbols, "g_dbus_connection_emit_signal"),
            .g_dbus_connection_flush_sync = lookup(&gio, Symbols, "g_dbus_connection_flush_sync"),
            .g_dbus_connection_register_object = lookup(&gio, Symbols, "g_dbus_connection_register_object"),
            .g_dbus_connection_unregister_object = lookup(&gio, Symbols, "g_dbus_connection_unregister_object"),
            .g_dbus_method_invocation_return_value = lookup(&gio, Symbols, "g_dbus_method_invocation_return_value"),
            .g_dbus_method_invocation_return_dbus_error = lookup(&gio, Symbols, "g_dbus_method_invocation_return_dbus_error"),
            .g_dbus_node_info_lookup_interface = lookup(&gio, Symbols, "g_dbus_node_info_lookup_interface"),
            .g_dbus_node_info_new_for_xml = lookup(&gio, Symbols, "g_dbus_node_info_new_for_xml"),
            .g_dbus_node_info_unref = lookup(&gio, Symbols, "g_dbus_node_info_unref"),
            .g_variant_get_child_value = lookup(&glib, Symbols, "g_variant_get_child_value"),
            .g_variant_get_string = lookup(&glib, Symbols, "g_variant_get_string"),
            .g_variant_get_uint32 = lookup(&glib, Symbols, "g_variant_get_uint32"),
            .g_variant_new_array = lookup(&glib, Symbols, "g_variant_new_array"),
            .g_variant_new_boolean = lookup(&glib, Symbols, "g_variant_new_boolean"),
            .g_variant_new_object_path = lookup(&glib, Symbols, "g_variant_new_object_path"),
            .g_variant_new_string = lookup(&glib, Symbols, "g_variant_new_string"),
            .g_variant_new_tuple = lookup(&glib, Symbols, "g_variant_new_tuple"),
            .g_variant_new_uint32 = lookup(&glib, Symbols, "g_variant_new_uint32"),
            .g_variant_new_variant = lookup(&glib, Symbols, "g_variant_new_variant"),
            .g_variant_print = lookup(&glib, Symbols, "g_variant_print"),
            .g_variant_ref_sink = lookup(&glib, Symbols, "g_variant_ref_sink"),
            .g_variant_unref = lookup(&glib, Symbols, "g_variant_unref"),
            .g_variant_type_free = lookup(&glib, Symbols, "g_variant_type_free"),
            .g_variant_type_new = lookup(&glib, Symbols, "g_variant_type_new"),
            .g_error_free = lookup(&glib, Symbols, "g_error_free"),
            .g_free = lookup(&glib, Symbols, "g_free"),
            .g_main_context_iteration = lookup(&glib, Symbols, "g_main_context_iteration"),
            .g_object_unref = lookup(&gobject, Symbols, "g_object_unref"),
        },
    };
}

pub fn createConnection(libs: *const Libraries, address: []const u8) !Connection {
    return createConnectionWithLogging(libs, address, true);
}

pub fn createConnectionQuiet(libs: *const Libraries, address: []const u8) !Connection {
    return createConnectionWithLogging(libs, address, false);
}

fn createConnectionWithLogging(
    libs: *const Libraries,
    address: []const u8,
    log_errors: bool,
) !Connection {
    var err_ptr: ?*GError = null;
    const address_z = try std.heap.c_allocator.dupeZ(u8, address);
    defer std.heap.c_allocator.free(address_z);
    const connection = libs.symbols.g_dbus_connection_new_for_address_sync(
        address_z,
        1 | 8,
        null,
        null,
        &err_ptr,
    ) orelse return wrapGError(libs, err_ptr, Error.DBusCallFailed, log_errors);
    return connection;
}

pub fn createStringVariant(libs: *const Libraries, value: []const u8) !Variant {
    const value_z = try std.heap.c_allocator.dupeZ(u8, value);
    defer std.heap.c_allocator.free(value_z);
    return libs.symbols.g_variant_new_string(value_z) orelse Error.NullResult;
}

pub fn createUint32Variant(libs: *const Libraries, value: u32) !Variant {
    return libs.symbols.g_variant_new_uint32(value) orelse Error.NullResult;
}

pub fn createBooleanVariant(libs: *const Libraries, value: bool) !Variant {
    return libs.symbols.g_variant_new_boolean(if (value) 1 else 0) orelse Error.NullResult;
}

pub fn createObjectPathVariant(libs: *const Libraries, value: []const u8) !Variant {
    const value_z = try std.heap.c_allocator.dupeZ(u8, value);
    defer std.heap.c_allocator.free(value_z);
    return libs.symbols.g_variant_new_object_path(value_z) orelse Error.NullResult;
}

pub fn createVariantWrapper(libs: *const Libraries, value: Variant) !Variant {
    return libs.symbols.g_variant_new_variant(value) orelse Error.NullResult;
}

pub fn createTupleVariant(libs: *const Libraries, values: []const Variant) !Variant {
    return libs.symbols.g_variant_new_tuple(values.ptr, values.len) orelse Error.NullResult;
}

pub fn createEmptyArrayVariant(libs: *const Libraries, child_signature: []const u8) !Variant {
    const signature_z = try std.heap.c_allocator.dupeZ(u8, child_signature);
    defer std.heap.c_allocator.free(signature_z);
    const child_type = libs.symbols.g_variant_type_new(signature_z) orelse return Error.NullResult;
    defer libs.symbols.g_variant_type_free(child_type);
    return libs.symbols.g_variant_new_array(child_type, null, 0) orelse Error.NullResult;
}

pub fn createStringReturnTuple(libs: *const Libraries, value: []const u8) !Variant {
    const child = try createStringVariant(libs, value);
    return createTupleVariant(libs, &.{child});
}

pub fn createObjectPathReturnTuple(libs: *const Libraries, value: []const u8) !Variant {
    const child = try createObjectPathVariant(libs, value);
    return createTupleVariant(libs, &.{child});
}

pub fn createBooleanReturnTuple(libs: *const Libraries, value: bool) !Variant {
    const child = try createBooleanVariant(libs, value);
    return createTupleVariant(libs, &.{child});
}

pub fn createVariantReturnTuple(libs: *const Libraries, value: Variant) !Variant {
    const child = try createVariantWrapper(libs, value);
    return createTupleVariant(libs, &.{child});
}

pub fn createRequestNameParametersVariant(libs: *const Libraries, name: []const u8, flags: u32) !Variant {
    const bus_name = try createStringVariant(libs, name);
    const name_flags = try createUint32Variant(libs, flags);
    return createTupleVariant(libs, &.{ bus_name, name_flags });
}

pub fn requestBusName(
    libs: *const Libraries,
    connection: Connection,
    name: []const u8,
    timeout_ms: i32,
    flags: u32,
) !u32 {
    const parameters = try createRequestNameParametersVariant(libs, name, flags);
    var err_ptr: ?*GError = null;
    const bus_name_z = try makeCStringSet4(name, dbus_object_path, dbus_interface_name, dbus_request_name_method);
    defer freeCStringSet4(bus_name_z);
    const reply = libs.symbols.g_dbus_connection_call_sync(
        connection,
        dbus_service_name,
        bus_name_z.b,
        bus_name_z.c,
        bus_name_z.d,
        parameters,
        null,
        0,
        timeout_ms,
        null,
        &err_ptr,
    ) orelse return wrapGError(libs, err_ptr, Error.BusNameRequestFailed, true);
    defer libs.symbols.g_variant_unref(reply);
    return extractFirstUint32FromTuple(libs, reply);
}

pub fn registerObject(
    allocator: std.mem.Allocator,
    libs: *const Libraries,
    connection: Connection,
    object_path: []const u8,
    interface_name: []const u8,
    xml: []const u8,
    handler_ctx: *anyopaque,
    handler: MethodHandler,
) !Registration {
    var err_ptr: ?*GError = null;
    const xml_z = try std.heap.c_allocator.dupeZ(u8, xml);
    defer std.heap.c_allocator.free(xml_z);
    const interface_name_z = try std.heap.c_allocator.dupeZ(u8, interface_name);
    defer std.heap.c_allocator.free(interface_name_z);
    const object_path_z = try std.heap.c_allocator.dupeZ(u8, object_path);
    defer std.heap.c_allocator.free(object_path_z);
    const node_info = libs.symbols.g_dbus_node_info_new_for_xml(xml_z, &err_ptr) orelse
        return wrapGError(libs, err_ptr, Error.DBusRegisterFailed, true);
    errdefer libs.symbols.g_dbus_node_info_unref(node_info);

    const interface_info = libs.symbols.g_dbus_node_info_lookup_interface(node_info, interface_name_z) orelse
        return Error.DBusRegisterFailed;
    const state = try allocator.create(RegistrationState);
    errdefer allocator.destroy(state);
    state.* = .{
        .handler_ctx = handler_ctx,
        .handler = handler,
    };

    const registration_id = libs.symbols.g_dbus_connection_register_object(
        connection,
        object_path_z,
        interface_info,
        &method_vtable,
        state,
        null,
        &err_ptr,
    );
    if (registration_id == 0) {
        allocator.destroy(state);
        return wrapGError(libs, err_ptr, Error.DBusRegisterFailed, true);
    }

    return .{
        .id = registration_id,
        .node_info = node_info,
        .state = state,
    };
}

pub fn unregisterObject(
    allocator: std.mem.Allocator,
    libs: *const Libraries,
    connection: Connection,
    registration: *Registration,
) void {
    _ = libs.symbols.g_dbus_connection_unregister_object(connection, registration.id);
    libs.symbols.g_dbus_node_info_unref(registration.node_info);
    allocator.destroy(registration.state);
}

pub fn extractFirstStringFromTuple(
    allocator: std.mem.Allocator,
    libs: *const Libraries,
    tuple: Variant,
) ![]const u8 {
    const child = libs.symbols.g_variant_get_child_value(tuple, 0) orelse return Error.MissingChild;
    defer libs.symbols.g_variant_unref(child);
    return variantToOwnedString(allocator, libs, child);
}

pub fn extractFirstUint32FromTuple(libs: *const Libraries, tuple: Variant) !u32 {
    const child = libs.symbols.g_variant_get_child_value(tuple, 0) orelse return Error.MissingChild;
    defer libs.symbols.g_variant_unref(child);
    return libs.symbols.g_variant_get_uint32(child);
}

pub fn variantToOwnedString(
    allocator: std.mem.Allocator,
    libs: *const Libraries,
    value: Variant,
) ![]const u8 {
    const c_value = libs.symbols.g_variant_get_string(value, null) orelse return Error.NullResult;
    return allocator.dupe(u8, std.mem.span(c_value));
}

pub fn printVariant(
    allocator: std.mem.Allocator,
    libs: *const Libraries,
    value: Variant,
) ![]const u8 {
    const raw = libs.symbols.g_variant_print(value, 1) orelse return Error.NullResult;
    defer libs.symbols.g_free(raw);
    return allocator.dupe(u8, std.mem.span(raw));
}

pub fn refSink(libs: *const Libraries, value: Variant) !Variant {
    return libs.symbols.g_variant_ref_sink(value) orelse Error.NullResult;
}

pub fn unrefVariant(libs: *const Libraries, value: Variant) void {
    libs.symbols.g_variant_unref(value);
}

pub fn emitSignal(
    libs: *const Libraries,
    connection: Connection,
    object_path: []const u8,
    interface_name: []const u8,
    signal_name: []const u8,
    parameters: Variant,
) !void {
    var err_ptr: ?*GError = null;
    const names = try makeCStringSet4(object_path, interface_name, signal_name, "");
    defer freeCStringSet4(names);
    const sent = libs.symbols.g_dbus_connection_emit_signal(
        connection,
        null,
        names.a,
        names.b,
        names.c,
        parameters,
        &err_ptr,
    );
    if (sent == 0) return wrapGError(libs, err_ptr, Error.DBusCallFailed, true);
}

pub fn flushConnection(libs: *const Libraries, connection: Connection) !void {
    var err_ptr: ?*GError = null;
    const ok = libs.symbols.g_dbus_connection_flush_sync(connection, null, &err_ptr);
    if (ok == 0) return wrapGError(libs, err_ptr, Error.DBusCallFailed, true);
}

pub fn iterateMainContext(libs: *const Libraries) void {
    _ = libs.symbols.g_main_context_iteration(null, 0);
}

pub fn isBusNameReplyOwned(reply: u32) bool {
    return reply == dbus_request_name_reply_primary_owner or reply == dbus_request_name_reply_already_owner;
}

pub fn makeEnginePath(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    id: usize,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}", .{ prefix, id });
}

fn lookup(
    lib: *std.DynLib,
    comptime Namespace: type,
    comptime name: [:0]const u8,
) @FieldType(Namespace, name[0..name.len]) {
    return lib.lookup(@FieldType(Namespace, name[0..name.len]), name) orelse @panic("missing dynamic symbol");
}

fn onMethodCall(
    _: Connection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    method_name: [*:0]const u8,
    parameters: Variant,
    invocation: MethodInvocation,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state = @as(*RegistrationState, @ptrCast(@alignCast(user_data orelse return)));
    const method = std.mem.span(method_name);
    const reply = state.handler(state.handler_ctx, method, parameters) catch |err| {
        returnError(invocation, "org.freedesktop.DBus.Error.Failed", @errorName(err));
        return;
    };
    if (reply) |value| {
        global_libs.?.symbols.g_dbus_method_invocation_return_value(invocation, value);
        return;
    }
    global_libs.?.symbols.g_dbus_method_invocation_return_value(invocation, null);
}

fn returnError(invocation: MethodInvocation, error_name: []const u8, message: []const u8) void {
    const libs = global_libs orelse return;
    libs.symbols.g_dbus_method_invocation_return_dbus_error(
        invocation,
        std.fmt.bufPrintZ(&error_name_buffer, "{s}", .{error_name}) catch return,
        std.fmt.bufPrintZ(&error_message_buffer, "{s}", .{message}) catch return,
    );
}

threadlocal var error_name_buffer: [256]u8 = undefined;
threadlocal var error_message_buffer: [1024]u8 = undefined;
threadlocal var global_libs: ?*const Libraries = null;

pub fn installThreadLocalLibraries(libs: *const Libraries) void {
    global_libs = libs;
}

pub fn threadLocalLibraries() ?*const Libraries {
    return global_libs;
}

fn wrapGError(
    libs: *const Libraries,
    err_ptr: ?*GError,
    fallback: anyerror,
    log_errors: bool,
) anyerror {
    if (err_ptr) |err_value| {
        defer libs.symbols.g_error_free(err_value);
        if (log_errors) std.log.err("{s}", .{std.mem.span(err_value.message)});
    }
    return fallback;
}

fn makeCStringSet4(a: []const u8, b: []const u8, c: []const u8, d: []const u8) !CStringSet4 {
    return .{
        .a = try std.heap.c_allocator.dupeZ(u8, a),
        .b = try std.heap.c_allocator.dupeZ(u8, b),
        .c = try std.heap.c_allocator.dupeZ(u8, c),
        .d = try std.heap.c_allocator.dupeZ(u8, d),
    };
}

fn freeCStringSet4(set: CStringSet4) void {
    std.heap.c_allocator.free(set.a);
    std.heap.c_allocator.free(set.b);
    std.heap.c_allocator.free(set.c);
    std.heap.c_allocator.free(set.d);
}

test "gio dbus helpers are exposed" {
    try std.testing.expect(isBusNameReplyOwned(1));
    try std.testing.expect(isBusNameReplyOwned(4));
    try std.testing.expect(!isBusNameReplyOwned(2));
    const path = try makeEnginePath(std.testing.allocator, "/org/freedesktop/IBus/Engine/ASR", 7);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/org/freedesktop/IBus/Engine/ASR/7", path);
}
