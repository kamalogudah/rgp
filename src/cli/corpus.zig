//! Corpus management subcommands: add, remove, list, sync.
const std = @import("std");
const Io = std.Io;

const manifest = @import("../corpus/manifest.zig");
const sync = @import("../corpus/sync.zig");
const git = @import("../corpus/git.zig");

const corpus_path = "corpus.toml";
const default_cache_root = ".rgp/corpus";

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    if (args.len == 0) {
        try writer.writeAll(corpus_usage);
        return 0;
    }
    const subcommand = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, subcommand, "add")) return try add(io, allocator, rest, writer);
    if (std.mem.eql(u8, subcommand, "remove")) return try remove(io, allocator, rest, writer);
    if (std.mem.eql(u8, subcommand, "list")) return try list(io, allocator, writer);
    if (std.mem.eql(u8, subcommand, "sync")) return try syncCmd(io, allocator, writer);
    try writer.print("error: unknown corpus subcommand `{s}`. Run `rgp corpus` for usage.\n", .{subcommand});
    return 2;
}

const corpus_usage =
    "Corpus management\n" ++
    "\n" ++
    "Usage:\n" ++
    "  rgp corpus add <source> [--revision <sha>] [--category <cat>] [--id <id>]\n" ++
    "  rgp corpus remove <repo>\n" ++
    "  rgp corpus list\n" ++
    "  rgp corpus sync\n" ++
    "\n" ++
    "<source> may be a local path or a Git URL (https:// or git@).\n" ++
    "\n" ++
    "Categories: rails, framework, library, tool, standard, server, fixture, other.\n";

fn loadManifest(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer) !?manifest.Manifest {
    Io.Dir.cwd().access(io, corpus_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return manifest.Manifest{ .schema_version = 1, .offline = true, .repositories = try allocator.alloc(manifest.Repository, 0) },
        else => {},
    };
    const lr = manifest.loadFile(allocator, io, Io.Dir.cwd(), corpus_path);
    if (lr.manifest) |m| {
        if (lr.diagnostic) |d| allocator.free(d);
        return m;
    }
    if (lr.diagnostic) |d| {
        try writer.print("error: {s}\n", .{d});
        allocator.free(d);
    } else {
        try writer.print("error: cannot load corpus.toml\n", .{});
    }
    return null;
}

fn add(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    var source: ?[]const u8 = null;
    var revision: ?[]const u8 = null;
    var category: ?manifest.Category = null;
    var id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--revision")) {
            i += 1;
            if (i >= args.len) {
                try writer.writeAll("error: `--revision` requires a 40-character SHA.\n");
                return 2;
            }
            revision = args[i];
        } else if (std.mem.eql(u8, arg, "--category")) {
            i += 1;
            if (i >= args.len) {
                try writer.writeAll("error: `--category` requires a category name.\n");
                return 2;
            }
            if (manifest.Category.fromString(args[i])) |c| {
                category = c;
            } else {
                try writer.print("error: unknown category `{s}`.\n", .{args[i]});
                return 2;
            }
        } else if (std.mem.eql(u8, arg, "--id")) {
            i += 1;
            if (i >= args.len) {
                try writer.writeAll("error: `--id` requires a value.\n");
                return 2;
            }
            id = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try writer.print("error: unknown option `{s}`.\n", .{arg});
            return 2;
        } else {
            if (source != null) {
                try writer.writeAll("error: only one source may be added at a time.\n");
                return 2;
            }
            source = arg;
        }
    }

    const src = source orelse {
        try writer.writeAll("error: `rgp corpus add` requires a source.\n");
        return 2;
    };

    const m = (try loadManifest(allocator, io, writer)) orelse return 1;
    defer m.deinit(allocator);

    const inferred_id = id orelse try inferId(allocator, src);
    defer if (id == null) allocator.free(inferred_id);
    if (!manifest.validateId(inferred_id)) {
        try writer.print("error: id `{s}` must match [a-z0-9][a-z0-9_-]*; use `--id` to specify one.\n", .{inferred_id});
        return 2;
    }
    if (m.findById(inferred_id) != null) {
        try writer.print("error: corpus.toml already contains repository `{s}`.\n", .{inferred_id});
        return 1;
    }

    const inferred_revision = revision orelse resolveRevision(allocator, io, writer, src) catch return 1;
    defer if (revision == null) allocator.free(inferred_revision);
    if (!manifest.validateSha(inferred_revision)) {
        try writer.print("error: revision `{s}` must be a 40-character lowercase Git commit SHA.\n", .{inferred_revision});
        return 2;
    }

    const inferred_category = category orelse try inferCategory(allocator, src);

    var updated = try m.clone(allocator);
    defer updated.deinit(allocator);
    const new_repos = try allocator.alloc(manifest.Repository, updated.repositories.len + 1);
    errdefer {
        for (new_repos[0..updated.repositories.len]) |*r| r.deinit(allocator);
        allocator.free(new_repos);
    }
    for (updated.repositories, 0..) |repo, idx| new_repos[idx] = repo;
    new_repos[updated.repositories.len] = .{
        .id = try allocator.dupe(u8, inferred_id),
        .source = try allocator.dupe(u8, src),
        .revision = try allocator.dupe(u8, inferred_revision),
        .include = try duplicateStringArray(allocator, &.{"**/*.rb"}),
        .exclude = try duplicateStringArray(allocator, &.{ "vendor/**", "tmp/**", "node_modules/**" }),
        .category = inferred_category,
    };
    allocator.free(updated.repositories);
    updated.repositories = new_repos;

    try manifest.writeToFile(updated, allocator, io, Io.Dir.cwd(), corpus_path);
    try writer.print("added `{s}` ({s}) at {s}\n", .{ inferred_id, src, inferred_revision });
    return 0;
}

fn inferCategory(allocator: std.mem.Allocator, source: []const u8) !?manifest.Category {
    _ = allocator;
    if (std.mem.indexOf(u8, source, "rails")) |_| return .rails;
    if (std.mem.indexOf(u8, source, "hanami")) |_| return .framework;
    if (std.mem.indexOf(u8, source, "sinatra")) |_| return .framework;
    if (std.mem.indexOf(u8, source, "rack")) |_| return .framework;
    if (std.mem.indexOf(u8, source, "rspec")) |_| return .tool;
    if (std.mem.indexOf(u8, source, "rubocop")) |_| return .tool;
    if (std.mem.indexOf(u8, source, "rake")) |_| return .standard;
    if (std.mem.indexOf(u8, source, "irb")) |_| return .standard;
    if (std.mem.indexOf(u8, source, "debug")) |_| return .standard;
    return null;
}

fn isRemoteSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "https://") or std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "git@");
}

fn resolveRevision(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, source: []const u8) ![]u8 {
    if (isRemoteSource(source)) {
        const sha = git.resolveRemoteCommit(allocator, io, source) catch |err| {
            try writer.print("error: cannot resolve remote HEAD for `{s}`: {s}\n", .{ source, @errorName(err) });
            return error.ActionFailed;
        };
        return sha.?;
    }
    const abs = try sync.resolveLocalPath(allocator, io, source);
    defer allocator.free(abs);
    const sha = git.localCommit(allocator, io, abs) catch |err| {
        try writer.print("error: cannot read Git HEAD at `{s}`: {s}\n", .{ source, @errorName(err) });
        return error.ActionFailed;
    };
    if (sha) |s| return s;
    try writer.print("error: `{s}` is not a Git repository; pass `--revision` explicitly.\n", .{source});
    return error.ActionFailed;
}

const ActionFailed = error{ActionFailed};

fn inferId(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, source, "https://") or std.mem.startsWith(u8, source, "http://")) {
        // Drop trailing .git and take owner_repo.
        var end = source.len;
        if (std.mem.endsWith(u8, source, ".git")) end -= 4;
        var it = std.mem.splitBackwardsScalar(u8, source[0..end], '/');
        const repo = it.next() orelse return try allocator.dupe(u8, "repo");
        const owner = it.next() orelse return try allocator.dupe(u8, repo);
        return try std.fmt.allocPrint(allocator, "{s}_{s}", .{ owner, repo });
    }
    if (std.mem.startsWith(u8, source, "git@")) {
        const path_start = std.mem.indexOfScalar(u8, source, ':') orelse source.len;
        const path = source[path_start + 1 ..];
        var end = path.len;
        if (std.mem.endsWith(u8, path, ".git")) end -= 4;
        var it = std.mem.splitBackwardsScalar(u8, path[0..end], '/');
        const repo = it.next() orelse return try allocator.dupe(u8, "repo");
        const owner = it.next() orelse return try allocator.dupe(u8, repo);
        return try std.fmt.allocPrint(allocator, "{s}_{s}", .{ owner, repo });
    }
    const base = std.fs.path.basename(source);
    if (base.len > 0) return try allocator.dupe(u8, base);
    return try allocator.dupe(u8, "local");
}

fn remove(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    if (args.len != 1) {
        try writer.writeAll("error: `rgp corpus remove` requires exactly one repository id or source.\n");
        return 2;
    }
    const target = args[0];
    const m = (try loadManifest(allocator, io, writer)) orelse return 1;
    defer m.deinit(allocator);

    const index = m.findById(target) orelse findBySource(m, target) orelse {
        try writer.print("error: corpus.toml has no repository with id or source `{s}`.\n", .{target});
        return 1;
    };
    const removed_repo = m.repositories[index];

    var updated = try m.clone(allocator);
    defer updated.deinit(allocator);
    const new_repos = try allocator.alloc(manifest.Repository, updated.repositories.len - 1);
    errdefer allocator.free(new_repos);
    var dst: usize = 0;
    for (updated.repositories, 0..) |r, i| {
        if (i == index) continue;
        new_repos[dst] = r;
        dst += 1;
    }
    allocator.free(updated.repositories);
    updated.repositories = new_repos;

    try manifest.writeToFile(updated, allocator, io, Io.Dir.cwd(), corpus_path);

    if (removed_repo.isRemote()) {
        const cache_path = try sync.snapshotPath(allocator, default_cache_root, removed_repo.id);
        defer allocator.free(cache_path);
        try writer.print("removed `{s}` from corpus.toml.\n", .{removed_repo.id});
        try writer.print("note: cached snapshot at `{s}` was preserved; delete it manually or run `rgp corpus clean`.\n", .{cache_path});
    } else {
        try writer.print("removed `{s}` from corpus.toml.\n", .{removed_repo.id});
        try writer.print("note: local source at `{s}` was not modified.\n", .{removed_repo.source});
    }
    return 0;
}

fn findBySource(m: manifest.Manifest, source: []const u8) ?usize {
    for (m.repositories, 0..) |repo, i| {
        if (std.mem.eql(u8, repo.source, source)) return i;
    }
    return null;
}

fn list(io: Io, allocator: std.mem.Allocator, writer: *Io.Writer) !u8 {
    const m = (try loadManifest(allocator, io, writer)) orelse return 1;
    defer m.deinit(allocator);

    try writer.writeAll("id                  source                                    revision                                category    status\n");
    try writer.writeAll("-----------------------------------------------------------------------------------------------\n");
    for (m.repositories) |repo| {
        const status: []const u8 = if (repo.isRemote())
            if (sync.isMaterialized(io, repo, default_cache_root)) "cached" else "missing"
        else if (localPathPresent(io, repo.source)) "present" else "missing";
        try writer.print("{s:<19} {s:<41} {s:<40} {s:<11} {s}\n", .{
            truncate(repo.id, 18),
            truncate(repo.source, 40),
            repo.revision,
            repo.displayCategory(),
            status,
        });
    }
    try writer.print("\n{d} repository(s)\n", .{m.repositories.len});
    return 0;
}

fn localPathPresent(io: Io, source: []const u8) bool {
    Io.Dir.cwd().access(io, source, .{}) catch return false;
    return true;
}

fn syncCmd(io: Io, allocator: std.mem.Allocator, writer: *Io.Writer) !u8 {
    const m = (try loadManifest(allocator, io, writer)) orelse return 1;
    defer m.deinit(allocator);

    Io.Dir.cwd().createDirPath(io, default_cache_root) catch |err| {
        try writer.print("error: cannot create cache directory `{s}`: {s}\n", .{ default_cache_root, @errorName(err) });
        return 1;
    };

    const results = try sync.syncAll(allocator, io, m, .{ .cache_root = default_cache_root });
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    var failures: usize = 0;
    for (results) |result| {
        const symbol: []const u8 = switch (result.status) {
            .ok => "ok",
            .failed => "FAILED",
            .skipped => "skipped",
        };
        try writer.print("[{s}] {s}: {s}\n", .{ symbol, result.id, result.message });
        if (result.status == .failed) failures += 1;
    }
    if (failures > 0) {
        try writer.print("\nerror: {d} snapshot(s) could not be materialized.\n", .{failures});
        return 1;
    }
    return 0;
}

fn duplicateStringArray(allocator: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error![]const []u8 {
    const result = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(result);
    for (items, 0..) |item, i| {
        result[i] = try allocator.dupe(u8, item);
    }
    return result;
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

test "inferId derives ids from URLs, SSH URLs, and local paths" {
    const https_id = try inferId(std.testing.allocator, "https://github.com/rails/rails.git");
    defer std.testing.allocator.free(https_id);
    try std.testing.expectEqualStrings("rails_rails", https_id);

    const ssh_id = try inferId(std.testing.allocator, "git@github.com:rspec/rspec-core.git");
    defer std.testing.allocator.free(ssh_id);
    try std.testing.expectEqualStrings("rspec_rspec-core", ssh_id);

    const local_id = try inferId(std.testing.allocator, "./my-project");
    defer std.testing.allocator.free(local_id);
    try std.testing.expectEqualStrings("my-project", local_id);
}

test "inferCategory maps known repositories to cohorts" {
    try std.testing.expectEqual(manifest.Category.rails, (try inferCategory(std.testing.allocator, "https://github.com/rails/rails")).?);
    try std.testing.expectEqual(manifest.Category.framework, (try inferCategory(std.testing.allocator, "https://github.com/sinatra/sinatra")).?);
    try std.testing.expectEqual(manifest.Category.standard, (try inferCategory(std.testing.allocator, "https://github.com/ruby/rake")).?);
    try std.testing.expect((try inferCategory(std.testing.allocator, "https://example.test/unknown")) == null);
}
