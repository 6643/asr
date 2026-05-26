const std = @import("std");
const gio = @import("gio_dbus.zig");
const ibus_runtime = @import("ibus.zig");

pub const bus_name = "org.freedesktop.IBus.ASR";
pub const engine_name = "asr";
pub const engine_path_prefix = "/org/freedesktop/IBus/Engine/ASR";
pub const factory_path = "/org/freedesktop/IBus/Factory";
pub const factory_iface = "org.freedesktop.IBus.Factory";
pub const engine_iface = "org.freedesktop.IBus.Engine";
pub const service_path = "/org/freedesktop/IBus/ASR";
pub const service_iface = "org.freedesktop.IBus.ASR";
pub const commit_text_signal = "CommitText";

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    libs: gio.Libraries,
    connection: gio.Connection,
    registrations: std.ArrayListUnmanaged(gio.Registration),
    state: State,
    mutex: std.Io.Mutex = .init,

    pub fn stop(service: *Service) void {
        service.unregisterRegistrations();
        service.libs.symbols.g_object_unref(service.connection);
        service.libs.close();
    }

    fn unregisterRegistrations(service: *Service) void {
        var i = service.registrations.items.len;
        while (i > 0) : (i -= 1) {
            const registration = &service.registrations.items[i - 1];
            const handler_ctx = registration.state.handler_ctx;
            if (handler_ctx != @as(*anyopaque, @ptrCast(service))) {
                const engine_ctx = @as(*EngineContext, @ptrCast(@alignCast(handler_ctx)));
                service.allocator.free(engine_ctx.object_path);
                service.allocator.destroy(engine_ctx);
            }
            gio.unregisterObject(service.allocator, &service.libs, service.connection, registration);
        }
        service.registrations.deinit(service.allocator);
    }

    pub fn iterate(service: *Service) void {
        gio.installThreadLocalLibraries(&service.libs);
        gio.iterateMainContext(&service.libs);
    }

    pub fn status(service: *Service) []const u8 {
        service.mutex.lockUncancelable(service.io);
        defer service.mutex.unlock(service.io);
        return getStatus(service.state.active_engine);
    }

    pub fn commit(service: *Service, text: []const u8) !void {
        const result = service.commitStatus(text);
        if (std.mem.startsWith(u8, result, "OK ")) return;
        return error.IbusCommitFailed;
    }

    pub fn commitStatus(service: *Service, text: []const u8) []const u8 {
        return commitTextStatus(service, text);
    }
};

const EngineState = struct {
    object_path: []const u8,
    has_focus: bool = false,
    enabled: bool = false,
};

const State = struct {
    engine_id: usize = 0,
    active_engine: ?EngineState = null,
};

const EngineContext = struct {
    service: *Service,
    object_path: []const u8,
};

pub fn start(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !*Service {
    _ = environ;
    var libs = try gio.loadLibraries();
    errdefer libs.close();
    gio.installThreadLocalLibraries(&libs);
    const connection = try connectWithRetry(allocator, io, &libs);
    errdefer libs.symbols.g_object_unref(connection);

    const service = try allocator.create(Service);
    errdefer allocator.destroy(service);
    service.* = .{
        .allocator = allocator,
        .io = io,
        .libs = libs,
        .connection = connection,
        .registrations = .empty,
        .state = .{},
    };
    errdefer service.unregisterRegistrations();

    try registerFactory(service);
    try registerService(service);

    const reply = try gio.requestBusName(
        &service.libs,
        service.connection,
        bus_name,
        1500,
        gio.dbus_request_name_flag_do_not_queue,
    );
    if (!gio.isBusNameReplyOwned(reply)) return gio.Error.BusNameRequestFailed;
    return service;
}

fn connectWithRetry(allocator: std.mem.Allocator, io: std.Io, libs: *const gio.Libraries) !gio.Connection {
    var attempts: usize = 0;
    while (attempts < ibus_runtime.retry_attempts) : (attempts += 1) {
        const address = try ibus_runtime.resolveAddress(allocator, io);
        defer allocator.free(address);
        const connection = gio.createConnectionQuiet(libs, address) catch |err| {
            if (shouldRetryConnection(err) and attempts + 1 < ibus_runtime.retry_attempts) {
                sleepMs(io, ibus_runtime.retry_delay_ms);
                continue;
            }
            return err;
        };
        return connection;
    }
    return gio.Error.DBusCallFailed;
}

fn shouldRetryConnection(err: anyerror) bool {
    return err == gio.Error.DBusCallFailed;
}

pub fn getStatus(state: ?EngineState) []const u8 {
    if (state == null) return "engine_not_created";
    return "ready";
}

pub fn createFactoryXml() []const u8 {
    return
    \\<node>
    \\  <interface name="org.freedesktop.IBus.Factory">
    \\    <method name="CreateEngine"><arg type="s" name="name" direction="in"/><arg type="o" name="engine" direction="out"/></method>
    \\  </interface>
    \\</node>
    ;
}

pub fn createServiceXml() []const u8 {
    return
    \\<node>
    \\  <interface name="org.freedesktop.IBus.ASR">
    \\    <method name="CommitText"><arg type="s" name="text" direction="in"/><arg type="s" name="reply" direction="out"/></method>
    \\    <method name="GetStatus"><arg type="s" name="status" direction="out"/></method>
    \\  </interface>
    \\</node>
    ;
}

pub fn createEngineXml() []const u8 {
    return
    \\<node>
    \\  <interface name="org.freedesktop.IBus.Engine">
    \\    <method name="FocusIn"/>
    \\    <method name="FocusOut"/>
    \\    <method name="Destroy"/>
    \\    <method name="Enable"/>
    \\    <method name="Disable"/>
    \\    <method name="ProcessKeyEvent"><arg type="u" name="keyval" direction="in"/><arg type="u" name="keycode" direction="in"/><arg type="u" name="state" direction="in"/><arg type="b" name="handled" direction="out"/></method>
    \\    <method name="GetEngine"><arg type="v" name="engine" direction="out"/></method>
    \\    <signal name="CommitText"><arg type="v" name="text"/></signal>
    \\  </interface>
    \\</node>
    ;
}

fn registerFactory(service: *Service) !void {
    var registration = try gio.registerObject(
        service.allocator,
        &service.libs,
        service.connection,
        factory_path,
        factory_iface,
        createFactoryXml(),
        @ptrCast(service),
        onFactoryMethod,
    );
    errdefer gio.unregisterObject(service.allocator, &service.libs, service.connection, &registration);
    try service.registrations.append(service.allocator, registration);
}

fn registerService(service: *Service) !void {
    var registration = try gio.registerObject(
        service.allocator,
        &service.libs,
        service.connection,
        service_path,
        service_iface,
        createServiceXml(),
        @ptrCast(service),
        onServiceMethod,
    );
    errdefer gio.unregisterObject(service.allocator, &service.libs, service.connection, &registration);
    try service.registrations.append(service.allocator, registration);
}

fn registerEngine(service: *Service, path: []const u8) !void {
    const ctx = try service.allocator.create(EngineContext);
    errdefer service.allocator.destroy(ctx);
    ctx.* = .{
        .service = service,
        .object_path = path,
    };
    var registration = try gio.registerObject(
        service.allocator,
        &service.libs,
        service.connection,
        path,
        engine_iface,
        createEngineXml(),
        @ptrCast(ctx),
        onEngineMethod,
    );
    errdefer gio.unregisterObject(service.allocator, &service.libs, service.connection, &registration);
    try service.registrations.append(service.allocator, registration);
}

fn onFactoryMethod(ctx: *anyopaque, method_name: []const u8, parameters: gio.Variant) !?gio.Variant {
    const service = @as(*Service, @ptrCast(@alignCast(ctx)));
    if (!std.mem.eql(u8, method_name, "CreateEngine")) return gio.createObjectPathReturnTuple(&service.libs, "/");
    const requested_name = try gio.extractFirstStringFromTuple(service.allocator, &service.libs, parameters);
    defer service.allocator.free(requested_name);
    if (!std.mem.eql(u8, requested_name, engine_name)) return gio.createObjectPathReturnTuple(&service.libs, "/");
    service.mutex.lockUncancelable(service.io);
    const engine_id = service.state.engine_id;
    service.state.engine_id += 1;
    service.mutex.unlock(service.io);
    const engine_path = try gio.makeEnginePath(service.allocator, engine_path_prefix, engine_id);
    errdefer service.allocator.free(engine_path);
    try registerEngine(service, engine_path);
    service.mutex.lockUncancelable(service.io);
    service.state.active_engine = .{ .object_path = engine_path, .has_focus = false, .enabled = false };
    service.mutex.unlock(service.io);
    return gio.createObjectPathReturnTuple(&service.libs, engine_path);
}

fn onServiceMethod(ctx: *anyopaque, method_name: []const u8, parameters: gio.Variant) !?gio.Variant {
    const service = @as(*Service, @ptrCast(@alignCast(ctx)));
    if (std.mem.eql(u8, method_name, "GetStatus")) {
        return gio.createStringReturnTuple(&service.libs, service.status());
    }
    if (!std.mem.eql(u8, method_name, "CommitText")) {
        return gio.createStringReturnTuple(&service.libs, "ERR unsupported_method");
    }
    const text = try gio.extractFirstStringFromTuple(service.allocator, &service.libs, parameters);
    defer service.allocator.free(text);
    return gio.createStringReturnTuple(&service.libs, commitTextStatus(service, text));
}

fn onEngineMethod(ctx: *anyopaque, method_name: []const u8, _: gio.Variant) !?gio.Variant {
    const engine_ctx = @as(*EngineContext, @ptrCast(@alignCast(ctx)));
    const service = engine_ctx.service;
    service.mutex.lockUncancelable(service.io);
    defer service.mutex.unlock(service.io);
    const active_state = service.state.active_engine orelse return null;
    if (!std.mem.eql(u8, active_state.object_path, engine_ctx.object_path)) return null;
    var active = &service.state.active_engine.?;
    if (std.mem.eql(u8, method_name, "FocusIn")) {
        active.has_focus = true;
        return null;
    }
    if (std.mem.eql(u8, method_name, "FocusOut")) {
        active.has_focus = false;
        return null;
    }
    if (std.mem.eql(u8, method_name, "Enable")) {
        active.enabled = true;
        return null;
    }
    if (std.mem.eql(u8, method_name, "Disable")) {
        active.enabled = false;
        return null;
    }
    if (std.mem.eql(u8, method_name, "Destroy")) {
        active.enabled = false;
        active.has_focus = false;
        return null;
    }
    if (std.mem.eql(u8, method_name, "ProcessKeyEvent")) {
        return gio.createBooleanReturnTuple(&service.libs, false);
    }
    if (std.mem.eql(u8, method_name, "GetEngine")) {
        const desc = try createEngineDescriptionVariant(&service.libs);
        return gio.createVariantReturnTuple(&service.libs, desc);
    }
    return null;
}

fn createEngineDescriptionVariant(libs: *const gio.Libraries) !gio.Variant {
    const values = [_]gio.Variant{
        try gio.createStringVariant(libs, "IBusEngineDesc"),
        try gio.createEmptyArrayVariant(libs, "{sv}"),
        try gio.createStringVariant(libs, engine_name),
        try gio.createStringVariant(libs, "ASR"),
        try gio.createStringVariant(libs, "Commit ASR text through IBus"),
        try gio.createStringVariant(libs, "zh"),
        try gio.createStringVariant(libs, "MIT"),
        try gio.createStringVariant(libs, "_"),
        try gio.createStringVariant(libs, ""),
        try gio.createStringVariant(libs, "us"),
        try gio.createUint32Variant(libs, 0),
        try gio.createStringVariant(libs, ""),
        try gio.createStringVariant(libs, ""),
        try gio.createStringVariant(libs, ""),
        try gio.createStringVariant(libs, ""),
        try gio.createStringVariant(libs, ""),
        try gio.createStringVariant(libs, ""),
        try gio.createStringVariant(libs, ""),
        try gio.createStringVariant(libs, "ASR"),
    };
    return gio.createTupleVariant(libs, &values);
}

fn createIbusTextSignalParameters(libs: *const gio.Libraries, text: []const u8) !gio.Variant {
    const attr_list = try gio.createTupleVariant(libs, &.{
        try gio.createStringVariant(libs, "IBusAttrList"),
        try gio.createEmptyArrayVariant(libs, "{sv}"),
        try gio.createEmptyArrayVariant(libs, "v"),
    });
    const text_struct = try gio.createTupleVariant(libs, &.{
        try gio.createStringVariant(libs, "IBusText"),
        try gio.createEmptyArrayVariant(libs, "{sv}"),
        try gio.createStringVariant(libs, text),
        try gio.createVariantWrapper(libs, attr_list),
    });
    const signal_arg = try gio.createVariantWrapper(libs, text_struct);
    return gio.createTupleVariant(libs, &.{signal_arg});
}

fn commitTextStatus(service: *Service, text: []const u8) []const u8 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return "ERR empty_response";
    service.mutex.lockUncancelable(service.io);
    const active = service.state.active_engine;
    service.mutex.unlock(service.io);
    const engine = active orelse return "ERR engine_not_created";
    if (!engine.enabled and !engine.has_focus) return "ERR engine_not_active";

    const raw_parameters = createIbusTextSignalParameters(&service.libs, text) catch return "ERR service_unavailable";
    const parameters = gio.refSink(&service.libs, raw_parameters) catch return "ERR service_unavailable";
    defer gio.unrefVariant(&service.libs, parameters);

    gio.emitSignal(&service.libs, service.connection, engine.object_path, engine_iface, commit_text_signal, parameters) catch return "ERR service_unavailable";
    gio.flushConnection(&service.libs, service.connection) catch return "ERR service_unavailable";
    return "OK committed";
}

fn sleepMs(io: std.Io, milliseconds: i64) void {
    std.Io.sleep(io, .fromMilliseconds(milliseconds), .awake) catch {};
}

test "gio ibus helpers are exposed" {
    try std.testing.expectEqualStrings("engine_not_created", getStatus(null));
    try std.testing.expect(std.mem.indexOf(u8, createFactoryXml(), "CreateEngine") != null);
    try std.testing.expect(std.mem.indexOf(u8, createServiceXml(), "CommitText") != null);
    try std.testing.expect(std.mem.indexOf(u8, createEngineXml(), "ProcessKeyEvent") != null);
}

test "commit text guards empty and inactive engine" {
    var service = Service{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .libs = undefined,
        .connection = undefined,
        .registrations = .empty,
        .state = .{},
        .mutex = .init,
    };
    try std.testing.expectEqualStrings("ERR empty_response", commitTextStatus(&service, " "));
    try std.testing.expectEqualStrings("ERR engine_not_created", commitTextStatus(&service, "hello"));
    service.state.active_engine = .{ .object_path = "/tmp/engine", .enabled = false, .has_focus = false };
    try std.testing.expectEqualStrings("ERR engine_not_active", commitTextStatus(&service, "hello"));
}

test "retries only dbus call failures" {
    try std.testing.expect(shouldRetryConnection(gio.Error.DBusCallFailed));
    try std.testing.expect(!shouldRetryConnection(gio.Error.BusNameRequestFailed));
}
