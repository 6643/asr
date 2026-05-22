const std = @import("std");
const asr = @import("asr_zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const path = try asr.runtime.ibus.resolveComponentPath(allocator, init.minimal.environ);
    defer allocator.free(path);
    try asr.runtime.ibus.installComponent(init.io, path);
    std.log.info("{s}", .{path});
}
