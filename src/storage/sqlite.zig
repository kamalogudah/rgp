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
extern fn sqlite3_reset(*Stmt) c_int;
extern fn sqlite3_clear_bindings(*Stmt) c_int;
extern fn sqlite3_bind_int64(*Stmt, c_int, i64) c_int;
extern fn sqlite3_bind_text(*Stmt, c_int, [*]const u8, c_int, ?*const anyopaque) c_int;
extern fn sqlite3_bind_null(*Stmt, c_int) c_int;
extern fn sqlite3_column_int64(*Stmt, c_int) i64;
extern fn sqlite3_column_text(*Stmt, c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(*Stmt, c_int) c_int;
extern fn sqlite3_last_insert_rowid(*Db) i64;

const ok = 0;
const row = 100;
const done = 101;
const transient: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const latest_schema_version = 13;

pub const LearnerProfile = enum { beginner, intermediate, senior };
pub const EvidenceDimension = enum { exposure, practice, demonstrated };

pub const Learner = struct { id: i64, external_id: []u8, display_name: []u8, profile: LearnerProfile };
pub const LessonProgress = struct { learner_id: i64, lesson_id: i64, status: []const u8, position: i64 = 0 };
pub const CompetencyState = struct { key: []u8, exposure: i64, practice: i64, demonstrated: i64 };
pub const CompetencyEvidence = struct {
    learner_id: i64,
    competency_id: i64,
    evidence_key: []const u8,
    dimension: EvidenceDimension,
    level: u8,
    source_type: []const u8,
    source_id: []const u8,
    detail: []const u8,
    attributed_to: []const u8,
};

pub const Run = struct {
    repository_id: i64,
    commit_id: i64,
    snapshot_id: ?i64 = null,
    rgp_version: []const u8,
    prism_version: []const u8,
    classifier_version: []const u8,
    taxonomy_version: []const u8,
    ruby_version: ?[]const u8 = null,
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
    block_syntax: ?[]const u8 = null,
};

pub const IdiomMatch = struct {
    observation_index: usize,
    idiom_id: []const u8,
    reason: []const u8,
    confidence: []const u8,
    classification: []const u8,
    rule_version: []const u8,
};

pub const StatisticsQuery = struct {
    snapshot_id: ?i64 = null,
    repository_id: ?i64 = null,
    repository_origin: ?[]const u8 = null,
    classification: ?[]const u8 = null,
    receiver_kind: ?[]const u8 = null,
    rgp_version: ?[]const u8 = null,
    prism_version: ?[]const u8 = null,
    classifier_version: ?[]const u8 = null,
    taxonomy_version: ?[]const u8 = null,
    ruby_version: ?[]const u8 = null,
    cohort: ?[]const u8 = null,
};

/// The filter values that produced a statistic, preserved so every reported
/// value can be reproduced from deterministic observations.
pub const AppliedFilter = struct {
    snapshot_id: ?i64 = null,
    repository_origin: ?[]u8 = null,
    classification: ?[]u8 = null,
    receiver_kind: ?[]u8 = null,
    rgp_version: ?[]u8 = null,
    prism_version: ?[]u8 = null,
    classifier_version: ?[]u8 = null,
    taxonomy_version: ?[]u8 = null,
    ruby_version: ?[]u8 = null,
    cohort: ?[]u8 = null,

    pub fn deinit(self: *AppliedFilter, allocator: std.mem.Allocator) void {
        if (self.repository_origin) |s| allocator.free(s);
        if (self.classification) |s| allocator.free(s);
        if (self.receiver_kind) |s| allocator.free(s);
        if (self.rgp_version) |s| allocator.free(s);
        if (self.prism_version) |s| allocator.free(s);
        if (self.classifier_version) |s| allocator.free(s);
        if (self.taxonomy_version) |s| allocator.free(s);
        if (self.ruby_version) |s| allocator.free(s);
        if (self.cohort) |s| allocator.free(s);
        self.* = .{};
    }
};

pub const SourceObservation = struct {
    id: i64,
    repository_id: i64,
    repository_origin: []u8,
    commit_sha: []u8,
    file_path: []u8,
    classification: []u8,
    line: i64,
    column: i64,
    raw_json: []u8,
    start_offset: i64,
    end_offset: i64,
    pub fn deinit(self: *SourceObservation, allocator: std.mem.Allocator) void {
        allocator.free(self.repository_origin);
        allocator.free(self.commit_sha);
        allocator.free(self.file_path);
        allocator.free(self.classification);
        allocator.free(self.raw_json);
    }
};

pub const ReadingQuestion = struct {
    id: i64,
    session_id: i64,
    question_key: []u8,
    construct: []u8,
    prompt: []u8,
    expected_fact: []u8,
    repository_origin: []u8,
    commit_sha: []u8,
    file_path: []u8,
    line: i64,
    column: i64,
    start_offset: i64,
    end_offset: i64,
    validated: bool,
    pub fn deinit(self: *ReadingQuestion, allocator: std.mem.Allocator) void {
        allocator.free(self.question_key);
        allocator.free(self.construct);
        allocator.free(self.prompt);
        allocator.free(self.expected_fact);
        allocator.free(self.repository_origin);
        allocator.free(self.commit_sha);
        allocator.free(self.file_path);
    }
};

pub const ProjectCount = struct { repository_id: i64, origin: []u8, count: i64 };

pub const Statistic = struct {
    construct: []u8,
    snapshot_id: ?i64,
    rgp_version: []u8,
    prism_version: []u8,
    classifier_version: []u8,
    taxonomy_version: []u8,
    filters: AppliedFilter,
    denominator: i64,
    count: i64,
    percentage: ?f64,
    projects: []ProjectCount,
    supporting_observations: []SourceObservation,
    pub fn deinit(self: *Statistic, allocator: std.mem.Allocator) void {
        allocator.free(self.construct);
        allocator.free(self.rgp_version);
        allocator.free(self.prism_version);
        allocator.free(self.classifier_version);
        allocator.free(self.taxonomy_version);
        self.filters.deinit(allocator);
        for (self.projects) |project| allocator.free(project.origin);
        allocator.free(self.projects);
        for (self.supporting_observations) |*source| source.deinit(allocator);
        allocator.free(self.supporting_observations);
    }
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
        if (current < 2) try self.exec("BEGIN IMMEDIATE;" ++ migration_2 ++ "INSERT INTO schema_migrations VALUES(2);COMMIT;");
        if (current < 3) try self.exec("BEGIN IMMEDIATE;" ++ migration_3 ++ "INSERT INTO schema_migrations VALUES(3);COMMIT;");
        if (current < 4) try self.exec("BEGIN IMMEDIATE;" ++ migration_4 ++ "INSERT INTO schema_migrations VALUES(4);COMMIT;");
        if (current < 5) try self.exec("BEGIN IMMEDIATE;" ++ migration_5 ++ "INSERT INTO schema_migrations VALUES(5);COMMIT;");
        if (current < 6) try self.exec("BEGIN IMMEDIATE;" ++ migration_6 ++ "INSERT INTO schema_migrations VALUES(6);COMMIT;");
        if (current < 7) try self.exec("BEGIN IMMEDIATE;" ++ migration_7 ++ "INSERT INTO schema_migrations VALUES(7);COMMIT;");
        if (current < 8) try self.exec("BEGIN IMMEDIATE;" ++ migration_8 ++ "INSERT INTO schema_migrations VALUES(8);COMMIT;");
        if (current < 9) try self.exec("BEGIN IMMEDIATE;" ++ migration_9 ++ "INSERT INTO schema_migrations VALUES(9);COMMIT;");
        if (current < 10) try self.exec("BEGIN IMMEDIATE;" ++ migration_10 ++ "INSERT INTO schema_migrations VALUES(10);COMMIT;");
        if (current < 11) try self.exec("BEGIN IMMEDIATE;" ++ migration_11 ++ "INSERT INTO schema_migrations VALUES(11);COMMIT;");
        if (current < 12) try self.exec("BEGIN IMMEDIATE;" ++ migration_12 ++ "INSERT INTO schema_migrations VALUES(12);COMMIT;");
        if (current < 13) try self.exec("BEGIN IMMEDIATE;" ++ migration_13 ++ "INSERT INTO schema_migrations VALUES(13);COMMIT;");
    }
    pub fn schemaVersion(self: *Database) !i64 {
        return self.one("SELECT COALESCE(MAX(version), 0) FROM schema_migrations;", .{});
    }

    pub fn upsertAgentSession(self: *Database, key: []const u8, adapter: []const u8, learner_id: ?[]const u8, topic: ?[]const u8, cwd: ?[]const u8, corpus_snapshot: ?[]const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM agent_sessions WHERE session_key=?1;", .{key})) |id| {
            try self.execute("UPDATE agent_sessions SET adapter=?2,learner_id=?3,topic=?4,cwd=?5,corpus_snapshot=?6,status='active',resumed_at=unixepoch(),generation=generation+1 WHERE id=?1;", .{ id, adapter, learner_id, topic, cwd, corpus_snapshot });
            return id;
        }
        return self.insert("INSERT INTO agent_sessions(session_key,adapter,learner_id,topic,cwd,corpus_snapshot,status,generation) VALUES(?1,?2,?3,?4,?5,?6,'active',0);", .{ key, adapter, learner_id, topic, cwd, corpus_snapshot });
    }

    pub fn appendAgentMessage(self: *Database, session_id: i64, role: []const u8, content: []const u8, complete: bool) !i64 {
        const complete_value: i64 = if (complete) 1 else 0;
        const safe = if (std.mem.indexOf(u8, content, "Bearer ") != null or std.mem.indexOf(u8, content, "api_key") != null or std.mem.indexOf(u8, content, "token=") != null) "[redacted credential]" else content;
        return self.insert("INSERT INTO agent_messages(session_id,role,content,complete) VALUES(?1,?2,?3,?4);", .{ session_id, role, safe, complete_value });
    }

    pub fn setAgentStatus(self: *Database, session_id: i64, status: []const u8) !void {
        try self.execute("UPDATE agent_sessions SET status=?2,resumed_at=unixepoch() WHERE id=?1;", .{ session_id, status });
    }

    pub fn agentSessionStatus(self: *Database, session_id: i64) ![]u8 {
        return self.string("SELECT status FROM agent_sessions WHERE id=?1;", .{session_id});
    }

    pub fn agentMessageCount(self: *Database, session_id: i64) !i64 {
        return self.one("SELECT COUNT(*) FROM agent_messages WHERE session_id=?1;", .{session_id});
    }

    pub fn addRepository(self: *Database, origin: []const u8) !i64 {
        return self.insert("INSERT INTO repositories(origin) VALUES(?1);", .{origin});
    }
    pub fn setRepositoryCohort(self: *Database, repository_id: i64, cohort: ?[]const u8) !void {
        try self.execute("UPDATE repositories SET cohort=?2 WHERE id=?1;", .{ repository_id, cohort });
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
        return self.addFileClassified(commit, path, hash, "production");
    }
    pub fn addFileClassified(self: *Database, commit: i64, path: []const u8, hash: []const u8, classification: []const u8) !i64 {
        return self.insert("INSERT INTO files(commit_id,path,source_sha256,classification) VALUES(?1,?2,?3,?4);", .{ commit, path, hash, classification });
    }

    pub const FileRecord = struct { id: i64, hash: []const u8, changed: bool };

    /// Returns the existing file id when the path and hash match; otherwise
    /// updates the stored hash and returns the same id so callers can detect
    /// changed files and invalidate stale observations.
    pub fn upsertFile(self: *Database, commit: i64, path: []const u8, hash: []const u8) !FileRecord {
        return self.upsertFileClassified(commit, path, hash, "production");
    }
    pub fn upsertFileClassified(self: *Database, commit: i64, path: []const u8, hash: []const u8, classification: []const u8) !FileRecord {
        if (try self.oneOrNull("SELECT id, source_sha256 FROM files WHERE commit_id=?1 AND path=?2;", .{ commit, path })) |id| {
            const stored_hash = try self.string("SELECT source_sha256 FROM files WHERE id=?1;", .{id});
            defer self.allocator.free(stored_hash);
            const old_classification = try self.string("SELECT classification FROM files WHERE id=?1;", .{id});
            defer self.allocator.free(old_classification);
            const changed = !std.mem.eql(u8, stored_hash, hash) or !std.mem.eql(u8, old_classification, classification);
            if (!changed) return .{ .id = id, .hash = stored_hash, .changed = false };
            try self.execute("UPDATE files SET source_sha256=?1,classification=?2 WHERE id=?3;", .{ hash, classification, id });
            return .{ .id = id, .hash = hash, .changed = true };
        }
        const id = try self.addFileClassified(commit, path, hash, classification);
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
        try self.invalidateStatisticsCache();
        const run_id = try self.beginRun(run_value);
        try self.addObservations(run_id, observations);
        try self.finishRun(run_id, .completed, null);
        try self.exec("COMMIT;");
        committed = true;
        return run_id;
    }

    /// Atomically replaces stale observations, removes observations for deleted
    /// files, and commits the run. Interruptions before COMMIT leave prior facts
    /// untouched because all writes happen inside one transaction.
    pub fn persistIncremental(self: *Database, run_value: Run, current_file_ids: []const i64, reanalyzed_file_ids: []const i64, observations: []const Observation) !i64 {
        return self.persistIncrementalWithIdioms(run_value, current_file_ids, reanalyzed_file_ids, observations, .{});
    }

    pub fn persistIncrementalWithIdioms(self: *Database, run_value: Run, current_file_ids: []const i64, reanalyzed_file_ids: []const i64, observations: []const Observation, idiom_matches: []const IdiomMatch) !i64 {
        try self.exec("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.exec("ROLLBACK;") catch {};
        try self.invalidateStatisticsCache();

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

        var observation_ids = std.ArrayList(i64).empty;
        defer observation_ids.deinit(self.allocator);
        try self.addObservationsReturningIds(run_id, observations, &observation_ids);
        for (idiom_matches) |match| {
            if (match.observation_index >= observation_ids.items.len) return error.Sqlite;
            _ = try self.addIdiomMatch(observation_ids.items[match.observation_index], match);
        }
        try self.finishRun(run_id, .completed, null);
        try self.exec("COMMIT;");
        committed = true;
        return run_id;
    }

    fn fileIdsForCommit(self: *Database, commit_id: i64) ![]i64 {
        const sql = "SELECT id FROM files WHERE commit_id=?1;";
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
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
        return self.insert("INSERT INTO analysis_runs(repository_id,commit_id,snapshot_id,status,rgp_version,prism_version,classifier_version,taxonomy_version,ruby_version) VALUES(?1,?2,?3,'running',?4,?5,?6,?7,?8);", .{ value.repository_id, value.commit_id, value.snapshot_id, value.rgp_version, value.prism_version, value.classifier_version, value.taxonomy_version, value.ruby_version });
    }
    pub fn finishRun(self: *Database, id: i64, status: enum { completed, failed }, failure: ?[]const u8) !void {
        try self.execute("UPDATE analysis_runs SET status=?2,failure=?3,finished_at=unixepoch() WHERE id=?1 AND status='running';", .{ id, @tagName(status), failure });
    }
    pub fn addObservation(self: *Database, run_id: i64, value: Observation) !i64 {
        return self.insert("INSERT INTO observations(analysis_run_id,repository_id,commit_id,file_id,start_offset,end_offset,line,column,node_kind,raw_json,construct_id,topic_id,name,receiver_kind,block_syntax) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15);", .{ run_id, value.repository_id, value.commit_id, value.file_id, value.start_offset, value.end_offset, value.line, value.column, value.node_kind, value.raw_json, value.construct_id, value.topic_id, value.name, value.receiver_kind, value.block_syntax });
    }

    const observation_insert_sql = "INSERT INTO observations(analysis_run_id,repository_id,commit_id,file_id,start_offset,end_offset,line,column,node_kind,raw_json,construct_id,topic_id,name,receiver_kind,block_syntax) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15);";

    fn prepareObservationInsert(self: *Database) !*Stmt {
        const zsql = try self.allocator.dupeZ(u8, observation_insert_sql);
        defer self.allocator.free(zsql);
        return self.prepare(zsql);
    }

    fn bindObservation(statement: *Stmt, run_id: i64, value: Observation) !void {
        try bindAll(statement, .{ run_id, value.repository_id, value.commit_id, value.file_id, value.start_offset, value.end_offset, value.line, value.column, value.node_kind, value.raw_json, value.construct_id, value.topic_id, value.name, value.receiver_kind, value.block_syntax });
    }

    fn addObservations(self: *Database, run_id: i64, values: []const Observation) !void {
        const statement = try self.prepareObservationInsert();
        defer _ = sqlite3_finalize(statement);
        for (values) |value| {
            try bindObservation(statement, run_id, value);
            if (sqlite3_step(statement) != done) return error.Sqlite;
            _ = sqlite3_reset(statement);
            _ = sqlite3_clear_bindings(statement);
        }
    }

    fn addObservationsReturningIds(self: *Database, run_id: i64, values: []const Observation, ids: *std.ArrayList(i64)) !void {
        const statement = try self.prepareObservationInsert();
        defer _ = sqlite3_finalize(statement);
        for (values) |value| {
            try bindObservation(statement, run_id, value);
            if (sqlite3_step(statement) != done) return error.Sqlite;
            try ids.append(self.allocator, sqlite3_last_insert_rowid(self.db));
            _ = sqlite3_reset(statement);
            _ = sqlite3_clear_bindings(statement);
        }
    }
    pub fn getOrAddIdiom(self: *Database, name: []const u8, rule_version: []const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM idioms WHERE name=?1 AND rule_version=?2;", .{ name, rule_version })) |id| return id;
        return self.insert("INSERT INTO idioms(name,title,rule_version) VALUES(?1,?1,?2);", .{ name, rule_version });
    }
    pub fn addIdiomMatch(self: *Database, observation_id: i64, value: IdiomMatch) !i64 {
        const idiom_id = try self.getOrAddIdiom(value.idiom_id, value.rule_version);
        return self.insert("INSERT INTO observation_idioms(observation_id,idiom_id,reason,confidence,classification,rule_version) VALUES(?1,?2,?3,?4,?5,?6);", .{ observation_id, idiom_id, value.reason, value.confidence, value.classification, value.rule_version });
    }
    pub fn recordExerciseAttemptAnalysis(self: *Database, learner_id: i64, exercise_key: []const u8, title: []const u8, prompt: []const u8, competency_key: []const u8, source: []const u8, outcome: []const u8, syntax_ok: bool, behavioral_check: []const u8, feedback: []const u8, deterministic: bool, source_sha256: []const u8, idiom_id: ?[]const u8, idiom_evidence: []const u8, corpus_evidence: []const u8) !i64 {
        const id = try self.recordExerciseAttempt(learner_id, exercise_key, title, prompt, competency_key, source, outcome, syntax_ok, behavioral_check, feedback, deterministic, source_sha256);
        try self.execute("UPDATE exercise_attempts SET idiom_id=?2,idiom_evidence=?3,corpus_evidence=?4 WHERE id=?1;", .{ id, idiom_id, idiom_evidence, corpus_evidence });
        return id;
    }

    pub fn recordExerciseProvenance(self: *Database, exercise_key: []const u8, expected_behavior: []const u8, provenance: []const u8, generation_status: []const u8) !void {
        try self.execute("UPDATE exercises SET expected_behavior=?2,generation_provenance=?3,generation_status=?4 WHERE key=?1;", .{ exercise_key, expected_behavior, provenance, generation_status });
    }

    pub fn recordExerciseAttempt(self: *Database, learner_id: i64, exercise_key: []const u8, title: []const u8, prompt: []const u8, competency_key: []const u8, source: []const u8, outcome: []const u8, syntax_ok: bool, behavioral_check: []const u8, feedback: []const u8, deterministic: bool, source_sha256: []const u8) !i64 {
        const exercise_id = if (try self.oneOrNull("SELECT id FROM exercises WHERE key=?1;", .{exercise_key})) |id| id else try self.insert("INSERT INTO exercises(key,title,prompt,competency_key) VALUES(?1,?2,?3,?4);", .{ exercise_key, title, prompt, competency_key });
        if (try self.oneOrNull("SELECT id FROM exercise_attempts WHERE learner_id=?1 AND exercise_id=?2 AND source_sha256=?3;", .{ learner_id, exercise_id, source_sha256 })) |id| return id;
        return self.insert("INSERT INTO exercise_attempts(learner_id,exercise_id,source,outcome,syntax_ok,behavioral_check,feedback,deterministic,source_sha256) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9);", .{ learner_id, exercise_id, source, outcome, @as(i64, if (syntax_ok) 1 else 0), behavioral_check, feedback, @as(i64, if (deterministic) 1 else 0), source_sha256 });
    }

    /// Reveal requests are monotonic for this exact learner attempt.
    pub fn revealAttempt(self: *Database, learner_id: i64, attempt_id: i64, level: i64) !i64 {
        if (level < 0 or level > 4) return error.InvalidRevealLevel;
        if (try self.oneOrNull("SELECT id FROM exercise_attempts WHERE id=?1 AND learner_id=?2;", .{ attempt_id, learner_id }) == null) return error.AttemptNotFound;
        try self.execute("INSERT INTO attempt_reveals(attempt_id,level) VALUES(?1,?2) ON CONFLICT(attempt_id) DO UPDATE SET level=MAX(level,excluded.level),updated_at=unixepoch();", .{ attempt_id, level });
        return self.one("SELECT level FROM attempt_reveals WHERE attempt_id=?1;", .{attempt_id});
    }

    pub fn attemptReveal(self: *Database, learner_id: i64, attempt_id: i64) !i64 {
        if (try self.oneOrNull("SELECT id FROM exercise_attempts WHERE id=?1 AND learner_id=?2;", .{ attempt_id, learner_id }) == null) return error.AttemptNotFound;
        return (try self.oneOrNull("SELECT level FROM attempt_reveals WHERE attempt_id=?1;", .{attempt_id})) orelse 0;
    }

    /// Read-only learner state used by deterministic recommendation logic.
    pub fn competencyStates(self: *Database, allocator: std.mem.Allocator, learner_id: i64) ![]CompetencyState {
        const sql: [:0]const u8 = "SELECT c.key,lc.exposure_level,lc.practice_level,lc.demonstrated_level FROM learner_competencies lc JOIN competencies c ON c.id=lc.competency_id WHERE lc.learner_id=?1 ORDER BY c.key;";
        const zsql = try allocator.dupeZ(u8, sql);
        defer allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, .{learner_id});
        var result = std.ArrayList(CompetencyState).empty;
        errdefer {
            for (result.items) |state| allocator.free(state.key);
            result.deinit(allocator);
        }
        while (true) {
            const rc = sqlite3_step(statement);
            if (rc == done) break;
            if (rc != row) return error.Sqlite;
            try result.append(allocator, .{ .key = try columnString(allocator, statement, 0), .exposure = sqlite3_column_int64(statement, 1), .practice = sqlite3_column_int64(statement, 2), .demonstrated = sqlite3_column_int64(statement, 3) });
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn completedLessonKeys(self: *Database, allocator: std.mem.Allocator, learner_id: i64) ![][]u8 {
        const sql: [:0]const u8 = "SELECT l.key FROM lesson_progress p JOIN lessons l ON l.id=p.lesson_id WHERE p.learner_id=?1 AND p.status='completed' ORDER BY l.id;";
        const zsql = try allocator.dupeZ(u8, sql);
        defer allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, .{learner_id});
        var result = std.ArrayList([]u8).empty;
        errdefer {
            for (result.items) |key| allocator.free(key);
            result.deinit(allocator);
        }
        while (true) {
            const rc = sqlite3_step(statement);
            if (rc == done) break;
            if (rc != row) return error.Sqlite;
            try result.append(allocator, try columnString(allocator, statement, 0));
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn count(self: *Database, comptime table: []const u8) !i64 {
        return self.one("SELECT COUNT(*) FROM " ++ table ++ ";", .{});
    }
    pub fn upsertLearner(self: *Database, external_id: []const u8, display_name: []const u8, profile: LearnerProfile) !i64 {
        if (try self.oneOrNull("SELECT id FROM learners WHERE external_id=?1;", .{external_id})) |id| {
            try self.execute("UPDATE learners SET display_name=?2,profile=?3,updated_at=unixepoch() WHERE id=?1;", .{ id, display_name, profileText(profile) });
            return id;
        }
        return self.insert("INSERT INTO learners(external_id,display_name,profile) VALUES(?1,?2,?3);", .{ external_id, display_name, profileText(profile) });
    }

    pub fn startLearningSession(self: *Database, learner_id: i64, session_key: []const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM learning_sessions WHERE learner_id=?1 AND session_key=?2;", .{ learner_id, session_key })) |id| {
            try self.execute("UPDATE learning_sessions SET resumed_at=unixepoch() WHERE id=?1;", .{id});
            return id;
        }
        return self.insert("INSERT INTO learning_sessions(learner_id,session_key) VALUES(?1,?2);", .{ learner_id, session_key });
    }

    pub fn startRepositoryReadingSession(self: *Database, learner_id: i64, session_key: []const u8, repository_origin: []const u8, commit_sha: []const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM repository_reading_sessions WHERE learner_id=?1 AND session_key=?2;", .{ learner_id, session_key })) |id| {
            try self.execute("UPDATE repository_reading_sessions SET repository_origin=?3,commit_sha=?4,resumed_at=unixepoch() WHERE id=?1;", .{ id, learner_id, repository_origin, commit_sha });
            return id;
        }
        return self.insert("INSERT INTO repository_reading_sessions(learner_id,session_key,repository_origin,commit_sha) VALUES(?1,?2,?3,?4);", .{ learner_id, session_key, repository_origin, commit_sha });
    }

    pub fn saveReadingQuestion(self: *Database, session_id: i64, question_key: []const u8, construct: []const u8, prompt: []const u8, expected_fact: []const u8, observation: SourceObservation) !i64 {
        if (try self.oneOrNull("SELECT id FROM repository_reading_questions WHERE session_id=?1 AND question_key=?2;", .{ session_id, question_key })) |id| return id;
        return self.insert("INSERT INTO repository_reading_questions(session_id,question_key,construct,prompt,expected_fact,observation_id,repository_origin,commit_sha,file_path,line,column,start_offset,end_offset) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13);", .{ session_id, question_key, construct, prompt, expected_fact, observation.id, observation.repository_origin, observation.commit_sha, observation.file_path, observation.line, observation.column, observation.start_offset, observation.end_offset });
    }

    pub fn recordReadingAnswer(self: *Database, learner_id: i64, question_id: i64, answer: []const u8, accepted: bool, detail: []const u8) !i64 {
        const value: i64 = if (accepted) 1 else 0;
        if (try self.oneOrNull("SELECT id FROM repository_reading_answers WHERE question_id=?1 AND learner_id=?2;", .{ question_id, learner_id })) |id| {
            try self.execute("UPDATE repository_reading_answers SET answer=?3,accepted=?4,detail=?5,updated_at=unixepoch() WHERE id=?1 AND learner_id=?2;", .{ id, learner_id, answer, value, detail });
            return id;
        }
        return self.insert("INSERT INTO repository_reading_answers(question_id,learner_id,answer,accepted,detail) VALUES(?1,?2,?3,?4,?5);", .{ question_id, learner_id, answer, value, detail });
    }

    pub fn recordLessonProgress(self: *Database, learner_id: i64, lesson_key: []const u8, title: []const u8, status: []const u8, position: i64) !i64 {
        const lesson_id = if (try self.oneOrNull("SELECT id FROM lessons WHERE key=?1;", .{lesson_key})) |id| blk: {
            try self.execute("UPDATE lessons SET title=?2 WHERE id=?1;", .{ id, title });
            break :blk id;
        } else try self.insert("INSERT INTO lessons(key,title) VALUES(?1,?2);", .{ lesson_key, title });
        if (try self.oneOrNull("SELECT id FROM lesson_progress WHERE learner_id=?1 AND lesson_id=?2;", .{ learner_id, lesson_id })) |progress_id| {
            try self.execute("UPDATE lesson_progress SET status=?3,position=?4,updated_at=unixepoch(),completed_at=CASE WHEN ?3=\"completed\" THEN unixepoch() ELSE completed_at END WHERE id=?1 AND learner_id=?2;", .{ progress_id, learner_id, status, position });
            return progress_id;
        }
        return self.insert("INSERT INTO lesson_progress(learner_id,lesson_id,status,position,completed_at) VALUES(?1,?2,?3,?4,CASE WHEN ?3=\"completed\" THEN unixepoch() ELSE NULL END);", .{ learner_id, lesson_id, status, position });
    }

    pub fn getOrAddCompetency(self: *Database, key: []const u8, title: []const u8) !i64 {
        if (try self.oneOrNull("SELECT id FROM competencies WHERE key=?1;", .{key})) |id| return id;
        return self.insert("INSERT INTO competencies(key,title) VALUES(?1,?2);", .{ key, title });
    }

    pub fn recordCompetencyEvidence(self: *Database, value: CompetencyEvidence) !i64 {
        if (value.level > 4) return error.InvalidCompetencyLevel;
        const dimension = dimensionText(value.dimension);
        if (try self.oneOrNull("SELECT id FROM competency_evidence WHERE learner_id=?1 AND evidence_key=?2;", .{ value.learner_id, value.evidence_key })) |id| {
            try self.execute("UPDATE competency_evidence SET competency_id=?3,dimension=?4,level=?5,source_type=?6,source_id=?7,detail=?8,attributed_to=?9,updated_at=unixepoch() WHERE id=?1 AND learner_id=?2;", .{ id, value.learner_id, value.competency_id, dimension, value.level, value.source_type, value.source_id, value.detail, value.attributed_to });
            try self.refreshCompetency(value.learner_id, value.competency_id);
            return id;
        }
        const id = try self.insert("INSERT INTO competency_evidence(learner_id,competency_id,evidence_key,dimension,level,source_type,source_id,detail,attributed_to) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9);", .{ value.learner_id, value.competency_id, value.evidence_key, dimension, value.level, value.source_type, value.source_id, value.detail, value.attributed_to });
        try self.refreshCompetency(value.learner_id, value.competency_id);
        return id;
    }

    fn refreshCompetency(self: *Database, learner_id: i64, competency_id: i64) !void {
        try self.execute("INSERT INTO learner_competencies(learner_id,competency_id) VALUES(?1,?2) ON CONFLICT(learner_id,competency_id) DO NOTHING;", .{ learner_id, competency_id });
        try self.execute("UPDATE learner_competencies SET exposure_level=COALESCE((SELECT MAX(level) FROM competency_evidence WHERE learner_id=?1 AND competency_id=?2 AND dimension=\"exposure\"),0),practice_level=COALESCE((SELECT MAX(level) FROM competency_evidence WHERE learner_id=?1 AND competency_id=?2 AND dimension=\"practice\"),0),demonstrated_level=COALESCE((SELECT MAX(level) FROM competency_evidence WHERE learner_id=?1 AND competency_id=?2 AND dimension=\"demonstrated\"),0),updated_at=unixepoch() WHERE learner_id=?1 AND competency_id=?2;", .{ learner_id, competency_id });
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
        try self.execute("DELETE FROM observation_idioms WHERE observation_id IN (SELECT id FROM observations WHERE file_id=?1);", .{file_id});
        try self.execute("DELETE FROM observations WHERE file_id=?1;", .{file_id});
    }

    /// Marks any still-running analysis for a commit as failed so retries do
    /// not mistake them for valid completed snapshots.
    pub fn failStaleRuns(self: *Database, commit_id: i64, message: []const u8) !void {
        try self.execute("UPDATE analysis_runs SET status='failed',failure=?1,finished_at=unixepoch() WHERE commit_id=?2 AND status='running';", .{ message, commit_id });
    }

    const AggregateCache = struct {
        denominator: i64,
        count: i64,
        rgp_version: []u8,
        prism_version: []u8,
        classifier_version: []u8,
        taxonomy_version: []u8,

        fn deinit(self: *AggregateCache, allocator: std.mem.Allocator) void {
            allocator.free(self.rgp_version);
            allocator.free(self.prism_version);
            allocator.free(self.classifier_version);
            allocator.free(self.taxonomy_version);
        }
    };

    fn invalidateStatisticsCache(self: *Database) !void {
        try self.exec("DELETE FROM statistics_cache;");
    }

    fn loadAggregateCache(self: *Database, key: []const u8) !?AggregateCache {
        const zsql = try self.allocator.dupeZ(u8, "SELECT denominator,count,rgp_version,prism_version,classifier_version,taxonomy_version FROM statistics_cache WHERE cache_key=?1;");
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, .{key});
        if (sqlite3_step(statement) == done) return null;
        if (sqlite3_column_text(statement, 2) == null) return error.Sqlite;
        return .{
            .denominator = sqlite3_column_int64(statement, 0),
            .count = sqlite3_column_int64(statement, 1),
            .rgp_version = try columnString(self.allocator, statement, 2),
            .prism_version = try columnString(self.allocator, statement, 3),
            .classifier_version = try columnString(self.allocator, statement, 4),
            .taxonomy_version = try columnString(self.allocator, statement, 5),
        };
    }

    fn storeAggregateCache(self: *Database, key: []const u8, value: AggregateCache) !void {
        try self.execute("INSERT OR REPLACE INTO statistics_cache(cache_key,denominator,count,rgp_version,prism_version,classifier_version,taxonomy_version) VALUES(?1,?2,?3,?4,?5,?6,?7);", .{ key, value.denominator, value.count, value.rgp_version, value.prism_version, value.classifier_version, value.taxonomy_version });
    }

    /// Derive counts, percentages, project distribution, and corpus denominators
    /// from completed observations. Each result carries the filter values that
    /// produced it, the analyzer versions that observed the facts, and the
    /// supporting source observations for provenance.
    pub fn queryStatistics(self: *Database, allocator: std.mem.Allocator, constructs: []const []const u8, q: StatisticsQuery) ![]Statistic {
        var result = std.ArrayList(Statistic).empty;
        errdefer {
            for (result.items) |*item| item.deinit(allocator);
            result.deinit(allocator);
        }
        for (constructs) |construct| {
            const common = .{ q.snapshot_id, q.repository_id, q.repository_origin, q.classification, q.receiver_kind, q.rgp_version, q.prism_version, q.classifier_version, q.taxonomy_version, q.ruby_version, q.cohort };
            const args = .{ q.snapshot_id, q.repository_id, q.repository_origin, q.classification, q.receiver_kind, q.rgp_version, q.prism_version, q.classifier_version, q.taxonomy_version, q.ruby_version, q.cohort, construct };
            const where = " FROM observations o JOIN analysis_runs r ON r.id=o.analysis_run_id JOIN files f ON f.id=o.file_id JOIN repositories p ON p.id=o.repository_id JOIN commits cm ON cm.id=o.commit_id JOIN constructs c ON c.id=o.construct_id WHERE r.status='completed' AND (?1 IS NULL OR r.snapshot_id=?1) AND (?2 IS NULL OR o.repository_id=?2) AND (?3 IS NULL OR p.origin=?3) AND (?4 IS NULL OR f.classification=?4) AND (?5 IS NULL OR o.receiver_kind=?5) AND (?6 IS NULL OR r.rgp_version=?6) AND (?7 IS NULL OR r.prism_version=?7) AND (?8 IS NULL OR r.classifier_version=?8) AND (?9 IS NULL OR r.taxonomy_version=?9) AND (?10 IS NULL OR r.ruby_version=?10) AND (?11 IS NULL OR p.cohort=?11)";
            const cache_key = try statisticsCacheKey(self.allocator, q, construct);
            defer self.allocator.free(cache_key);
            var aggregate = try self.loadAggregateCache(cache_key);
            if (aggregate == null) {
                aggregate = .{
                    .denominator = try self.one("SELECT COUNT(*)" ++ where, common),
                    .count = try self.one("SELECT COUNT(*)" ++ where ++ " AND c.name=?12", args),
                    .rgp_version = try self.string("SELECT COALESCE(MIN(r.rgp_version), char(117,110,107,110,111,119,110))" ++ where, common),
                    .prism_version = try self.string("SELECT COALESCE(MIN(r.prism_version), char(117,110,107,110,111,119,110))" ++ where, common),
                    .classifier_version = try self.string("SELECT COALESCE(MIN(r.classifier_version), char(117,110,107,110,111,119,110))" ++ where, common),
                    .taxonomy_version = try self.string("SELECT COALESCE(MIN(r.taxonomy_version), char(117,110,107,110,111,119,110))" ++ where, common),
                };
                try self.storeAggregateCache(cache_key, aggregate.?);
            }
            defer aggregate.?.deinit(self.allocator);
            const denominator = aggregate.?.denominator;
            const matches = aggregate.?.count;
            const version = try allocator.dupe(u8, aggregate.?.rgp_version);
            const prism_version = try allocator.dupe(u8, aggregate.?.prism_version);
            const classifier_version = try allocator.dupe(u8, aggregate.?.classifier_version);
            const taxonomy_version = try allocator.dupe(u8, aggregate.?.taxonomy_version);
            const projects = try self.projectCounts(allocator, "SELECT o.repository_id,p.origin,COUNT(*)" ++ where ++ " AND c.name=?12 GROUP BY o.repository_id,p.origin ORDER BY o.repository_id", args);
            const supporting = try self.sourceObservations(allocator, "SELECT o.id,o.repository_id,p.origin,coalesce(cm.sha, char(117,110,107,110,111,119,110)),f.path,f.classification,o.line,o.column,o.raw_json,o.start_offset,o.end_offset" ++ where ++ " AND c.name=?12 ORDER BY o.id", args);
            try result.append(allocator, .{
                .construct = try allocator.dupe(u8, construct),
                .snapshot_id = q.snapshot_id,
                .rgp_version = version,
                .prism_version = prism_version,
                .classifier_version = classifier_version,
                .taxonomy_version = taxonomy_version,
                .filters = try appliedFilter(allocator, q),
                .denominator = denominator,
                .count = matches,
                .percentage = if (denominator == 0) null else @as(f64, @floatFromInt(matches)) * 100.0 / @as(f64, @floatFromInt(denominator)),
                .projects = projects,
                .supporting_observations = supporting,
            });
        }
        return try result.toOwnedSlice(allocator);
    }

    /// Return constructs observed by completed runs under a repository/cohort filter, in stable order for reproducible concept maps.
    pub fn queryConstructNames(self: *Database, allocator: std.mem.Allocator, q: StatisticsQuery) ![][]u8 {
        const values = .{ q.snapshot_id, q.repository_id, q.repository_origin, q.classification, q.receiver_kind, q.rgp_version, q.prism_version, q.classifier_version, q.taxonomy_version, q.ruby_version, q.cohort };
        const where = " FROM observations o JOIN analysis_runs r ON r.id=o.analysis_run_id JOIN files f ON f.id=o.file_id JOIN repositories p ON p.id=o.repository_id JOIN constructs c ON c.id=o.construct_id WHERE r.status='completed' AND (?1 IS NULL OR r.snapshot_id=?1) AND (?2 IS NULL OR o.repository_id=?2) AND (?3 IS NULL OR p.origin=?3) AND (?4 IS NULL OR f.classification=?4) AND (?5 IS NULL OR o.receiver_kind=?5) AND (?6 IS NULL OR r.rgp_version=?6) AND (?7 IS NULL OR r.prism_version=?7) AND (?8 IS NULL OR r.classifier_version=?8) AND (?9 IS NULL OR r.taxonomy_version=?9) AND (?10 IS NULL OR r.ruby_version=?10) AND (?11 IS NULL OR p.cohort=?11)";
        const zsql = try self.allocator.dupeZ(u8, "SELECT DISTINCT c.name" ++ where ++ " ORDER BY c.name");
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        var list = std.ArrayList([]u8).empty;
        errdefer {
            for (list.items) |name| allocator.free(name);
            list.deinit(allocator);
        }
        while (true) {
            const rc = sqlite3_step(statement);
            if (rc == done) break;
            if (rc != row) return error.Sqlite;
            try list.append(allocator, try columnString(allocator, statement, 0));
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn findExamples(self: *Database, allocator: std.mem.Allocator, construct: []const u8, q: StatisticsQuery, limit: usize) ![]SourceObservation {
        const values = .{ q.snapshot_id, q.repository_id, q.repository_origin, q.classification, q.receiver_kind, q.rgp_version, q.prism_version, q.classifier_version, q.taxonomy_version, q.ruby_version, q.cohort, construct, @as(i64, @intCast(limit)) };
        const where = " FROM observations o JOIN analysis_runs r ON r.id=o.analysis_run_id JOIN files f ON f.id=o.file_id JOIN repositories p ON p.id=o.repository_id JOIN commits cm ON cm.id=o.commit_id JOIN constructs c ON c.id=o.construct_id WHERE r.status='completed' AND (?1 IS NULL OR r.snapshot_id=?1) AND (?2 IS NULL OR o.repository_id=?2) AND (?3 IS NULL OR p.origin=?3) AND (?4 IS NULL OR f.classification=?4) AND (?5 IS NULL OR o.receiver_kind=?5) AND (?6 IS NULL OR r.rgp_version=?6) AND (?7 IS NULL OR r.prism_version=?7) AND (?8 IS NULL OR r.classifier_version=?8) AND (?9 IS NULL OR r.taxonomy_version=?9) AND (?10 IS NULL OR r.ruby_version=?10) AND (?11 IS NULL OR p.cohort=?11) AND c.name=?12 ORDER BY p.origin,f.path,o.start_offset LIMIT ?13";
        return self.sourceObservations(allocator, "SELECT o.id,o.repository_id,p.origin,cm.sha,f.path,f.classification,o.line,o.column,o.raw_json,o.start_offset,o.end_offset" ++ where, values);
    }

    /// Returns true when any analysis run matching the query filters is not
    /// completed, so callers can warn that the corpus may be incomplete.
    pub fn hasIncompleteRuns(self: *Database, q: StatisticsQuery) !bool {
        const common = .{ q.snapshot_id, q.repository_id, q.repository_origin, q.rgp_version, q.prism_version, q.classifier_version, q.taxonomy_version };
        const where = " FROM analysis_runs r JOIN repositories p ON p.id=r.repository_id WHERE r.status!='completed' AND (?1 IS NULL OR r.snapshot_id=?1) AND (?2 IS NULL OR r.repository_id=?2) AND (?3 IS NULL OR p.origin=?3) AND (?4 IS NULL OR r.rgp_version=?4) AND (?5 IS NULL OR r.prism_version=?5) AND (?6 IS NULL OR r.classifier_version=?6) AND (?7 IS NULL OR r.taxonomy_version=?7)";
        return (try self.one("SELECT COUNT(*)" ++ where, common)) > 0;
    }

    fn projectCounts(self: *Database, allocator: std.mem.Allocator, sql: []const u8, values: anytype) ![]ProjectCount {
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        var list = std.ArrayList(ProjectCount).empty;
        errdefer {
            for (list.items) |item| allocator.free(item.origin);
            list.deinit(allocator);
        }
        while (true) {
            const rc = sqlite3_step(statement);
            if (rc == done) break;
            if (rc != row) return error.Sqlite;
            try list.append(allocator, .{ .repository_id = sqlite3_column_int64(statement, 0), .origin = try columnString(allocator, statement, 1), .count = sqlite3_column_int64(statement, 2) });
        }
        return try list.toOwnedSlice(allocator);
    }

    fn sourceObservations(self: *Database, allocator: std.mem.Allocator, sql: []const u8, values: anytype) ![]SourceObservation {
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        var list = std.ArrayList(SourceObservation).empty;
        errdefer {
            for (list.items) |*item| item.deinit(allocator);
            list.deinit(allocator);
        }
        while (true) {
            const rc = sqlite3_step(statement);
            if (rc == done) break;
            if (rc != row) return error.Sqlite;
            try list.append(allocator, .{ .id = sqlite3_column_int64(statement, 0), .repository_id = sqlite3_column_int64(statement, 1), .repository_origin = try columnString(allocator, statement, 2), .commit_sha = try columnString(allocator, statement, 3), .file_path = try columnString(allocator, statement, 4), .classification = try columnString(allocator, statement, 5), .line = sqlite3_column_int64(statement, 6), .column = sqlite3_column_int64(statement, 7), .raw_json = try columnString(allocator, statement, 8), .start_offset = sqlite3_column_int64(statement, 9), .end_offset = sqlite3_column_int64(statement, 10) });
        }
        return try list.toOwnedSlice(allocator);
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
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        if (sqlite3_step(statement) != done) return error.Sqlite;
    }
    fn insert(self: *Database, sql: [:0]const u8, values: anytype) !i64 {
        try self.execute(sql, values);
        return self.one("SELECT last_insert_rowid();", .{});
    }
    fn one(self: *Database, sql: [:0]const u8, values: anytype) !i64 {
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        if (sqlite3_step(statement) != row) return error.Sqlite;
        return sqlite3_column_int64(statement, 0);
    }
    fn oneOrNull(self: *Database, sql: [:0]const u8, values: anytype) !?i64 {
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        const rc = sqlite3_step(statement);
        if (rc == done) return null;
        if (rc != row) return error.Sqlite;
        return sqlite3_column_int64(statement, 0);
    }
    fn string(self: *Database, sql: [:0]const u8, values: anytype) ![]u8 {
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);
        const statement = try self.prepare(zsql);
        defer _ = sqlite3_finalize(statement);
        try bindAll(statement, values);
        if (sqlite3_step(statement) != row) return error.Sqlite;
        const ptr = sqlite3_column_text(statement, 0) orelse return error.Sqlite;
        const len = sqlite3_column_bytes(statement, 0);
        return try self.allocator.dupe(u8, ptr[0..@intCast(len)]);
    }
};
fn columnString(allocator: std.mem.Allocator, statement: *Stmt, index: c_int) ![]u8 {
    const ptr = sqlite3_column_text(statement, index) orelse return allocator.dupe(u8, "");
    const len = sqlite3_column_bytes(statement, index);
    return allocator.dupe(u8, ptr[0..@intCast(len)]);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) std.mem.Allocator.Error!?[]u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn appliedFilter(allocator: std.mem.Allocator, q: StatisticsQuery) std.mem.Allocator.Error!AppliedFilter {
    return .{
        .snapshot_id = q.snapshot_id,
        .repository_origin = try dupeOptional(allocator, q.repository_origin),
        .classification = try dupeOptional(allocator, q.classification),
        .receiver_kind = try dupeOptional(allocator, q.receiver_kind),
        .rgp_version = try dupeOptional(allocator, q.rgp_version),
        .prism_version = try dupeOptional(allocator, q.prism_version),
        .classifier_version = try dupeOptional(allocator, q.classifier_version),
        .taxonomy_version = try dupeOptional(allocator, q.taxonomy_version),
        .ruby_version = try dupeOptional(allocator, q.ruby_version),
        .cohort = try dupeOptional(allocator, q.cohort),
    };
}

fn statisticsCacheKey(allocator: std.mem.Allocator, q: StatisticsQuery, construct: []const u8) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    writer.print("{d};{d};", .{ q.snapshot_id orelse -1, q.repository_id orelse -1 }) catch return error.OutOfMemory;
    const values = .{ q.repository_origin, q.classification, q.receiver_kind, q.rgp_version, q.prism_version, q.classifier_version, q.taxonomy_version, q.ruby_version, q.cohort, @as(?[]const u8, construct) };
    inline for (values) |value| {
        if (value) |text| writer.print("{d}:", .{text.len}) catch return error.OutOfMemory else writer.writeAll("-:") catch return error.OutOfMemory;
        if (value) |text| writer.writeAll(text) catch return error.OutOfMemory;
        writer.writeByte(';') catch return error.OutOfMemory;
    }
    return allocator.dupe(u8, output.written());
}

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
fn profileText(value: LearnerProfile) []const u8 {
    return switch (value) {
        .beginner => "beginner",
        .intermediate => "intermediate",
        .senior => "senior",
    };
}
fn dimensionText(value: EvidenceDimension) []const u8 {
    return switch (value) {
        .exposure => "exposure",
        .practice => "practice",
        .demonstrated => "demonstrated",
    };
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
    "CREATE INDEX observations_run_file ON observations(analysis_run_id,file_id);" ++
    "CREATE INDEX observations_construct_run ON observations(construct_id,analysis_run_id);" ++
    "CREATE INDEX observations_file_run ON observations(file_id,analysis_run_id);" ++
    "CREATE INDEX analysis_runs_filter ON analysis_runs(status,snapshot_id,rgp_version,prism_version,classifier_version,taxonomy_version);";

const migration_2 = "ALTER TABLE observations ADD COLUMN block_syntax TEXT;";
const migration_3 = "ALTER TABLE files ADD COLUMN classification TEXT NOT NULL DEFAULT 'production';CREATE INDEX files_classification ON files(classification,commit_id);";
const migration_4 = "CREATE TABLE idioms(id INTEGER PRIMARY KEY,name TEXT NOT NULL,title TEXT NOT NULL,rule_version TEXT NOT NULL,UNIQUE(name,rule_version));" ++ "CREATE TABLE observation_idioms(observation_id INTEGER NOT NULL REFERENCES observations(id),idiom_id INTEGER NOT NULL REFERENCES idioms(id),reason TEXT NOT NULL,confidence TEXT NOT NULL,classification TEXT NOT NULL CHECK(classification IN('proven_equivalence', 'potential_alternative')),rule_version TEXT NOT NULL,PRIMARY KEY(observation_id,idiom_id,rule_version));" ++ "CREATE INDEX observation_idioms_idiom ON observation_idioms(idiom_id);";
const migration_5 = "ALTER TABLE analysis_runs ADD COLUMN ruby_version TEXT;ALTER TABLE repositories ADD COLUMN cohort TEXT;";
const migration_6 = "CREATE TABLE statistics_cache(cache_key TEXT PRIMARY KEY,denominator INTEGER NOT NULL,count INTEGER NOT NULL,rgp_version TEXT NOT NULL,prism_version TEXT NOT NULL,classifier_version TEXT NOT NULL,taxonomy_version TEXT NOT NULL);";
const migration_8 = "CREATE TABLE exercises(id INTEGER PRIMARY KEY,key TEXT NOT NULL UNIQUE,title TEXT NOT NULL,prompt TEXT NOT NULL,competency_key TEXT NOT NULL);" ++ "CREATE TABLE exercise_attempts(id INTEGER PRIMARY KEY,learner_id INTEGER NOT NULL REFERENCES learners(id),exercise_id INTEGER NOT NULL REFERENCES exercises(id),source TEXT NOT NULL,outcome TEXT NOT NULL,syntax_ok INTEGER NOT NULL,behavioral_check TEXT NOT NULL,feedback TEXT NOT NULL,deterministic INTEGER NOT NULL,source_sha256 TEXT NOT NULL,created_at INTEGER NOT NULL DEFAULT(unixepoch()),UNIQUE(learner_id,exercise_id,source_sha256));" ++ "CREATE INDEX exercise_attempts_lookup ON exercise_attempts(learner_id,exercise_id,created_at);";
const migration_9 = "ALTER TABLE exercise_attempts ADD COLUMN idiom_id TEXT;ALTER TABLE exercise_attempts ADD COLUMN idiom_evidence TEXT NOT NULL DEFAULT 'none';ALTER TABLE exercise_attempts ADD COLUMN corpus_evidence TEXT NOT NULL DEFAULT 'no corpus evidence claimed';";
const migration_10 = "CREATE TABLE attempt_reveals(attempt_id INTEGER PRIMARY KEY REFERENCES exercise_attempts(id),level INTEGER NOT NULL CHECK(level BETWEEN 0 AND 4),updated_at INTEGER NOT NULL DEFAULT(unixepoch()));";
const migration_11 = "CREATE TABLE agent_sessions(id INTEGER PRIMARY KEY,session_key TEXT NOT NULL UNIQUE,adapter TEXT NOT NULL,learner_id TEXT,topic TEXT,cwd TEXT,corpus_snapshot TEXT,status TEXT NOT NULL CHECK(status IN(\"active\",\"completed\",\"interrupted\")),generation INTEGER NOT NULL DEFAULT 0,started_at INTEGER NOT NULL DEFAULT(unixepoch()),resumed_at INTEGER);" ++ "CREATE TABLE agent_messages(id INTEGER PRIMARY KEY,session_id INTEGER NOT NULL REFERENCES agent_sessions(id),role TEXT NOT NULL CHECK(role IN(\"system\",\"user\",\"assistant\",\"tool\")),content TEXT NOT NULL,complete INTEGER NOT NULL CHECK(complete IN(0,1)),created_at INTEGER NOT NULL DEFAULT(unixepoch()));" ++ "CREATE TABLE agent_tool_calls(id INTEGER PRIMARY KEY,session_id INTEGER NOT NULL REFERENCES agent_sessions(id),tool TEXT NOT NULL,call_id TEXT NOT NULL,result_id TEXT,ok INTEGER NOT NULL,created_at INTEGER NOT NULL DEFAULT(unixepoch()));" ++ "CREATE INDEX agent_messages_lookup ON agent_messages(session_id,id);";
const migration_12 = "ALTER TABLE exercises ADD COLUMN expected_behavior TEXT NOT NULL DEFAULT 'returns user.name for every user';ALTER TABLE exercises ADD COLUMN generation_provenance TEXT NOT NULL DEFAULT 'reviewed-static';ALTER TABLE exercises ADD COLUMN generation_status TEXT NOT NULL DEFAULT 'reviewed';";
const migration_13 = "CREATE TABLE repository_reading_sessions(id INTEGER PRIMARY KEY,learner_id INTEGER NOT NULL REFERENCES learners(id),session_key TEXT NOT NULL,repository_origin TEXT NOT NULL,commit_sha TEXT NOT NULL,started_at INTEGER NOT NULL DEFAULT(unixepoch()),resumed_at INTEGER,UNIQUE(learner_id,session_key));" ++ "CREATE TABLE repository_reading_questions(id INTEGER PRIMARY KEY,session_id INTEGER NOT NULL REFERENCES repository_reading_sessions(id),question_key TEXT NOT NULL,construct TEXT NOT NULL,prompt TEXT NOT NULL,expected_fact TEXT NOT NULL,observation_id INTEGER NOT NULL REFERENCES observations(id),repository_origin TEXT NOT NULL,commit_sha TEXT NOT NULL,file_path TEXT NOT NULL,line INTEGER NOT NULL,column INTEGER NOT NULL,start_offset INTEGER NOT NULL,end_offset INTEGER NOT NULL,validated INTEGER NOT NULL DEFAULT 0,UNIQUE(session_id,question_key));" ++ "CREATE TABLE repository_reading_answers(id INTEGER PRIMARY KEY,question_id INTEGER NOT NULL REFERENCES repository_reading_questions(id),learner_id INTEGER NOT NULL REFERENCES learners(id),answer TEXT NOT NULL,accepted INTEGER NOT NULL,detail TEXT NOT NULL,created_at INTEGER NOT NULL DEFAULT(unixepoch()),updated_at INTEGER NOT NULL DEFAULT(unixepoch()),UNIQUE(question_id,learner_id));" ++ "CREATE INDEX repository_reading_questions_session ON repository_reading_questions(session_id);";
const migration_7 = "CREATE TABLE learners(id INTEGER PRIMARY KEY,external_id TEXT NOT NULL UNIQUE,display_name TEXT NOT NULL,profile TEXT NOT NULL CHECK(profile IN(\"beginner\",\"intermediate\",\"senior\")),created_at INTEGER NOT NULL DEFAULT(unixepoch()),updated_at INTEGER NOT NULL DEFAULT(unixepoch()));" ++
    "CREATE TABLE learning_sessions(id INTEGER PRIMARY KEY,learner_id INTEGER NOT NULL REFERENCES learners(id),session_key TEXT NOT NULL,started_at INTEGER NOT NULL DEFAULT(unixepoch()),resumed_at INTEGER,UNIQUE(learner_id,session_key));" ++
    "CREATE TABLE lessons(id INTEGER PRIMARY KEY,key TEXT NOT NULL UNIQUE,title TEXT NOT NULL);" ++
    "CREATE TABLE lesson_progress(id INTEGER PRIMARY KEY,learner_id INTEGER NOT NULL REFERENCES learners(id),lesson_id INTEGER NOT NULL REFERENCES lessons(id),status TEXT NOT NULL CHECK(status IN(\"not_started\",\"in_progress\",\"completed\")),position INTEGER NOT NULL DEFAULT 0,completed_at INTEGER,updated_at INTEGER NOT NULL DEFAULT(unixepoch()),UNIQUE(learner_id,lesson_id));" ++
    "CREATE TABLE competencies(id INTEGER PRIMARY KEY,key TEXT NOT NULL UNIQUE,title TEXT NOT NULL);" ++
    "CREATE TABLE learner_competencies(learner_id INTEGER NOT NULL REFERENCES learners(id),competency_id INTEGER NOT NULL REFERENCES competencies(id),exposure_level INTEGER NOT NULL DEFAULT 0 CHECK(exposure_level BETWEEN 0 AND 4),practice_level INTEGER NOT NULL DEFAULT 0 CHECK(practice_level BETWEEN 0 AND 4),demonstrated_level INTEGER NOT NULL DEFAULT 0 CHECK(demonstrated_level BETWEEN 0 AND 4),updated_at INTEGER NOT NULL DEFAULT(unixepoch()),PRIMARY KEY(learner_id,competency_id));" ++
    "CREATE TABLE competency_evidence(id INTEGER PRIMARY KEY,learner_id INTEGER NOT NULL REFERENCES learners(id),competency_id INTEGER NOT NULL REFERENCES competencies(id),evidence_key TEXT NOT NULL,dimension TEXT NOT NULL CHECK(dimension IN(\"exposure\",\"practice\",\"demonstrated\")),level INTEGER NOT NULL CHECK(level BETWEEN 0 AND 4),source_type TEXT NOT NULL,source_id TEXT NOT NULL,detail TEXT NOT NULL,attributed_to TEXT NOT NULL,created_at INTEGER NOT NULL DEFAULT(unixepoch()),updated_at INTEGER NOT NULL DEFAULT(unixepoch()),UNIQUE(learner_id,evidence_key));" ++
    "CREATE INDEX competency_evidence_lookup ON competency_evidence(learner_id,competency_id,dimension);";

test "fresh migration stores versioned raw observations and provenance" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, latest_schema_version), try db.schemaVersion());
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

test "statistics are reproducible, filtered, and carry source provenance" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("project-a");
    const commit = try db.addCommit(repo, "sha-a");
    const file = try db.addFileClassified(commit, "test/example_test.rb", "hash", "test");
    const snapshot = try db.addSnapshot("fixtures", "manifest-a");
    const construct = try db.addConstruct("map");
    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .snapshot_id = snapshot, .rgp_version = "rgp", .prism_version = "prism", .classifier_version = "classifier", .taxonomy_version = "taxonomy" }, &.{.{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 0, .end_offset = 3, .line = 4, .column = 2, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = construct, .receiver_kind = null }});
    var stats = try db.queryStatistics(std.testing.allocator, &.{"map"}, .{ .snapshot_id = snapshot, .classification = "test", .receiver_kind = "array" });
    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expectEqual(@as(i64, 0), stats[0].count);
    try std.testing.expectEqual(@as(i64, 0), stats[0].denominator);
    try std.testing.expect(stats[0].percentage == null);
    try std.testing.expectEqual(@as(usize, 0), stats[0].supporting_observations.len);

    for (stats) |*stat| stat.deinit(std.testing.allocator);
    std.testing.allocator.free(stats);

    stats = try db.queryStatistics(std.testing.allocator, &.{"map"}, .{ .snapshot_id = snapshot, .classification = "test" });
    try std.testing.expectEqual(@as(i64, 1), stats[0].count);
    try std.testing.expectEqual(@as(i64, 1), stats[0].denominator);
    try std.testing.expectEqual(@as(usize, 1), stats[0].projects.len);
    try std.testing.expectEqualStrings("test/example_test.rb", stats[0].supporting_observations[0].file_path);
    for (stats) |*stat| stat.deinit(std.testing.allocator);
    std.testing.allocator.free(stats);
    try std.testing.expectEqual(@as(i64, 2), try db.count("statistics_cache"));

    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .snapshot_id = snapshot, .rgp_version = "rgp", .prism_version = "prism", .classifier_version = "classifier", .taxonomy_version = "taxonomy" }, &.{});
    try std.testing.expectEqual(@as(i64, 0), try db.count("statistics_cache"));
}

test "empty corpus returns zero counts with null percentage and unknown versions" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    const stats = try db.queryStatistics(std.testing.allocator, &.{"each"}, .{});
    defer {
        for (stats) |*stat| stat.deinit(std.testing.allocator);
        std.testing.allocator.free(stats);
    }

    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expectEqual(@as(i64, 0), stats[0].count);
    try std.testing.expectEqual(@as(i64, 0), stats[0].denominator);
    try std.testing.expect(stats[0].percentage == null);
    try std.testing.expectEqualStrings("unknown", stats[0].rgp_version);
    try std.testing.expectEqual(@as(usize, 0), stats[0].projects.len);
    try std.testing.expectEqual(@as(usize, 0), stats[0].supporting_observations.len);
}

test "production and test observations are not mixed without an explicit filter" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("project-b");
    const commit = try db.addCommit(repo, "sha-b");
    const prod_file = try db.addFileClassified(commit, "lib/a.rb", "hash1", "production");
    const test_file = try db.addFileClassified(commit, "test/a_test.rb", "hash2", "test");
    const construct = try db.addConstruct("each");
    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" }, &.{
        .{ .repository_id = repo, .commit_id = commit, .file_id = prod_file, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = construct },
        .{ .repository_id = repo, .commit_id = commit, .file_id = test_file, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = construct },
    });

    const unfiltered = try db.queryStatistics(std.testing.allocator, &.{"each"}, .{});
    defer {
        for (unfiltered) |*stat| stat.deinit(std.testing.allocator);
        std.testing.allocator.free(unfiltered);
    }
    try std.testing.expectEqual(@as(i64, 2), unfiltered[0].denominator);
    try std.testing.expectEqual(@as(i64, 2), unfiltered[0].count);

    const prod_only = try db.queryStatistics(std.testing.allocator, &.{"each"}, .{ .classification = "production" });
    defer {
        for (prod_only) |*stat| stat.deinit(std.testing.allocator);
        std.testing.allocator.free(prod_only);
    }
    try std.testing.expectEqual(@as(i64, 1), prod_only[0].denominator);
    try std.testing.expectEqual(@as(i64, 1), prod_only[0].count);

    const test_only = try db.queryStatistics(std.testing.allocator, &.{"each"}, .{ .classification = "test" });
    defer {
        for (test_only) |*stat| stat.deinit(std.testing.allocator);
        std.testing.allocator.free(test_only);
    }
    try std.testing.expectEqual(@as(i64, 1), test_only[0].denominator);
    try std.testing.expectEqual(@as(i64, 1), test_only[0].count);
}

test "unknown receiver kind is not mixed into known receiver contexts" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("project-c");
    const commit = try db.addCommit(repo, "sha-c");
    const file = try db.addFile(commit, "lib/a.rb", "hash");
    const construct = try db.addConstruct("size");
    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" }, &.{
        .{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = construct, .receiver_kind = "array" },
        .{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 5, .end_offset = 9, .line = 2, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = construct, .receiver_kind = "other" },
    });

    const array_only = try db.queryStatistics(std.testing.allocator, &.{"size"}, .{ .receiver_kind = "array" });
    defer {
        for (array_only) |*stat| stat.deinit(std.testing.allocator);
        std.testing.allocator.free(array_only);
    }
    try std.testing.expectEqual(@as(i64, 1), array_only[0].denominator);
    try std.testing.expectEqual(@as(i64, 1), array_only[0].count);

    const unknown_only = try db.queryStatistics(std.testing.allocator, &.{"size"}, .{ .receiver_kind = "other" });
    defer {
        for (unknown_only) |*stat| stat.deinit(std.testing.allocator);
        std.testing.allocator.free(unknown_only);
    }
    try std.testing.expectEqual(@as(i64, 1), unknown_only[0].denominator);
    try std.testing.expectEqual(@as(i64, 1), unknown_only[0].count);
}

test "incomplete runs are detected independently of completed observations" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("project-d");
    const commit = try db.addCommit(repo, "sha-d");
    const file = try db.addFile(commit, "lib/a.rb", "hash");
    const construct = try db.addConstruct("each");
    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" }, &.{.{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = construct }});

    const stale = try db.beginRun(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" });
    try std.testing.expect(try db.hasIncompleteRuns(.{}));
    try db.finishRun(stale, .failed, "interrupted");
    try std.testing.expect(try db.hasIncompleteRuns(.{}));

    const stats = try db.queryStatistics(std.testing.allocator, &.{"each"}, .{});
    defer {
        for (stats) |*stat| stat.deinit(std.testing.allocator);
        std.testing.allocator.free(stats);
    }
    try std.testing.expectEqual(@as(i64, 1), stats[0].count);
}

test "learner state survives restart and evidence retries are idempotent" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const learner = try db.upsertLearner("learner-1", "Ada", .beginner);
    _ = try db.recordLessonProgress(learner, "arrays", "Arrays", "in_progress", 3);
    _ = try db.recordLessonProgress(learner, "arrays", "Arrays", "completed", 9);
    try std.testing.expectEqual(@as(i64, 1), try db.count("learners"));
    try std.testing.expectEqual(@as(i64, 1), try db.count("lesson_progress"));
    const competency = try db.getOrAddCompetency("arrays", "Arrays");
    const evidence = CompetencyEvidence{ .learner_id = learner, .competency_id = competency, .evidence_key = "exercise-1", .dimension = .practice, .level = 2, .source_type = "exercise_attempt", .source_id = "attempt-1", .detail = "used each", .attributed_to = "learner" };
    const first = try db.recordCompetencyEvidence(evidence);
    const second = try db.recordCompetencyEvidence(evidence);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(i64, 1), try db.count("competency_evidence"));
    try std.testing.expectEqual(@as(i64, 1), try db.count("learner_competencies"));
    try std.testing.expectEqual(@as(i64, 1), try db.startLearningSession(learner, "session-1"));
    try std.testing.expectEqual(@as(i64, 1), try db.startLearningSession(learner, "session-1"));
    try std.testing.expectEqual(@as(i64, 1), try db.count("learning_sessions"));
}
