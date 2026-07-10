pub const config = @import("config.zig");
pub const cli = @import("cli.zig");
pub const key = @import("key.zig");
pub const runtime = struct {
    pub const app = @import("runtime/app.zig");
    pub const audio_gate = @import("runtime/audio_gate.zig");
    pub const cmd = @import("runtime/cmd.zig");
    pub const gio_dbus = @import("runtime/gio_dbus.zig");
    pub const gio_ibus = @import("runtime/gio_ibus.zig");
    pub const ibus = @import("runtime/ibus.zig");
    pub const mute = @import("runtime/mute.zig");
    pub const notify = @import("runtime/notify.zig");
    pub const postprocess = @import("runtime/postprocess.zig");
    pub const output = @import("runtime/output.zig");
};
pub const doubao = struct {
    pub const proto = @import("doubao/proto.zig");
    pub const client = @import("doubao/client.zig");
    pub const rectify = @import("doubao/rectify.zig");
};

test {
    _ = config;
    _ = cli;
    _ = key;
    _ = runtime.app;
    _ = runtime.audio_gate;
    _ = runtime.cmd;
    _ = runtime.gio_dbus;
    _ = runtime.gio_ibus;
    _ = runtime.ibus;
    _ = @import("runtime/mic.zig");
    _ = runtime.mute;
    _ = runtime.notify;
    _ = runtime.postprocess;
    _ = runtime.output;
    _ = doubao.proto;
    _ = doubao.client;
}
