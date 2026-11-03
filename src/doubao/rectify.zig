const std = @import("std");
const common = @import("../common.zig");

pub const CorrectWordInfo = struct {
    source_word: []const u8,
    predict_word: []const u8,
    word_idx_in_text: usize,
    confidence: f64,
};

/// Hard timeout for rectify HTTP so commit path never hangs on a slow network.
pub const request_timeout_ms: i64 = 1_500;

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

/// HTTP POST via curl argv (no shell). Race the request against a timeout using
/// Zig 0.16 `Io.Select` so a hung rectify never blocks the commit forever.
fn doHttpRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    body: []const u8,
    sami_token: []const u8,
    device_id: []const u8,
) !?[]u8 {
    const SelectResult = union(enum) {
        response: ?[]u8,
        timeout: void,
    };
    var slots: [2]SelectResult = undefined;
    var select = std.Io.Select(SelectResult).init(io, &slots);

    const curl_args = CurlArgs{
        .allocator = allocator,
        .io = io,
        .body = body,
        .sami_token = sami_token,
        .device_id = device_id,
    };

    // Prefer concurrent so curl and timeout race on real workers.
    select.concurrent(.response, curlRequest, .{curl_args}) catch {
        select.async(.response, curlRequest, .{curl_args});
    };
    select.concurrent(.timeout, sleepThenTimeout, .{ io, request_timeout_ms }) catch {
        select.async(.timeout, sleepThenTimeout, .{ io, request_timeout_ms });
    };

    // First completed arm wins; cancel drains the rest.
    const first = try select.await();
    while (select.cancel()) |item| {
        switch (item) {
            .response => |body_opt| if (body_opt) |owned| allocator.free(owned),
            .timeout => {},
        }
    }

    return switch (first) {
        .response => |body_opt| body_opt,
        .timeout => null,
    };
}

fn sleepThenTimeout(io: std.Io, timeout_ms: i64) void {
    std.Io.sleep(io, .fromMilliseconds(timeout_ms), .awake) catch {};
}

const CurlArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    body: []const u8,
    sami_token: []const u8,
    device_id: []const u8,
};

/// The argv plus the formatted strings it points at; `deinit` frees both.
const CurlArgv = struct {
    argv: std.ArrayList([]const u8),
    owned: [3][]u8,

    fn deinit(self: *CurlArgv, allocator: std.mem.Allocator) void {
        for (self.owned) |owned| allocator.free(owned);
        self.argv.deinit(allocator);
    }
};

fn curlArgv(
    allocator: std.mem.Allocator,
    body: []const u8,
    sami_token: []const u8,
    device_id: []const u8,
) !CurlArgv {
    var owned: [3][]u8 = undefined;
    var filled: usize = 0;
    errdefer for (owned[0..filled]) |s| allocator.free(s);

    // --max-time is a second line of defense if cancel does not interrupt curl promptly.
    owned[filled] = try std.fmt.allocPrint(allocator, "{d}", .{@divTrunc(request_timeout_ms + 999, 1000)});
    filled += 1;
    owned[filled] = try std.fmt.allocPrint(allocator, "sami_token: {s}", .{sami_token});
    filled += 1;
    owned[filled] = try std.fmt.allocPrint(allocator, "X-Device-Id: {s}", .{device_id});
    filled += 1;

    const argv = try common.directCurlArgv(allocator, &.{
        "-s",                                                "-X",                             "POST",
        "https://ime.oceancloudapi.com/api/v1/rectify_text", "--max-time",                     owned[0],
        "-H",                                                "content-type: application/json", "-H",
        owned[1],                                            "-H",                             owned[2],
        "-d",                                                body,
    });
    return .{ .argv = argv, .owned = owned };
}

fn curlRequest(args: CurlArgs) ?[]u8 {
    const allocator = args.allocator;
    const io = args.io;

    var curl = curlArgv(allocator, args.body, args.sami_token, args.device_id) catch return null;
    defer curl.deinit(allocator);

    var child = std.process.spawn(io, .{
        .argv = curl.argv.items,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return null;
    errdefer child.kill(io);

    const stdout = child.stdout orelse {
        child.kill(io);
        return null;
    };
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var reader_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(stdout, io, &reader_buffer);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const read_len = reader.interface.readSliceShort(&chunk) catch break;
        if (read_len == 0) break;
        buf.appendSlice(allocator, chunk[0..read_len]) catch {
            child.kill(io);
            buf.deinit(allocator);
            return null;
        };
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

    std.log.scoped(.rectify).info("{d} corrections found", .{corrections.items.len});

    // Apply from the end so earlier byte offsets stay valid, and splice through
    // a writer instead of reallocating the whole string per correction.
    std.mem.sortUnstable(CorrectWordInfo, corrections.items, {}, struct {
        fn lessThan(_: void, a: CorrectWordInfo, b: CorrectWordInfo) bool {
            return a.word_idx_in_text > b.word_idx_in_text;
        }
    }.lessThan);

    var applied: std.ArrayList(AppliedCorrection) = .empty;
    defer applied.deinit(allocator);
    for (corrections.items) |corr| {
        const byte_offset = codePointToByteOffset(text, corr.word_idx_in_text) catch continue;
        if (byte_offset + corr.source_word.len > text.len) continue;
        if (!std.mem.eql(u8, text[byte_offset..][0..corr.source_word.len], corr.source_word)) {
            std.log.scoped(.rectify).warn("source_word '{s}' not found at position {d}, text: '{s}'", .{ corr.source_word, corr.word_idx_in_text, text });
            continue;
        }
        const correction: AppliedCorrection = .{ .start = byte_offset, .end = byte_offset + corr.source_word.len, .replacement = corr.predict_word };
        // Corrections are sorted from the end, so an earlier accepted range
        // starts after this one. Overlapping duplicates would corrupt the
        // splice; the first accepted correction at a position wins.
        if (applied.items.len > 0) {
            const previous = applied.items[applied.items.len - 1];
            if (correction.end > previous.start) continue;
        }
        try applied.append(allocator, correction);
    }
    if (applied.items.len == 0) return null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var cursor: usize = 0;
    // `applied` is in descending offset order (the order the corrections
    // arrived in); the splice walks the text left to right.
    var index: usize = applied.items.len;
    while (index > 0) {
        index -= 1;
        const corr = applied.items[index];
        try out.writer.writeAll(text[cursor..corr.start]);
        try out.writer.writeAll(corr.replacement);
        cursor = corr.end;
    }
    try out.writer.writeAll(text[cursor..]);
    return try out.toOwnedSlice();
}

const AppliedCorrection = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

fn codePointToByteOffset(text: []const u8, codepoint_index: usize) !usize {
    var cp_count: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    while (cp_count < codepoint_index) {
        _ = it.nextCodepoint() orelse return error.IndexOutOfBounds;
        cp_count += 1;
    }
    return it.i;
}

test "rectify curl ignores the environment proxy" {
    const allocator = std.testing.allocator;
    var argv = try curlArgv(allocator, "body", "token", "device");
    defer argv.deinit(allocator);
    try std.testing.expectEqualSlices(
        []const u8,
        &[_][]const u8{ "curl", "--noproxy", "*" },
        argv.argv.items[0..3],
    );
}

test "request timeout constant is short enough for commit path" {
    try std.testing.expect(request_timeout_ms > 0);
    try std.testing.expect(request_timeout_ms <= 3_000);
}

test "applies corrections from the end without shifting earlier offsets" {
    const allocator = std.testing.allocator;
    const body =
        \\{"code":0,"data":{"correct_word_info":[
        \\{"source_word":"世界","predict_word":"视界","word_idx_in_text":2,"confidence":0.9},
        \\{"source_word":"你好","predict_word":"您好","word_idx_in_text":0,"confidence":0.9}]}}
    ;
    const result = (try parseAndApply(allocator, "你好世界", body)).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("您好视界", result);
}

test "ignores a correction whose source word is not at the reported index" {
    const allocator = std.testing.allocator;
    const body = "{\"code\":0,\"data\":{\"correct_word_info\":[{\"source_word\":\"不存在\",\"predict_word\":\"X\",\"word_idx_in_text\":0,\"confidence\":0.9}]}}";
    try std.testing.expect(try parseAndApply(allocator, "你好世界", body) == null);
}
