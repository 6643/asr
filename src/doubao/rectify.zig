const std = @import("std");

pub const CorrectWordInfo = struct {
    source_word: []const u8,
    predict_word: []const u8,
    word_idx_in_text: usize,
    confidence: f64,
};

pub fn rectifyText(allocator: std.mem.Allocator, io: std.Io, text: []const u8, sami_token: []const u8, device_id: []const u8) !?[]u8 {
    if (sami_token.len == 0) return null;

    const body = try buildJsonBody(allocator, text);
    defer allocator.free(body);

    const response_body = try doHttpRequest(allocator, io, body, sami_token, device_id) orelse return null;
    defer allocator.free(response_body);

    return parseAndApply(allocator, text, response_body);
}

fn buildJsonBody(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"text\":\"");
    for (text) |c| {
        if (c == '"' or c == '\\') try buf.append(allocator, '\\');
        try buf.append(allocator, c);
    }
    try buf.appendSlice(allocator, "\",\"rectify_type\":\"asr_correct\",\"scene\":\"asr\"}");
    return buf.toOwnedSlice(allocator);
}

/// HTTP POST using std.process.spawn with curl as separate argv elements.
/// No shell interpolation — eliminates the shell injection vulnerability
/// of the previous popen(shell_cmd) approach.
fn doHttpRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    body: []const u8,
    sami_token: []const u8,
    device_id: []const u8,
) !?[]u8 {
    const sami_hdr = try std.fmt.allocPrint(allocator, "sami_token: {s}", .{sami_token});
    defer allocator.free(sami_hdr);
    const device_hdr = try std.fmt.allocPrint(allocator, "X-Device-Id: {s}", .{device_id});
    defer allocator.free(device_hdr);

    var child = std.process.spawn(io, .{
        .argv = &.{
            "curl", "-s", "-X", "POST",
            "https://ime.oceancloudapi.com/api/v1/rectify_text",
            "-H", "content-type: application/json",
            "-H", sami_hdr,
            "-H", device_hdr,
            "-d", body,
        },
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return null;
    errdefer child.kill(io);

    const stdout = child.stdout orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var reader_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(stdout, io, &reader_buffer);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const read_len = reader.interface.readSliceShort(&chunk) catch break;
        if (read_len == 0) break;
        try buf.appendSlice(allocator, chunk[0..read_len]);
    }
    _ = child.wait(io) catch {};
    const result = buf.toOwnedSlice(allocator) catch return null;
    if (result.len == 0) {
        allocator.free(result);
        return null;
    }
    return result;
}

fn parseAndApply(allocator: std.mem.Allocator, text: []const u8, response_body: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;
    const code = root.object.get("code") orelse return null;
    if (code != .integer or code.integer != 0) return null;
    const data = root.object.get("data") orelse return null;
    if (data != .object) return null;
    const info_arr = data.object.get("correct_word_info") orelse return null;
    if (info_arr != .array or info_arr.array.items.len == 0) return null;

    var corrections = try std.ArrayList(CorrectWordInfo).initCapacity(allocator, info_arr.array.items.len);
    defer corrections.deinit(allocator);

    for (info_arr.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const source_word = obj.get("source_word") orelse continue;
        const predict_word = obj.get("predict_word") orelse continue;
        const word_idx = obj.get("word_idx_in_text") orelse continue;
        const confidence_val = obj.get("confidence") orelse continue;
        if (source_word != .string or predict_word != .string or word_idx != .integer or (confidence_val != .float and confidence_val != .integer)) continue;
        try corrections.append(allocator, .{
            .source_word = source_word.string,
            .predict_word = predict_word.string,
            .word_idx_in_text = @intCast(word_idx.integer),
            .confidence = if (confidence_val == .float) confidence_val.float else @floatFromInt(confidence_val.integer),
        });
    }

    if (corrections.items.len == 0) return null;

    std.log.info("rectify: {d} corrections found", .{corrections.items.len});

    var result = try allocator.dupe(u8, text);
    errdefer allocator.free(result);

    std.mem.sortUnstable(CorrectWordInfo, corrections.items, {}, struct {
        fn lessThan(_: void, a: CorrectWordInfo, b: CorrectWordInfo) bool {
            return a.word_idx_in_text > b.word_idx_in_text;
        }
    }.lessThan);

    for (corrections.items) |corr| {
        const byte_offset = codePointToByteOffset(result, corr.word_idx_in_text) catch continue;
        if (byte_offset + corr.source_word.len > result.len) continue;
        if (!std.mem.eql(u8, result[byte_offset..][0..corr.source_word.len], corr.source_word)) {
            std.log.warn("rectify: source_word '{s}' not found at position {d}, text: '{s}'", .{ corr.source_word, corr.word_idx_in_text, result });
            continue;
        }
        const new_result = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            result[0..byte_offset],
            corr.predict_word,
            result[byte_offset + corr.source_word.len ..],
        });
        allocator.free(result);
        result = new_result;
    }

    return result;
}

fn codePointToByteOffset(text: []const u8, codepoint_index: usize) !usize {
    var cp_count: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    while (it.nextCodepoint()) |_| {
        if (cp_count == codepoint_index) return it.i;
        cp_count += 1;
    }
    return error.IndexOutOfBounds;
}
