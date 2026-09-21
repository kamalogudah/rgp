//! Incremental repository analysis pipeline: discovery -> parse -> observe -> persist.
const std = @import("std");
const Io = std.Io;

const discovery = @import("../repository/discovery.zig");
const prism = @import("../prism/parser.zig");
const idioms = @import("idioms.zig");
const observation = @import("observation.zig");
const storage = @import("../storage/sqlite.zig");

pub const AnalyzerVersions = struct {
    rgp_version: []const u8,
    prism_version: []const u8,
    classifier_version: []const u8,
    taxonomy_version: []const u8,

    pub fn equal(a: AnalyzerVersions, b: AnalyzerVersions) bool {
        return std.mem.eql(u8, a.rgp_version, b.rgp_version) and
            std.mem.eql(u8, a.prism_version, b.prism_version) and
            std.mem.eql(u8, a.classifier_version, b.classifier_version) and
            std.mem.eql(u8, a.taxonomy_version, b.taxonomy_version);
    }
};

pub const Target = struct {
    path: []const u8,
    origin: []const u8,
    commit_sha: []const u8,
    snapshot_id: ?i64 = null,
    exclude: []const []const u8 = &.{},
};

pub const FileStatus = enum { analyzed, skipped, failed };

pub const FileResult = struct {
    path: []const u8,
    status: FileStatus,
    observations: usize,
    message: ?[]const u8 = null,

    pub fn deinit(self: *FileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.message) |m| allocator.free(m);
        self.* = .{ .path = &.{}, .status = .failed, .observations = 0, .message = null };
    }
};

pub const RunStatus = enum { completed, failed };

pub const RunResult = struct {
    run_id: i64,
    status: RunStatus,
    files_analyzed: usize,
    files_skipped: usize,
    files_failed: usize,
    total_observations: usize,
    failure: ?[]const u8 = null,
    file_results: []FileResult,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        if (self.failure) |f| allocator.free(f);
        for (self.file_results) |*fr| fr.deinit(allocator);
        allocator.free(self.file_results);
        self.* = .{ .run_id = 0, .status = .failed, .files_analyzed = 0, .files_skipped = 0, .files_failed = 0, .total_observations = 0, .failure = null, .file_results = &.{} };
    }
};

pub const Error = error{
    OutOfMemory,
    Sqlite,
    MigrationTooNew,
    Io,
};

/// Analyze a single repository snapshot incrementally. Existing observations
/// for unchanged files and unchanged analyzer versions are skipped; changed,
/// deleted, and version-invalidated observations are replaced atomically.
pub fn analyze(allocator: std.mem.Allocator, io: Io, db: *storage.Database, target: Target, versions: AnalyzerVersions) Error!RunResult {
    var file_results = std.ArrayList(FileResult).empty;
    errdefer {
        for (file_results.items) |*fr| fr.deinit(allocator);
        file_results.deinit(allocator);
    }

    const repo_id = try db.repositoryId(target.origin);
    const commit_id = try db.commitId(repo_id, target.commit_sha);

    var discovered = discovery.discover(io, allocator, target.path, .{ .exclude = target.exclude }) catch |err| {
        return .{
            .run_id = 0,
            .status = .failed,
            .files_analyzed = 0,
            .files_skipped = 0,
            .files_failed = 0,
            .total_observations = 0,
            .failure = try std.fmt.allocPrint(allocator, "cannot discover files in `{s}`: {s}", .{ target.path, @errorName(err) }),
            .file_results = try file_results.toOwnedSlice(allocator),
        };
    };
    defer discovered.deinit(allocator);

    const run_value = storage.Run{
        .repository_id = repo_id,
        .commit_id = commit_id,
        .snapshot_id = target.snapshot_id,
        .rgp_version = versions.rgp_version,
        .prism_version = versions.prism_version,
        .classifier_version = versions.classifier_version,
        .taxonomy_version = versions.taxonomy_version,
    };

    var current_file_ids = std.ArrayList(i64).empty;
    defer current_file_ids.deinit(allocator);

    var reanalyzed_file_ids = std.ArrayList(i64).empty;
    defer reanalyzed_file_ids.deinit(allocator);

    var observations = std.ArrayList(storage.Observation).empty;
    var idiom_matches = std.ArrayList(storage.IdiomMatch).empty;
    defer idiom_matches.deinit(allocator);
    defer {
        for (observations.items) |*obs| {
            allocator.free(obs.raw_json);
            if (obs.name) |n| allocator.free(n);
        }
        observations.deinit(allocator);
    }

    const root_dir = Io.Dir.cwd().openDir(io, target.path, .{ .iterate = false }) catch |err| {
        const result = RunResult{
            .run_id = 0,
            .status = .failed,
            .files_analyzed = 0,
            .files_skipped = 0,
            .files_failed = 0,
            .total_observations = 0,
            .failure = try std.fmt.allocPrint(allocator, "cannot open repository `{s}`: {s}", .{ target.path, @errorName(err) }),
            .file_results = try file_results.toOwnedSlice(allocator),
        };
        return result;
    };
    defer root_dir.close(io);

    for (discovered.files) |file| {
        const file_path = try std.fs.path.join(allocator, &.{ target.path, file.path });
        defer allocator.free(file_path);

        const source = root_dir.readFileAlloc(io, file.path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "cannot read `{s}`: {s}", .{ file.path, @errorName(err) });
            try file_results.append(allocator, .{ .path = try allocator.dupe(u8, file.path), .status = .failed, .observations = 0, .message = message });
            continue;
        };
        defer allocator.free(source);

        const hash = try sourceHash(allocator, source);
        defer allocator.free(hash);

        const file_record = try db.upsertFileClassified(commit_id, file.path, hash, @tagName(file.classification));
        try current_file_ids.append(allocator, file_record.id);

        const cached = !file_record.changed and try db.fileIsCached(file_record.id, run_value);

        if (cached) {
            try file_results.append(allocator, .{ .path = try allocator.dupe(u8, file.path), .status = .skipped, .observations = 0 });
            continue;
        }

        try reanalyzed_file_ids.append(allocator, file_record.id);
        const file_result = try analyzeFile(allocator, db, source, file.path, repo_id, commit_id, file_record.id, &observations, &idiom_matches);
        try file_results.append(allocator, file_result);
    }

    const run_id = db.persistIncrementalWithIdioms(run_value, current_file_ids.items, reanalyzed_file_ids.items, observations.items, idiom_matches.items) catch |err| {
        const result = RunResult{
            .run_id = 0,
            .status = .failed,
            .files_analyzed = 0,
            .files_skipped = 0,
            .files_failed = 0,
            .total_observations = 0,
            .failure = try std.fmt.allocPrint(allocator, "cannot persist analysis: {s}", .{@errorName(err)}),
            .file_results = try file_results.toOwnedSlice(allocator),
        };
        return result;
    };

    if (filesFailedBeforePersist(file_results.items)) try db.finishRun(run_id, .failed, "one or more files failed");

    var files_analyzed: usize = 0;
    var files_skipped: usize = 0;
    var files_failed: usize = 0;
    for (file_results.items) |fr| {
        switch (fr.status) {
            .analyzed => files_analyzed += 1,
            .skipped => files_skipped += 1,
            .failed => files_failed += 1,
        }
    }

    const failure_message: ?[]u8 = if (files_failed > 0)
        try buildFailureMessage(allocator, files_failed, file_results.items)
    else
        null;

    return .{
        .run_id = run_id,
        .status = if (files_failed > 0) .failed else .completed,
        .files_analyzed = files_analyzed,
        .files_skipped = files_skipped,
        .files_failed = files_failed,
        .total_observations = observations.items.len,
        .failure = failure_message,
        .file_results = try file_results.toOwnedSlice(allocator),
    };
}

fn filesFailedBeforePersist(results: []const FileResult) bool {
    for (results) |result| if (result.status == .failed) return true;
    return false;
}

fn analyzeFile(allocator: std.mem.Allocator, db: *storage.Database, source: []const u8, path: []const u8, repository_id: i64, commit_id: i64, file_id: i64, observations: *std.ArrayList(storage.Observation), idiom_matches: *std.ArrayList(storage.IdiomMatch)) Error!FileResult {
    var document = prism.parse(allocator, source, .{ .path = path }) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "cannot parse `{s}`: {s}", .{ path, @errorName(err) });
        return .{ .path = try allocator.dupe(u8, path), .status = .failed, .observations = 0, .message = message };
    };
    defer document.deinit();

    if (!document.success()) {
        const message = try std.fmt.allocPrint(allocator, "syntax error in `{s}`", .{path});
        return .{ .path = try allocator.dupe(u8, path), .status = .failed, .observations = 0, .message = message };
    }

    const extracted = observation.extract(allocator, &document) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "cannot extract observations from `{s}`: {s}", .{ path, @errorName(err) });
        return .{ .path = try allocator.dupe(u8, path), .status = .failed, .observations = 0, .message = message };
    };
    defer allocator.free(extracted);

    const observation_offset = observations.items.len;
    for (extracted) |obs| {
        const raw_json = try obs.json(allocator);
        errdefer allocator.free(raw_json);
        const construct_id = try constructIdFor(db, obs.construct);
        const name_copy: ?[]u8 = if (obs.name) |n| try allocator.dupe(u8, n) else null;
        errdefer if (name_copy) |n| allocator.free(n);
        try observations.append(allocator, .{
            .repository_id = repository_id,
            .commit_id = commit_id,
            .file_id = file_id,
            .start_offset = @intCast(obs.start_offset),
            .end_offset = @intCast(obs.end_offset),
            .line = @intCast(obs.line),
            .column = @intCast(obs.column),
            .node_kind = obs.node_kind,
            .raw_json = raw_json,
            .construct_id = construct_id,
            .name = name_copy,
            .receiver_kind = obs.receiver_kind,
            .block_syntax = obs.block_syntax,
        });
    }

    const found = try idioms.detectSource(allocator, source, extracted);
    defer allocator.free(found);
    for (found) |match| try idiom_matches.append(allocator, .{
        .observation_index = observation_offset + match.observation_index,
        .idiom_id = match.idiom_id,
        .reason = match.reason,
        .confidence = match.confidence,
        .classification = @tagName(match.classification),
        .rule_version = idioms.rule_version,
    });

    return .{ .path = try allocator.dupe(u8, path), .status = .analyzed, .observations = extracted.len };
}

fn constructIdFor(db: *storage.Database, construct: []const u8) Error!?i64 {
    return try db.getOrAddConstruct(construct);
}

fn buildFailureMessage(allocator: std.mem.Allocator, files_failed: usize, file_results: []const FileResult) std.mem.Allocator.Error![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    writer.print("{d} file(s) failed", .{files_failed}) catch |err| return convertWriterError(err);
    var first = true;
    for (file_results) |fr| {
        if (fr.status != .failed) continue;
        if (first) {
            writer.writeAll(": ") catch |err| return convertWriterError(err);
            first = false;
        } else {
            writer.writeAll("; ") catch |err| return convertWriterError(err);
        }
        if (fr.message) |m| {
            writer.writeAll(m) catch |err| return convertWriterError(err);
        } else {
            writer.writeAll(fr.path) catch |err| return convertWriterError(err);
        }
    }
    return allocator.dupe(u8, output.written()) catch |err| return err;
}

fn convertWriterError(_: anyerror) std.mem.Allocator.Error {
    return error.OutOfMemory;
}

fn sourceHash(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, hash.len * 2);
    for (hash, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return result;
}

test "pipeline analyzes a local repository and skips unchanged files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/greet.rb", .data = "class Greeter\n  def hello\n    puts 'hi'\n  end\nend\n" });

    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    const versions = AnalyzerVersions{
        .rgp_version = "0.1.0-dev",
        .prism_version = "1.9.0",
        .classifier_version = "1",
        .taxonomy_version = "1",
    };

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = buffer[0..len];

    var first = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.files_analyzed);
    try std.testing.expectEqual(@as(usize, 0), first.files_skipped);
    try std.testing.expectEqual(RunStatus.completed, first.status);
    try std.testing.expect(first.total_observations > 0);

    var second = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), second.files_analyzed);
    try std.testing.expectEqual(@as(usize, 1), second.files_skipped);
    try std.testing.expectEqual(RunStatus.completed, second.status);
}

test "changed files invalidate prior observations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/a.rb", .data = "[1].each {}\n" });

    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    const versions = AnalyzerVersions{
        .rgp_version = "0.1.0-dev",
        .prism_version = "1.9.0",
        .classifier_version = "1",
        .taxonomy_version = "1",
    };

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = buffer[0..len];

    var first = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.files_analyzed);
    const first_observations = try db.count("observations");

    try tmp.dir.writeFile(io, .{ .sub_path = "lib/a.rb", .data = "[1].each {}\n[2].each {}\n" });

    var second = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second.files_analyzed);
    try std.testing.expectEqual(@as(usize, 0), second.files_skipped);
    const second_observations = try db.count("observations");
    try std.testing.expect(second_observations > first_observations);
}

test "analyzer version change invalidates cached results" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/a.rb", .data = "puts 1\n" });

    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    const v1 = AnalyzerVersions{
        .rgp_version = "0.1.0-dev",
        .prism_version = "1.9.0",
        .classifier_version = "1",
        .taxonomy_version = "1",
    };
    const v2 = AnalyzerVersions{
        .rgp_version = "0.1.0-dev",
        .prism_version = "1.9.0",
        .classifier_version = "2",
        .taxonomy_version = "1",
    };

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = buffer[0..len];

    var first = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, v1);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.files_analyzed);

    var second = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, v2);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second.files_analyzed);
    try std.testing.expectEqual(@as(usize, 0), second.files_skipped);
}

test "deleted files remove observations atomically" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/a.rb", .data = "[1].each {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/b.rb", .data = "[2].each {}\n" });

    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    const versions = AnalyzerVersions{
        .rgp_version = "0.1.0-dev",
        .prism_version = "1.9.0",
        .classifier_version = "1",
        .taxonomy_version = "1",
    };

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = buffer[0..len];

    var first = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer first.deinit(std.testing.allocator);
    const first_count = try db.count("observations");
    try std.testing.expect(first_count > 0);

    // Simulate deletion by writing a directory with only a.rb.
    var tmp2 = std.testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    try tmp2.dir.createDirPath(io, "lib");
    try tmp2.dir.writeFile(io, .{ .sub_path = "lib/a.rb", .data = "[1].each {}\n" });
    var buffer2: [std.fs.max_path_bytes]u8 = undefined;
    const len2 = try tmp2.dir.realPath(io, &buffer2);
    const path2 = buffer2[0..len2];

    var second = try analyze(std.testing.allocator, io, &db, .{ .path = path2, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer second.deinit(std.testing.allocator);
    const second_count = try db.count("observations");
    try std.testing.expect(second_count < first_count);
}

test "stale running runs do not block retries or duplicate observations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/a.rb", .data = "[1].each {}\n" });

    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    const versions = AnalyzerVersions{
        .rgp_version = "0.1.0-dev",
        .prism_version = "1.9.0",
        .classifier_version = "1",
        .taxonomy_version = "1",
    };

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = buffer[0..len];

    var first = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer first.deinit(std.testing.allocator);
    const first_count = try db.count("observations");
    try std.testing.expect(first_count > 0);

    // Simulate an interrupted run by creating a stale 'running' record.
    const repo_id = try db.repositoryId(path);
    const commit_id = try db.commitId(repo_id, "0000000000000000000000000000000000000000");
    const stale = try db.beginRun(.{
        .repository_id = repo_id,
        .commit_id = commit_id,
        .rgp_version = versions.rgp_version,
        .prism_version = versions.prism_version,
        .classifier_version = versions.classifier_version,
        .taxonomy_version = versions.taxonomy_version,
    });
    try std.testing.expectEqual(@as(i64, 0), try db.runStatus(stale));

    var second = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), second.files_analyzed);
    try std.testing.expectEqual(@as(usize, 1), second.files_skipped);
    const second_count = try db.count("observations");
    try std.testing.expectEqual(first_count, second_count);

    // The stale run should have been marked failed by the successful run.
    try std.testing.expectEqual(@as(i64, 2), try db.runStatus(stale));
}

test "file parse failures are reported and do not abort the run" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/good.rb", .data = "[1].each {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/bad.rb", .data = "def missing(\n" });

    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    const versions = AnalyzerVersions{
        .rgp_version = "0.1.0-dev",
        .prism_version = "1.9.0",
        .classifier_version = "1",
        .taxonomy_version = "1",
    };

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = buffer[0..len];

    var result = try analyze(std.testing.allocator, io, &db, .{ .path = path, .origin = path, .commit_sha = "0000000000000000000000000000000000000000" }, versions);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.files_analyzed);
    try std.testing.expectEqual(@as(usize, 1), result.files_failed);
    try std.testing.expectEqual(RunStatus.failed, result.status);
    try std.testing.expect(result.failure != null);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.?, "bad.rb") != null);
}
