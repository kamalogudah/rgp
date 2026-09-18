//! Materializes and verifies corpus snapshots from local paths or remote Git URLs.
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const git = @import("git.zig");
const discovery = @import("../repository/discovery.zig");

pub const Status = enum {
    ok,
    failed,
    skipped,
};

pub const Result = struct {
    id: []const u8,
    status: Status,
    message: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

pub const Options = struct {
    cache_root: []const u8 = ".rgp/corpus",
};

/// Returns the snapshot directory path for a repository id. Caller owns string.
pub fn snapshotPath(allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_root, id });
}

/// Verifies or fetches the pinned snapshot for a single repository.
pub fn syncRepository(allocator: std.mem.Allocator, io: Io, repo: manifest.Repository, options: Options) !Result {
    if (!repo.isRemote()) {
        const abs_source = try resolveLocalPath(allocator, io, repo.source);
        defer allocator.free(abs_source);

        Io.Dir.cwd().access(io, abs_source, .{}) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "local path `{s}` is not accessible: {s}", .{ repo.source, @errorName(err) });
            return Result{ .id = repo.id, .status = .failed, .message = message };
        };

        const commit = git.localCommit(allocator, io, abs_source) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "cannot read Git HEAD at `{s}`: {s}", .{ repo.source, @errorName(err) });
            return Result{ .id = repo.id, .status = .failed, .message = message };
        };
        defer if (commit) |c| allocator.free(c);

        if (commit) |c| {
            if (!std.mem.eql(u8, c, repo.revision)) {
                const message = try std.fmt.allocPrint(allocator, "local repository `{s}` is at `{s}`, but corpus.toml pins `{s}`; update the revision or checkout the pinned commit", .{ repo.source, c, repo.revision });
                return Result{ .id = repo.id, .status = .failed, .message = message };
            }
        }

        const message = try std.fmt.allocPrint(allocator, "local snapshot verified at `{s}`", .{abs_source});
        return Result{ .id = repo.id, .status = .ok, .message = message };
    }

    const dest = try snapshotPath(allocator, options.cache_root, repo.id);
    defer allocator.free(dest);

    git.materialize(allocator, io, repo.source, repo.revision, dest) catch |err| {
        const description = switch (err) {
            error.GitNotFound => "git executable not found; install Git and ensure it is on PATH",
            error.GitFailed => "git fetch/checkout failed; check the URL, network, and that the pinned commit exists",
            error.InvalidOutput => "unexpected output from git; repository may be empty or unreachable",
            error.OutOfMemory => return error.OutOfMemory,
        };
        const message = try std.fmt.allocPrint(allocator, "cannot materialize snapshot at `{s}`: {s}", .{ dest, description });
        return Result{ .id = repo.id, .status = .failed, .message = message };
    };

    const message = try std.fmt.allocPrint(allocator, "snapshot materialized at `{s}`", .{dest});
    return Result{ .id = repo.id, .status = .ok, .message = message };
}

pub fn syncAll(allocator: std.mem.Allocator, io: Io, m: manifest.Manifest, options: Options) ![]Result {
    var results = std.ArrayList(Result).empty;
    errdefer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }
    for (m.repositories) |repo| {
        const result = try syncRepository(allocator, io, repo, options);
        try results.append(allocator, result);
    }
    return results.toOwnedSlice(allocator);
}

pub fn isMaterialized(io: Io, repo: manifest.Repository, cache_root: []const u8) bool {
    if (!repo.isRemote()) {
        Io.Dir.cwd().access(io, repo.source, .{}) catch return false;
        return true;
    }
    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ cache_root, repo.id }) catch return false;
    defer std.heap.page_allocator.free(path);
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn resolveLocalPath(allocator: std.mem.Allocator, io: Io, source: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(source)) return try allocator.dupe(u8, source);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, source });
}

test "local path sync reports missing directory" {
    const io = std.testing.io;
    const include = blk: {
        const items = try std.testing.allocator.alloc([]u8, 1);
        items[0] = try std.testing.allocator.dupe(u8, "**/*.rb");
        break :blk items;
    };
    const exclude = try std.testing.allocator.alloc([]u8, 0);
    var repo = manifest.Repository{
        .id = try std.testing.allocator.dupe(u8, "missing"),
        .source = try std.testing.allocator.dupe(u8, "does-not-exist"),
        .revision = try std.testing.allocator.dupe(u8, "0000000000000000000000000000000000000000"),
        .include = include,
        .exclude = exclude,
    };
    defer repo.deinit(std.testing.allocator);
    var result = try syncRepository(std.testing.allocator, io, repo, .{ .cache_root = ".rgp/corpus" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.failed, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.message, "not accessible") != null);
}
