# 启动时刷新 Doubao 凭证 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 每次普通 ASR 进程启动时，用现有设备标识刷新 `token` 与 `sami_token`，成功后最小化写回配置，失败则继续使用旧凭证。

**Architecture:** 新增 `src/doubao/credentials.zig`，集中负责两个 HTTP 请求、响应解析、原 JSON 的最小字段更新和原子写回。`runtime/app.zig` 与 `main.zig` 只负责在需要凭证的模式中调用刷新并重新加载配置；设备标识和未知 JSON 字段不经过重建丢失。

**Tech Stack:** Zig 0.16、`std.json`、`std.process.spawn`、`curl`。

## Global Constraints

- 保留 `device_id`、`install_id`、`cdid`、`openudid`、`clientudid`、`wave_session` 及未知 JSON 字段。
- 只在两个新 token 都成功获取后写回配置。
- 刷新失败不覆盖旧配置，继续使用旧凭证启动。
- 不为刷新流程引入第三方库。
- `--ibus` 和 `--ibus-xml` 不触发网络刷新。
- 不打印 token、SAMI token 或完整请求 URL。

---

### Task 1: Add pure credential JSON update helpers

**Files:**
- Create: `src/doubao/credentials.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Produce `pub fn updateCredentialJson(allocator: std.mem.Allocator, source: []const u8, token: []const u8, sami_token: []const u8) ![]u8`.
- Produce `pub fn extractCredentialRefreshIds(allocator: std.mem.Allocator, source: []const u8) !RefreshIds` where `RefreshIds` owns `device_id` and `cdid` and has `deinit`.

- [ ] **Step 1: Write failing tests**

Add tests in `src/doubao/credentials.zig` covering:

```zig
test "updates only token fields and preserves other credential fields" {
    const source =
        "{\"device_id\":\"dev\",\"install_id\":\"install\",\"cdid\":\"cid\",\"unknown\":42,\"token\":\"old\",\"sami_token\":\"old-sami\"}";
    const updated = try updateCredentialJson(std.testing.allocator, source, "new", "new-sami");
    defer std.testing.allocator.free(updated);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, updated, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("dev", parsed.value.object.get("device_id").?.string);
    try std.testing.expectEqualStrings("cid", parsed.value.object.get("cdid").?.string);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("unknown").?.integer);
    try std.testing.expectEqualStrings("new", parsed.value.object.get("token").?.string);
    try std.testing.expectEqualStrings("new-sami", parsed.value.object.get("sami_token").?.string);
}

test "extracts fixed refresh identifiers" {
    const ids = try extractCredentialRefreshIds(std.testing.allocator, "{\"device_id\":\"dev\",\"cdid\":\"cid\"}");
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dev", ids.device_id);
    try std.testing.expectEqualStrings("cid", ids.cdid);
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run `zig build test`; expect a compile failure because `credentials.zig` and its functions do not exist yet.

- [ ] **Step 3: Implement the pure helpers**

Parse with `std.json.parseFromSlice`, validate the root object and required string IDs, mutate only `token` and `sami_token`, serialize the same JSON value with `std.json.stringify`, and return an owned buffer. Missing IDs return an explicit error. Export the module from `src/root.zig` and include it in the test root.

- [ ] **Step 4: Run the focused test and verify it passes**

Run `zig build test`; expect the new JSON preservation tests and all existing tests to pass.

- [ ] **Step 5: Commit the unit**

Run:

```bash
git add src/doubao/credentials.zig src/root.zig
git commit -m "feat: add credential refresh JSON helpers"
```

### Task 2: Implement token fetching and atomic persistence

**Files:**
- Modify: `src/doubao/credentials.zig`

**Interfaces:**
- Produce `pub const RefreshResult = enum { updated, skipped }`.
- Produce `pub fn refreshFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, debug: bool) !RefreshResult`.

- [ ] **Step 1: Add failure-preservation test seam**

Add a pure test helper that accepts two already-fetched token results and only calls `updateCredentialJson` when both are non-empty. Test that an empty second result returns an error and leaves the source bytes unchanged. Keep network and filesystem out of this test.

- [ ] **Step 2: Run the test and verify it fails**

Run `zig build test`; expect failure because the fetch-result helper does not yet exist.

- [ ] **Step 3: Implement the minimum network path**

Use the historical API parameters exactly: AID `401734`, app `oime`, version `1.1.2`, channel `official`, existing `device_id`/`cdid`, and the existing Android device profile. Use `std.process.spawn` with `curl` argv, `--max-time`, `-sS`, and a response format that preserves the HTTP status for validation. Parse ASR `data.settings.asr_config.app_key` and SAMI `data.sami_token`; reject missing or empty values.

Fetch both values before touching the file. On success, write the updated JSON to a same-directory temporary file with restrictive mode and rename it over the original. On any request, parse, write, or rename error, do not replace the original and return the error. Log only error names/statuses when `debug` is enabled, never response bodies containing credentials.

- [ ] **Step 4: Run all tests**

Run `zig build test`; expect all tests to pass.

- [ ] **Step 5: Commit the unit**

Run:

```bash
git add src/doubao/credentials.zig
git commit -m "feat: refresh Doubao credentials atomically"
```

### Task 3: Invoke refresh during credential-dependent startup

**Files:**
- Modify: `src/runtime/app.zig:25-40`
- Modify: `src/main.zig:33-39`
- Modify: `src/root.zig`

**Interfaces:**
- Consume `doubao.credentials.refreshFile` from Task 2.
- Keep the existing in-memory `Config` fallback path when refresh returns an error.

- [ ] **Step 1: Add startup behavior test**

Add a test for a small startup helper with this contract: it attempts refresh, logs a warning on error, and returns the original loaded credentials; on success it reloads credentials from the path. The test must assert that the fallback token remains unchanged when refresh fails.

- [ ] **Step 2: Run the test and verify it fails**

Run `zig build test`; expect the helper contract test to fail before the startup helper exists.

- [ ] **Step 3: Wire the helper into both credential modes**

In `runtime/app.run` and the `once_pcm` branch, load the old credentials, call refresh, ignore only refresh errors with a warning, then reload credentials on success. Keep `--ibus` and `--ibus-xml` branches unchanged. Do not refresh after the IBus service has started or per hotkey press.

- [ ] **Step 4: Run tests and build**

Run `zig build test` and `zig build`; expect both to pass.

- [ ] **Step 5: Commit the unit**

Run:

```bash
git add src/main.zig src/runtime/app.zig src/root.zig
git commit -m "feat: refresh credentials at ASR startup"
```

### Task 4: Verify live startup behavior

**Files:**
- Modify: none

- [ ] **Step 1: Verify formatting and repository state**

Run `git diff --check` and confirm only intended files are changed; leave unrelated `docs/superpowers/plans/` content untouched.

- [ ] **Step 2: Build the executable**

Run `zig build`.

- [ ] **Step 3: Run one debug startup**

Run `./zig-out/bin/asr --debug`, hold `RightAlt` once, and verify that startup reports only a redacted refresh success/failure and that the existing device ID is unchanged.

- [ ] **Step 4: Verify the JSON field boundary**

Before and after the run, compare all fields except `token` and `sami_token`; expect no differences. Do not print token values.

- [ ] **Step 5: Run the final test gate**

Run `zig build test` and record the result before claiming completion.
