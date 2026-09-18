//! Analyze command: incremental repository and corpus analysis.
const std = @import("std");
const Io = std.Io;

const manifest = @import("../corpus/manifest.zig");
const sync = @import("../corpus/sync.zig");
const pipeline = @import("../analysis/pipeline.zig");
const storage = @import("../storage/sqlite.zig");
const prism_spike = @import("../prism_spike.zig");
const rgp = @import("../root.zig");

const corpus_path = "corpus.toml";
const default_cache_root = ".rgp/corpus";
const default_database = ".rgp/rgp.db";

pub const Options = struct {
    corpus: bool = false,
    path: ?[]const u8 = null,
};

pub const ParseResult = union(enum) {
    options: Options,
    help,
};

pub fn parseArgs(args: []const []const u8) !ParseResult {
    var options = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--corpus")) {
            options.corpus = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (options.path == null) {
            options.path = arg;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .options = options };
}

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    const parsed = parseArgs(args) catch |err| {
        const message = switch (err) {
            error.UnknownOption => "error: unknown option; supported flags are `--corpus`, `--help`.\n",
            error.TooManyArguments => "error: too many arguments; pass a single path or `--corpus`.\n",
        };
        try writer.writeAll(message);
        try writer.writeAll(analyze_usage);
        return 2;
    };

    switch (parsed) {
        .help => {
            try writer.writeAll(analyze_usage);
            return 0;
        },
        .options => |options| {
            if (options.corpus and options.path != null) {
                try writer.writeAll("error: `--corpus` and a positional path are mutually exclusive.\n");
                try writer.writeAll(analyze_usage);
                return 2;
            }

            if (options.corpus or options.path == null) {
                return try analyzeCorpus(io, allocator, writer);
            }

            return try analyzePath(io, allocator, writer, options.path.?);
        },
    }
}

const analyze_usage =
    "\nAnalyze usage:\n" ++
    "  rgp analyze              Analyze all materialized corpus snapshots\n" ++
    "  rgp analyze --corpus     Same as `rgp analyze`\n" ++
    "  rgp analyze <path>       Analyze a local repository path\n";

fn loadManifest(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer) !?manifest.Manifest {
    Io.Dir.cwd().access(io, corpus_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("error: `{s}` not found; add repositories with `rgp corpus add`.\n", .{corpus_path});
            return null;
        },
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
        try writer.print("error: cannot load {s}\n", .{corpus_path});
    }
    return null;
}

fn analyzeCorpus(io: Io, allocator: std.mem.Allocator, writer: *Io.Writer) !u8 {
    const m = (try loadManifest(allocator, io, writer)) orelse return 1;
    defer m.deinit(allocator);

    if (m.repositories.len == 0) {
        try writer.writeAll("No repositories configured; add one with `rgp corpus add`.\n");
        return 0;
    }

    var db = try openDatabase(io, allocator, writer, default_database);
    defer db.deinit();

    const versions = currentVersions();
    const snapshot_id = try snapshotIdForManifest(allocator, &db, m);

    var overall_failures: usize = 0;
    var total_analyzed: usize = 0;
    var total_skipped: usize = 0;

    for (m.repositories) |repo| {
        const repo_path = try resolveRepositoryPath(allocator, io, repo);
        defer allocator.free(repo_path);

        if (!sync.isMaterialized(io, repo, default_cache_root)) {
            try writer.print("[MISSING] {s}: snapshot not materialized; run `rgp corpus sync`.\n", .{repo.id});
            overall_failures += 1;
            continue;
        }

        var result = try pipeline.analyze(allocator, io, &db, .{
            .path = repo_path,
            .origin = repo.source,
            .commit_sha = repo.revision,
            .snapshot_id = snapshot_id,
            .exclude = repo.exclude,
        }, versions);
        defer result.deinit(allocator);

        total_analyzed += result.files_analyzed;
        total_skipped += result.files_skipped;

        const symbol: []const u8 = if (result.status == .completed) "ok" else "FAILED";
        try writer.print("[{s}] {s}: {d} analyzed, {d} skipped", .{ symbol, repo.id, result.files_analyzed, result.files_skipped });
        if (result.files_failed > 0) {
            try writer.print(", {d} failed", .{result.files_failed});
            overall_failures += result.files_failed;
        }
        try writer.writeByte('\n');
        if (result.failure) |failure| {
            try writer.print("  failure: {s}\n", .{failure});
        }
    }

    try writer.print("\nTotal: {d} analyzed, {d} skipped", .{ total_analyzed, total_skipped });
    if (overall_failures > 0) {
        try writer.print(", {d} failures\n", .{overall_failures});
        return 1;
    }
    try writer.writeByte('\n');
    return 0;
}

fn analyzePath(io: Io, allocator: std.mem.Allocator, writer: *Io.Writer, path: []const u8) !u8 {
    Io.Dir.cwd().access(io, path, .{}) catch |err| {
        try writer.print("error: cannot access `{s}`: {s}\n", .{ path, @errorName(err) });
        return 1;
    };

    var db = try openDatabase(io, allocator, writer, default_database);
    defer db.deinit();

    const commit_sha = try resolveLocalCommit(allocator, io, path);
    defer if (commit_sha) |s| allocator.free(s);
    const sha = commit_sha orelse "0000000000000000000000000000000000000000";

    var result = try pipeline.analyze(allocator, io, &db, .{
        .path = path,
        .origin = path,
        .commit_sha = sha,
    }, currentVersions());
    defer result.deinit(allocator);

    try writer.print("{d} analyzed, {d} skipped", .{ result.files_analyzed, result.files_skipped });
    if (result.files_failed > 0) try writer.print(", {d} failed", .{result.files_failed});
    try writer.writeByte('\n');

    if (result.failure) |failure| {
        try writer.print("failure: {s}\n", .{failure});
    }

    return if (result.status == .completed) 0 else 1;
}

fn openDatabase(io: Io, allocator: std.mem.Allocator, writer: *Io.Writer, path: []const u8) !storage.Database {
    Io.Dir.cwd().createDirPath(io, ".rgp") catch |err| {
        try writer.print("error: cannot create `.rgp` directory: {s}\n", .{@errorName(err)});
        return error.Io;
    };
    return storage.Database.open(allocator, path) catch |err| {
        try writer.print("error: cannot open database `{s}`: {s}\n", .{ path, @errorName(err) });
        return error.Io;
    };
}

fn resolveRepositoryPath(allocator: std.mem.Allocator, io: Io, repo: manifest.Repository) ![]u8 {
    if (!repo.isRemote()) {
        return sync.resolveLocalPath(allocator, io, repo.source);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ default_cache_root, repo.id });
}

fn resolveLocalCommit(allocator: std.mem.Allocator, io: Io, path: []const u8) !?[]u8 {
    const abs = try sync.resolveLocalPath(allocator, io, path);
    defer allocator.free(abs);
    const git = @import("../corpus/git.zig");
    return git.localCommit(allocator, io, abs) catch null;
}

fn snapshotIdForManifest(allocator: std.mem.Allocator, db: *storage.Database, m: manifest.Manifest) !i64 {
    const saved = try manifest.save(m, allocator);
    defer allocator.free(saved);
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(saved, &hash, .{});
    const hex = try hashToHex(allocator, &hash);
    defer allocator.free(hex);
    return try db.snapshotId("corpus", hex);
}

fn currentVersions() pipeline.AnalyzerVersions {
    return .{
        .rgp_version = rgp.version,
        .prism_version = prism_spike.version(),
        .classifier_version = "1",
        .taxonomy_version = "1",
    };
}

fn hashToHex(allocator: std.mem.Allocator, hash: *const [std.crypto.hash.sha2.Sha256.digest_length]u8) std.mem.Allocator.Error![]u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, hash.len * 2);
    for (hash, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return result;
}

test "parseArgs accepts no args, --corpus, and a path" {
    const no_args = (try parseArgs(&.{})).options;
    try std.testing.expect(no_args.corpus);
    try std.testing.expect(no_args.path == null);

    const corpus = (try parseArgs(&.{"--corpus"})).options;
    try std.testing.expect(corpus.corpus);
    try std.testing.expect(corpus.path == null);

    const path = (try parseArgs(&.{"./my-repo"})).options;
    try std.testing.expect(!path.corpus);
    try std.testing.expectEqualStrings("./my-repo", path.path.?);
}

test "parseArgs returns help for --help" {
    const result = try parseArgs(&.{"--help"});
    try std.testing.expectEqual(ParseResult.help, result);
}

test "parseArgs rejects unknown options and multiple positionals" {
    try std.testing.expectError(error.UnknownOption, parseArgs(&.{"--fast"}));
    try std.testing.expectError(error.TooManyArguments, parseArgs(&.{"a", "b"}));
}
