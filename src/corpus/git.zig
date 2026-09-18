//! Git operations for resolving and materializing pinned corpus snapshots.
const std = @import("std");
const Io = std.Io;

pub const Error = error{
    GitNotFound,
    GitFailed,
    InvalidOutput,
    OutOfMemory,
};

fn runGit(allocator: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) Error!std.process.RunResult {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    }) catch |err| {
        if (err == error.FileNotFound) return error.GitNotFound;
        return error.GitFailed;
    };
    return result;
}

/// Resolves the default-branch HEAD commit of a remote Git URL.
/// Caller owns the returned SHA.
pub fn resolveRemoteCommit(allocator: std.mem.Allocator, io: Io, url: []const u8) Error!?[]u8 {
    const argv = &[_][]const u8{ "git", "ls-remote", url, "HEAD" };
    const result = try runGit(allocator, io, argv, null);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    const stdout = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (stdout.len < 40) return error.InvalidOutput;
    const sha = stdout[0..40];
    for (sha) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidOutput;
    if (stdout.len > 40 and stdout[40] != '\t') return error.InvalidOutput;
    return try allocator.dupe(u8, sha);
}

/// Returns the HEAD commit of a local Git repository, or null if it cannot be
/// resolved without invoking a remote. Caller owns the returned string.
pub fn localCommit(allocator: std.mem.Allocator, io: Io, path: []const u8) Error!?[]u8 {
    const argv = &[_][]const u8{ "git", "-C", path, "rev-parse", "HEAD" };
    const result = try runGit(allocator, io, argv, null);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return error.GitFailed,
    }
    const stdout = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (stdout.len != 40) return error.InvalidOutput;
    for (stdout) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidOutput;
    return try allocator.dupe(u8, stdout);
}

/// Verifies that the working tree at `path` is at exactly `revision`.
pub fn verifyCheckout(allocator: std.mem.Allocator, io: Io, path: []const u8, revision: []const u8) Error!bool {
    const argv = &[_][]const u8{ "git", "-C", path, "rev-parse", "HEAD" };
    const result = try runGit(allocator, io, argv, null);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    const stdout = std.mem.trim(u8, result.stdout, " \t\r\n");
    return std.mem.eql(u8, stdout, revision);
}

/// Clones or updates a shallow snapshot of `url` into `dest` and checks out
/// exactly `revision`. The working tree is suitable for offline analysis.
pub fn materialize(allocator: std.mem.Allocator, io: Io, url: []const u8, revision: []const u8, dest: []const u8) Error!void {
    const exists = exists: {
        Io.Dir.cwd().access(io, dest, .{}) catch |err| switch (err) {
            error.FileNotFound => break :exists false,
            else => return error.GitFailed,
        };
        break :exists true;
    };

    if (!exists) {
        const init_argv = &[_][]const u8{ "git", "init", "-q", dest };
        const init_result = try runGit(allocator, io, init_argv, null);
        defer {
            allocator.free(init_result.stdout);
            allocator.free(init_result.stderr);
        }
        if (switch (init_result.term) {
            .exited => |c| c != 0,
            else => true,
        }) return error.GitFailed;

        const remote_argv = &[_][]const u8{ "git", "-C", dest, "remote", "add", "origin", url };
        const remote_result = try runGit(allocator, io, remote_argv, null);
        defer {
            allocator.free(remote_result.stdout);
            allocator.free(remote_result.stderr);
        }
        if (switch (remote_result.term) {
            .exited => |c| c != 0,
            else => true,
        }) return error.GitFailed;
    }

    const fetch_argv = &[_][]const u8{ "git", "-C", dest, "fetch", "--depth=1", "origin", revision };
    const fetch_result = try runGit(allocator, io, fetch_argv, null);
    defer {
        allocator.free(fetch_result.stdout);
        allocator.free(fetch_result.stderr);
    }
    if (switch (fetch_result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.GitFailed;

    const checkout_argv = &[_][]const u8{ "git", "-C", dest, "checkout", "--force", revision };
    const checkout_result = try runGit(allocator, io, checkout_argv, null);
    defer {
        allocator.free(checkout_result.stdout);
        allocator.free(checkout_result.stderr);
    }
    if (switch (checkout_result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.GitFailed;

    if (!(try verifyCheckout(allocator, io, dest, revision))) return error.GitFailed;
}

test "localCommit reads HEAD from a test repository" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, ".git/objects");
    try tmp.dir.createDirPath(io, ".git/refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/refs/heads/main", .data = "0123456789abcdef0123456789abcdef01234567\n" });

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = buffer[0..len];

    const commit = try localCommit(std.testing.allocator, io, path);
    defer if (commit) |c| std.testing.allocator.free(c);
    try std.testing.expect(commit != null);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", commit.?);
}
