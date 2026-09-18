//! Offline, versioned SQLite persistence for deterministic RGP facts.
const std = @import("std");

const Db = opaque {};
const Stmt = opaque {};
extern fn sqlite3_open_v2([*:0]const u8, *?*Db, c_int, ?[*:0]const u8) c_int;
extern fn sqlite3_close_v2(*Db) c_int;
extern fn sqlite3_exec(*Db, [*:0]const u8, ?*const anyopaque, ?*?[*:0]u8, ?[*:0]const u8) c_int;
extern fn sqlite3_prepare_v2(*Db, [*:0]const u8, c_int, *?*Stmt, ?*?[*:0]const u8) c_int;
extern fn sqlite3_step(*Stmt) c_int;
extern fn sqlite3_finalize(*Stmt) c_int;
extern fn sqlite3_bind_int64(*Stmt, c_int, i64) c_int;
extern fn sqlite3_bind_text(*Stmt, c_int, [*]const u8, c_int, ?*const anyopaque) c_int;
extern fn sqlite3_bind_null(*Stmt, c_int) c_int;
extern fn sqlite3_column_int64(*Stmt, c_int) i64;
extern fn sqlite3_column_text(*Stmt, c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(*Stmt, c_int) c_int;

const ok = 0;
const row = 100;
const done = 101;
const transient: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const latest_schema_version = 1;

pub const Run = struct {
    repository_id: i64,
    commit_id: i64,
    snapshot_id: ?i64 = null,
    rgp_version: []const u8,
    prism_version: []const u8,
    classifier_version: []const u8,
    taxonomy_version: []const u8,
};
pub const Observation = struct {
    repository_id: i64,
    commit_id: i64,
    file_id: i64,
    start_offset: i64,
    end_offset: i64,
    line: i64,
    column: i64,
    node_kind: []const u8,
    raw_json: []const u8,
    construct_id: ?i64 = null,
    topic_id: ?i64 = null,
    name: ?[]const u8 = null,
    receiver_kind: ?[]const u8 = null,
};

pub const Database = struct {
    db: *Db,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const zpath = try allocator.dupeZ(u8, path);
        defer allocator.free(zpath);
        var raw: ?*Db = null;
        if (sqlite3_open_v2(zpath, &raw, 2 | 4, null) != ok) return error.Sqlite;
        errdefer _ = sqlite3_close_v2(raw.?);
        var result = Database{ .db = raw.?, .allocator = allocator };
        try result.exec("PRAGMA foreign_keys = ON;");
        try result.migrate();
        return result;
    }
    pub fn deinit(self: *Database) void {
        _ = sqlite3_close_v2(self.db);
        self.* = undefined;
    }

    /// Applies append-only migrations atomically; a newer on-disk schema is rejected.
    pub fn migrate(self: *Database) !void {
        try self.exec("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY CHECK(version > 0));");
        const current = try self.one("SELECT COALESCE(MAX(version), 0) FROM schema_migrations;", .{});
        if (current > latest_schema_version) return error.MigrationTooNew;
        if (current < 1) try self.exec("BEGIN IMMEDIATE;" ++ migration_1 ++ "INSERT INTO schema_migrations VALUES(1);COMMIT;");
    }
    pub fn schemaVersion(self: *Database) !i64 {
        return self.one("SELECT COALESCE(MAX(version), 0) FROM schema_migrations;", .{});
    }

    pub fn addRepository(self: *Database, origin: []const u8) !i64 {
        return self.insert("INSERT INTO repositories(origin) VALUES(?1);", .{origin});
    }
    pub fn repositoryId(self: *Database, origin: []const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM repositories WHERE origin=?1;", .{origin})) |id| return id;
        return self.addRepository(origin);
    }
    pub fn addCommit(self: *Database, repo: i64, sha: []const u8) !i64 {
        return self.insert("INSERT INTO commits(repository_id,sha) VALUES(?1,?2);", .{ repo, sha });
    }
    pub fn commitId(self: *Database, repo: i64, sha: []const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM commits WHERE repository_id=?1 AND sha=?2;", .{ repo, sha })) |id| return id;
        return self.addCommit(repo, sha);
    }
    pub fn addFile(self: *Database, commit: i64, path: []const u8, hash: []const u8) !i64 {
        return self.insert("INSERT INTO files(commit_id,path,source_sha256) VALUES(?1,?2,?3);", .{ commit, path, hash });
    }

    pub const FileRecord = struct { id: i64, hash: []const u8, changed: bool };

    /// Returns the existing file id when the path and hash match; otherwise
    /// updates the stored hash and returns the same id so callers can detect
    /// changed files and invalidate stale observations.
    pub fn upsertFile(self: *Database, commit: i64, path: []const u8, hash: []const u8) !FileRecord {
        if (try self.oneOrNull("SELECT id, source_sha256 FROM files WHERE commit_id=?1 AND path=?2;", .{ commit, path })) |id| {
            const stored_hash = try self.string("SELECT source_sha256 FROM files WHERE id=?1;", .{id});
            defer self.allocator.free(stored_hash);
            if (std.mem.eql(u8, stored_hash, hash)) return .{ .id = id, .hash = stored_hash, .changed = false };
            try self.execute("UPDATE files SET source_sha256=?1 WHERE id=?2;", .{ hash, id });
            return .{ .id = id, .hash = hash, .changed = true };
        }
        const id = try self.addFile(commit, path, hash);
        return .{ .id = id, .hash = hash, .changed = true };
    }

    pub fn addSnapshot(self: *Database, name: []const u8, manifest: []const u8) !i64 {
        return self.insert("INSERT INTO corpus_snapshots(name,manifest_sha256) VALUES(?1,?2);", .{ name, manifest });
    }
    pub fn snapshotId(self: *Database, name: []const u8, manifest: []const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM corpus_snapshots WHERE name=?1;", .{name})) |id| {
            const stored = try self.string("SELECT manifest_sha256 FROM corpus_snapshots WHERE id=?1;", .{id});
            defer self.allocator.free(stored);
            if (!std.mem.eql(u8, stored, manifest)) {
                try self.execute("UPDATE corpus_snapshots SET manifest_sha256=?1 WHERE id=?2;", .{ manifest, id });
            }
            return id;
        }
        return self.addSnapshot(name, manifest);
    }
    pub fn addConstruct(self: *Database, name: []const u8) !i64 {
        return self.insert("INSERT INTO constructs(name) VALUES(?1);", .{name});
    }
    pub fn getOrAddConstruct(self: *Database, name: []const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM constructs WHERE name=?1;", .{name})) |id| return id;
        return self.addConstruct(name);
    }
    pub fn addTopic(self: *Database, key: []const u8, label: []const u8) !i64 {
        return self.insert("INSERT INTO topics(key,label) VALUES(?1,?2);", .{ key, label });
    }

    /// A successful write contains a completed run and every raw observation;
    /// failures roll back the entire batch without losing pre-existing facts.
    pub fn persistCompleted(self: *Database, run_value: Run, observations: []const Observation) !i64 {
        try self.exec("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.exec("ROLLBACK;") catch {};
        const run_id = try self.beginRun(run_value);
        for (observations) |value| _ = try self.addObservation(run_id, value);
        try self.finishRun(run_id, .completed, null);
        try self.exec("COMMIT;");
        committed = true;
        return run_id;
    }

    /// Atomically replaces stale observations, removes observations for deleted
    /// files, and commits the run. Interruptions before COMMIT leave prior facts
    /// untouched because all writes happen inside one transaction.
    pub fn persistIncremental(self: *Database, run_value: Run, current_file_ids: []const i64, reanalyzed_file_ids: []const i64, observations: []const Observation) !i64 {
        try self.exec("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.exec("ROLLBACK;") catch {};

        try self.failStaleRuns(run_value.commit_id, "superseded by newer run");
        const run_id = try self.beginRun(run_value);

        for (reanalyzed_file_ids) |file_id| {
            try self.deleteObservationsForFile(file_id);
        }

        // Remove observations for files that no longer exist in this commit.
        const all_file_ids = try self.fileIdsForCommit(run_value.commit_id);
        defer self.allocator.free(all_file_ids);
        for (all_file_ids) |file_id| {
            if (std.mem.indexOfScalar(i64, current_file_ids, file_id) == null) {
                try self.deleteObservationsForFile(file_id);
            }
        }

        for (observations) |value| _ = try self.addObservation(run_id, value);
        try self.finishRun(run_id, .completed, null);
        try self.exec("COMMIT;");
        committed = true;
        return run_id;
    }

    fn fileIdsForCommit(self: *Database, commit_id: i64) ![]i64 {
        const sql = "SELECT id FROM files WHERE commit_id=?1;";
        const statement = try self.prepare(sql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, .{commit_id});
        var list = std.ArrayList(i64).empty;
        errdefer list.deinit(self.allocator);
        while (true) {
            const rc = sqlite3_step(statement);
            if (rc == done) break;
            if (rc != row) return error.Sqlite;
            try list.append(self.allocator, sqlite3_column_int64(statement, 0));
        }
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn beginRun(self: *Database, value: Run) !i64 {
        return self.insert("INSERT INTO analysis_runs(repository_id,commit_id,snapshot_id,status,rgp_version,prism_version,classifier_version,taxonomy_version) VALUES(?1,?2,?3,'running',?4,?5,?6,?7);", .{ value.repository_id, value.commit_id, value.snapshot_id, value.rgp_version, value.prism_version, value.classifier_version, value.taxonomy_version });
    }
    pub fn finishRun(self: *Database, id: i64, status: enum { completed, failed }, failure: ?[]const u8) !void {
        try self.execute("UPDATE analysis_runs SET status=?2,failure=?3,finished_at=unixepoch() WHERE id=?1 AND status='running';", .{ id, @tagName(status), failure });
    }
    pub fn addObservation(self: *Database, run_id: i64, value: Observation) !i64 {
        return self.insert("INSERT INTO observations(analysis_run_id,repository_id,commit_id,file_id,start_offset,end_offset,line,column,node_kind,raw_json,construct_id,topic_id,name,receiver_kind) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14);", .{ run_id, value.repository_id, value.commit_id, value.file_id, value.start_offset, value.end_offset, value.line, value.column, value.node_kind, value.raw_json, value.construct_id, value.topic_id, value.name, value.receiver_kind });
    }
    pub fn count(self: *Database, comptime table: []const u8) !i64 {
        return self.one("SELECT COUNT(*) FROM " ++ table ++ ";", .{});
    }
    pub fn runStatus(self: *Database, id: i64) !i64 {
        return self.one("SELECT CASE status WHEN 'running' THEN 0 WHEN 'completed' THEN 1 WHEN 'failed' THEN 2 END FROM analysis_runs WHERE id=?1;", .{id});
    }

    /// Returns true when there exists any completed run for this commit with
    /// the supplied analyzer-version signature that already contains
    /// observations for the file. This lets skipped files remain valid even when
    /// a newer run materialized no observations of its own.
    pub fn fileIsCached(self: *Database, file_id: i64, versions: Run) !bool {
        return (try self.oneOrNull(
            "SELECT 1 FROM observations o " ++
                "JOIN analysis_runs r ON o.analysis_run_id = r.id " ++
                "WHERE o.file_id=?1 AND r.commit_id=?2 AND r.status='completed' " ++
                "AND r.rgp_version=?3 AND r.prism_version=?4 AND r.classifier_version=?5 AND r.taxonomy_version=?6 " ++
                "LIMIT 1;",
            .{ file_id, versions.commit_id, versions.rgp_version, versions.prism_version, versions.classifier_version, versions.taxonomy_version },
        )) != null;
    }

    /// Removes observations for a specific file across all runs. Used when a
    /// file's content or analyzer version has changed and old observations must
    /// be replaced atomically within the run transaction.
    pub fn deleteObservationsForFile(self: *Database, file_id: i64) !void {
        try self.execute("DELETE FROM observations WHERE file_id=?1;", .{file_id});
    }

    /// Marks any still-running analysis for a commit as failed so retries do
    /// not mistake them for valid completed snapshots.
    pub fn failStaleRuns(self: *Database, commit_id: i64, message: []const u8) !void {
        try self.execute("UPDATE analysis_runs SET status='failed',failure=?1,finished_at=unixepoch() WHERE commit_id=?2 AND status='running';", .{ message, commit_id });
    }

    fn exec(self: *Database, sql: [:0]const u8) !void {
        if (sqlite3_exec(self.db, sql, null, null, null) != ok) return error.Sqlite;
    }
    fn prepare(self: *Database, sql: [:0]const u8) !*Stmt {
        var statement: ?*Stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &statement, null) != ok) return error.Sqlite;
        return statement.?;
    }
    fn execute(self: *Database, sql: [:0]const u8, values: anytype) !void {
        const statement = try self.prepare(sql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        if (sqlite3_step(statement) != done) return error.Sqlite;
    }
    fn insert(self: *Database, sql: [:0]const u8, values: anytype) !i64 {
        try self.execute(sql, values);
        return self.one("SELECT last_insert_rowid();", .{});
    }
    fn one(self: *Database, sql: [:0]const u8, values: anytype) !i64 {
        const statement = try self.prepare(sql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        if (sqlite3_step(statement) != row) return error.Sqlite;
        return sqlite3_column_int64(statement, 0);
    }
    fn oneOrNull(self: *Database, sql: [:0]const u8, values: anytype) !?i64 {
        const statement = try self.prepare(sql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        const rc = sqlite3_step(statement);
        if (rc == done) return null;
        if (rc != row) return error.Sqlite;
        return sqlite3_column_int64(statement, 0);
    }
    fn string(self: *Database, sql: [:0]const u8, values: anytype) ![]u8 {
        const statement = try self.prepare(sql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        if (sqlite3_step(statement) != row) return error.Sqlite;
        const ptr = sqlite3_column_text(statement, 0) orelse return error.Sqlite;
        const len = sqlite3_column_bytes(statement, 0);
        return try self.allocator.dupe(u8, ptr[0..@intCast(len)]);
    }
};
fn bindAll(statement: *Stmt, values: anytype) !void {
    inline for (values, 1..) |value, i| try bind(statement, @intCast(i), value);
}
fn bind(statement: *Stmt, index: c_int, value: anytype) !void {
    const rc = switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => sqlite3_bind_int64(statement, index, @intCast(value)),
        .optional => if (value) |some| return bind(statement, index, some) else sqlite3_bind_null(statement, index),
        .pointer => sqlite3_bind_text(statement, index, value.ptr, @intCast(value.len), transient),
        else => @compileError("unsupported SQLite bind type"),
    };
    if (rc != ok) return error.Sqlite;
}
const migration_1 =
    "CREATE TABLE repositories(id INTEGER PRIMARY KEY,origin TEXT NOT NULL UNIQUE);" ++
    "CREATE TABLE commits(id INTEGER PRIMARY KEY,repository_id INTEGER NOT NULL REFERENCES repositories(id),sha TEXT NOT NULL,UNIQUE(repository_id,sha));" ++
    "CREATE TABLE files(id INTEGER PRIMARY KEY,commit_id INTEGER NOT NULL REFERENCES commits(id),path TEXT NOT NULL,source_sha256 TEXT NOT NULL,UNIQUE(commit_id,path));" ++
    "CREATE TABLE corpus_snapshots(id INTEGER PRIMARY KEY,name TEXT NOT NULL UNIQUE,manifest_sha256 TEXT NOT NULL);" ++
    "CREATE TABLE constructs(id INTEGER PRIMARY KEY,name TEXT NOT NULL UNIQUE);" ++
    "CREATE TABLE topics(id INTEGER PRIMARY KEY,key TEXT NOT NULL UNIQUE,label TEXT NOT NULL);" ++
    "CREATE TABLE analysis_runs(id INTEGER PRIMARY KEY,repository_id INTEGER NOT NULL REFERENCES repositories(id),commit_id INTEGER NOT NULL REFERENCES commits(id),snapshot_id INTEGER REFERENCES corpus_snapshots(id),status TEXT NOT NULL CHECK(status IN('running','completed','failed')),failure TEXT,rgp_version TEXT NOT NULL,prism_version TEXT NOT NULL,classifier_version TEXT NOT NULL,taxonomy_version TEXT NOT NULL,started_at INTEGER NOT NULL DEFAULT(unixepoch()),finished_at INTEGER);" ++
    "CREATE TABLE observations(id INTEGER PRIMARY KEY,analysis_run_id INTEGER NOT NULL REFERENCES analysis_runs(id),repository_id INTEGER NOT NULL REFERENCES repositories(id),commit_id INTEGER NOT NULL REFERENCES commits(id),file_id INTEGER NOT NULL REFERENCES files(id),start_offset INTEGER NOT NULL,end_offset INTEGER NOT NULL CHECK(end_offset>=start_offset),line INTEGER NOT NULL CHECK(line>0),column INTEGER NOT NULL CHECK(column>0),node_kind TEXT NOT NULL,raw_json TEXT NOT NULL,construct_id INTEGER REFERENCES constructs(id),topic_id INTEGER REFERENCES topics(id),name TEXT,receiver_kind TEXT);" ++
    "CREATE TRIGGER run_provenance BEFORE INSERT ON analysis_runs WHEN (SELECT repository_id FROM commits WHERE id=NEW.commit_id)!=NEW.repository_id BEGIN SELECT RAISE(ABORT,'run provenance');END;" ++
    "CREATE TRIGGER observation_provenance BEFORE INSERT ON observations WHEN (SELECT repository_id FROM analysis_runs WHERE id=NEW.analysis_run_id)!=NEW.repository_id OR (SELECT commit_id FROM analysis_runs WHERE id=NEW.analysis_run_id)!=NEW.commit_id OR (SELECT commit_id FROM files WHERE id=NEW.file_id)!=NEW.commit_id BEGIN SELECT RAISE(ABORT,'observation provenance');END;" ++
    "CREATE INDEX observations_run_file ON observations(analysis_run_id,file_id);";

test "fresh migration stores versioned raw observations and provenance" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, 1), try db.schemaVersion());
    const repo = try db.addRepository("https://example.test/ruby.git");
    const commit = try db.addCommit(repo, "abc");
    const file = try db.addFile(commit, "a.rb", "source");
    const snapshot = try db.addSnapshot("offline-fixtures", "manifest");
    const construct = try db.addConstruct("method_call");
    const topic = try db.addTopic("methods", "Methods");
    const run = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .snapshot_id = snapshot, .rgp_version = "0.1", .prism_version = "1.9", .classifier_version = "1", .taxonomy_version = "1" }, &.{.{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{\"name\":\"puts\"}", .construct_id = construct, .topic_id = topic, .name = "puts" }});
    try std.testing.expectEqual(@as(i64, 1), try db.count("analysis_runs"));
    try std.testing.expectEqual(@as(i64, 1), try db.count("observations"));
    try std.testing.expectEqual(@as(i64, 1), try db.runStatus(run));
}
test "existing database migration is idempotent and bad batches roll back" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    try db.migrate();
    try db.migrate();
    const repo = try db.addRepository("https://example.test/ruby.git");
    const commit = try db.addCommit(repo, "abc");
    const run = Run{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" };
    const bad = Observation{ .repository_id = repo, .commit_id = commit, .file_id = 404, .start_offset = 0, .end_offset = 0, .line = 1, .column = 1, .node_kind = "PM_MISSING_NODE", .raw_json = "{}" };
    try std.testing.expectError(error.Sqlite, db.persistCompleted(run, &.{bad}));
    try std.testing.expectEqual(@as(i64, 0), try db.count("analysis_runs"));
    try std.testing.expectEqual(@as(i64, 0), try db.count("observations"));
}
test "failed runs are preserved separately from completed runs" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("https://example.test/ruby.git");
    const commit = try db.addCommit(repo, "abc");
    const id = try db.beginRun(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" });
    try db.finishRun(id, .failed, "parse diagnostic");
    try std.testing.expectEqual(@as(i64, 2), try db.runStatus(id));
}
