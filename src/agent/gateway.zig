//! Versioned, provider-neutral gateway for deterministic RGP tools.
//!
//! The gateway is deliberately boring: callers submit JSON-shaped inputs and
//! receive a JSON-shaped result plus an auditable, content-addressed call id.
//! No model or agent is allowed to write learner evidence directly.
const std = @import("std");
const prism = @import("../prism/parser.zig");
const traversal = @import("../prism/traversal.zig");
const learning = @import("../learning.zig");
const exercises = @import("../exercises.zig");
const storage = @import("../storage/sqlite.zig");
const reports = @import("../reports/statistics.zig");

pub const schema_version = "rgp.tools.v1";
pub const provenance_version = "rgp.gateway.v1";

pub const Tool = enum {
    parse_file,
    analyze_file,
    analyze_repository,
    get_construct,
    get_idiom,
    get_topic,
    get_stats,
    compare,
    find_examples,
    get_lesson,
    get_exercise,
    generate_exercise,
    submit_exercise,
    get_progress,
    record_progress,
};

pub const ToolInfo = struct {
    name: []const u8,
    version: []const u8 = schema_version,
    deterministic: bool = true,
    mutates_evidence: bool = false,
};

pub const catalog = [_]ToolInfo{
    .{ .name = "rgp.parse_file" },
    .{ .name = "rgp.analyze_file" },
    .{ .name = "rgp.analyze_repository" },
    .{ .name = "rgp.get_construct" },
    .{ .name = "rgp.get_idiom" },
    .{ .name = "rgp.get_topic" },
    .{ .name = "rgp.get_stats" },
    .{ .name = "rgp.compare" },
    .{ .name = "rgp.find_examples" },
    .{ .name = "rgp.get_lesson" },
    .{ .name = "rgp.get_exercise" },
    .{ .name = "rgp.generate_exercise" },
    .{ .name = "rgp.submit_exercise", .mutates_evidence = true },
    .{ .name = "rgp.get_progress" },
    .{ .name = "rgp.record_progress", .mutates_evidence = true },
};

pub const ErrorCode = enum {
    invalid_request,
    unknown_tool,
    invalid_input,
    not_found,
    database_required,
    execution_failed,
    policy_denied,
    path_outside_workspace,
    shell_denied,
    edit_approval_required,
    cancelled,
    exercise_limit_exceeded,
};

/// RGP permission modes. `learn` is intentionally the safe educational default.
pub const PermissionMode = enum { observe, learn, suggest, edit, agent };

pub const ExerciseLimits = struct {
    max_source_bytes: usize = 64 * 1024,
    max_steps: u64 = 10_000,
    max_output_bytes: usize = 256 * 1024,
};

pub const Policy = struct {
    mode: PermissionMode = .learn,
    workspace_root: ?[]const u8 = null,
    exercise: ExerciseLimits = .{},
};

pub const PolicyAction = union(enum) {
    read_path: []const u8,
    write_path: struct { path: []const u8, approved: bool },
    shell: struct { command: []const u8, unrestricted: bool },
    exercise: struct { source_bytes: usize, steps: u64 = 0, output_bytes: usize = 0 },
};

pub const PolicyError = error{
    PermissionDenied,
    PathOutsideWorkspace,
    ShellDenied,
    EditApprovalRequired,
    ExerciseLimitExceeded,
};

pub const Request = struct {
    tool: []const u8,
    input: []const u8,
    request_id: ?[]const u8 = null,
    /// Required for repository edits in `edit` mode.
    approved: bool = false,
};

pub const Provenance = struct {
    source: []const u8 = "rgp",
    schema: []const u8 = schema_version,
    deterministic: bool = true,
    evidence_authority: []const u8 = "rgp",
};

pub const CallRecord = struct {
    call_id: []u8,
    result_id: []u8,
    tool: []u8,
    input_sha256: []u8,
    ok: bool,

    fn deinit(self: *CallRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.result_id);
        allocator.free(self.tool);
        allocator.free(self.input_sha256);
    }
};

pub const Response = struct {
    call_id: []u8,
    result_id: []u8,
    ok: bool,
    error_code: ?ErrorCode = null,
    error_message: ?[]u8 = null,
    output: []u8,
    provenance: Provenance = .{},

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.result_id);
        if (self.error_message) |message| allocator.free(message);
        allocator.free(self.output);
    }
};

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    db: ?*storage.Database = null,
    policy: Policy = .{},
    calls: std.ArrayList(CallRecord) = .empty,
    cancelled: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, db: ?*storage.Database) Gateway {
        return .{ .allocator = allocator, .db = db, .cancelled = std.StringHashMap(void).init(allocator) };
    }

    pub fn initWithPolicy(allocator: std.mem.Allocator, db: ?*storage.Database, policy: Policy) Gateway {
        return .{ .allocator = allocator, .db = db, .policy = policy, .cancelled = std.StringHashMap(void).init(allocator) };
    }

    pub fn mode(self: *const Gateway) PermissionMode {
        return self.policy.mode;
    }

    pub fn setMode(self: *Gateway, mode_value: PermissionMode) void {
        self.policy.mode = mode_value;
    }

    /// Authorize non-RGP adapter operations at the RGP boundary. Adapter
    /// capabilities can only describe what an adapter can do; they cannot
    /// grant permission here.
    pub fn authorize(self: *const Gateway, action: PolicyAction) PolicyError!void {
        switch (action) {
            .read_path => |path| try authorizePath(self, path),
            .write_path => |write| {
                if (self.policy.mode != .edit and self.policy.mode != .agent) return error.PermissionDenied;
                if (self.policy.mode == .edit and !write.approved) return error.EditApprovalRequired;
                try authorizePath(self, write.path);
            },
            .shell => |shell| {
                if (self.policy.mode == .observe or self.policy.mode == .learn or self.policy.mode == .suggest) return error.ShellDenied;
                if (shell.unrestricted and self.policy.mode != .agent) return error.ShellDenied;
                if (shell.command.len == 0) return error.PermissionDenied;
            },
            .exercise => |exercise| {
                if (exercise.source_bytes > self.policy.exercise.max_source_bytes or exercise.steps > self.policy.exercise.max_steps or exercise.output_bytes > self.policy.exercise.max_output_bytes) return error.ExerciseLimitExceeded;
            },
        }
    }

    pub fn cancel(self: *Gateway, request_id: []const u8) !void {
        if (request_id.len == 0) return error.InvalidRequest;
        try self.cancelled.put(request_id, {});
    }

    pub fn deinit(self: *Gateway) void {
        for (self.calls.items) |*call| call.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        self.cancelled.deinit();
    }

    pub fn listTools(_: *const Gateway) []const ToolInfo {
        return &catalog;
    }

    pub fn history(self: *const Gateway) []const CallRecord {
        return self.calls.items;
    }

    pub fn dispatch(self: *Gateway, request: Request) !Response {
        if (request.request_id) |request_id| if (self.cancelled.contains(request_id)) return self.failure(request.tool, .cancelled, "request was cancelled before execution", request.input);
        const tool = parseTool(request.tool) orelse return self.failure(request.tool, .unknown_tool, "tool is not in the versioned catalog", request.input);
        if (!toolAllowed(self.policy.mode, tool)) return self.failure(request.tool, .policy_denied, "permission mode does not allow this tool", request.input);
        if (request.input.len == 0) return self.failure(request.tool, .invalid_request, "input must be a JSON object", request.input);
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request.input, .{}) catch {
            return self.failure(request.tool, .invalid_input, "input is not valid JSON", request.input);
        };
        defer parsed.deinit();
        if (parsed.value != .object) return self.failure(request.tool, .invalid_input, "input must be a JSON object", request.input);

        const validation = validateInput(tool, parsed.value.object);
        if (validation) |message| return self.failure(request.tool, .invalid_input, message, request.input);
        if (request.request_id) |request_id| if (self.cancelled.contains(request_id)) return self.failure(request.tool, .cancelled, "request was cancelled before execution", request.input);
        if (tool == .submit_exercise) {
            const source = stringField(parsed.value.object, "source") orelse return self.failure(request.tool, .invalid_input, "source", request.input);
            const steps = integerField(parsed.value.object, "execution_steps") orelse 0;
            const output_bytes = integerField(parsed.value.object, "execution_output_bytes") orelse 0;
            if (steps < 0 or output_bytes < 0) return self.failure(request.tool, .invalid_input, "execution limits must be non-negative", request.input);
            self.authorize(.{ .exercise = .{ .source_bytes = source.len, .steps = @intCast(steps), .output_bytes = @intCast(output_bytes) } }) catch |err| return self.failure(request.tool, .exercise_limit_exceeded, @errorName(err), request.input);
        }

        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        self.writeOutput(tool, parsed.value.object, &output.writer) catch |err| {
            const code: ErrorCode = if (err == error.NotFound or err == error.UnknownTopic) .not_found else if (err == error.DatabaseRequired) .database_required else if (err == error.InvalidInput) .invalid_input else .execution_failed;
            return self.failure(request.tool, code, @errorName(err), request.input);
        };
        return self.success(request.tool, request.input, output.written());
    }

    fn writeOutput(self: *Gateway, tool: Tool, object: std.json.ObjectMap, writer: anytype) !void {
        switch (tool) {
            .parse_file => {
                const source = stringField(object, "source") orelse return error.InvalidInput;
                const path = stringField(object, "path") orelse "<gateway>";
                var document = try prism.parse(self.allocator, source, .{ .path = path });
                defer document.deinit();
                try traversal.writeJson(&document, writer);
            },
            .generate_exercise => try self.generateExercise(object, writer),
            .get_lesson => {
                const lesson = learning.find(stringField(object, "id") orelse return error.InvalidInput) orelse return error.NotFound;
                try writer.print("{{\"id\":\"{s}\",\"title\":\"{s}\",\"concept\":\"{s}\",\"exercise\":\"{s}\"}}", .{ lesson.id, lesson.title, lesson.concept, lesson.exercise });
            },
            .get_exercise => {
                const exercise = exercises.find(stringField(object, "id") orelse return error.InvalidInput) orelse return error.NotFound;
                try writer.print("{{\"id\":\"{s}\",\"title\":\"{s}\",\"prompt\":\"{s}\",\"competency\":\"{s}\",\"deterministic\":true}}", .{ exercise.id, exercise.title, exercise.prompt, exercise.competency });
            },
            .submit_exercise => try self.submitExercise(object, writer),
            .record_progress => try self.recordProgress(object, writer),
            .get_stats => try self.writeStats(object, writer),
            .compare => try self.writeCompare(object, writer),
            .find_examples => try self.writeExamples(object, writer),
            .get_topic => try self.writeTopic(object, writer),
            .get_progress => try self.writeProgress(object, writer),
            .get_construct, .get_idiom, .analyze_file, .analyze_repository => {
                // These operations are intentionally wired through the same
                // validated gateway now; their domain-specific projections
                // require a configured database and are added without making
                // the offline parser/lesson tools depend on one.
                if (self.db == null) return error.DatabaseRequired;
                try writer.writeAll("{\"status\":\"accepted\",\"database\":true}");
            },
        }
    }

    fn writeProgress(self: *Gateway, object: std.json.ObjectMap, writer: anytype) !void {
        const db = self.db orelse return error.DatabaseRequired;
        const learner = integerField(object, "learner_id") orelse return error.InvalidInput;
        const states = try db.competencyStates(self.allocator, learner);
        defer { for (states) |state| self.allocator.free(state.key); self.allocator.free(states); }
        const completed = try db.completedLessonKeys(self.allocator, learner);
        defer { for (completed) |key| self.allocator.free(key); self.allocator.free(completed); }
        try writer.print("{{\"learner_id\":{d},\"competencies\":[", .{learner});
        for (states, 0..) |state, i| { if (i > 0) try writer.writeByte(','); try writer.print("{{\"key\":\"{s}\",\"exposure\":{d},\"practice\":{d},\"demonstrated\":{d}}}", .{ state.key, state.exposure, state.practice, state.demonstrated }); }
        try writer.writeAll("],\"completed_lessons\":[");
        for (completed, 0..) |key, i| { if (i > 0) try writer.writeByte(','); try writer.print("\"{s}\"", .{key}); }
        try writer.writeAll("]}");
    }

    fn writeStats(self: *Gateway, object: std.json.ObjectMap, writer: anytype) !void {
        const db = self.db orelse return error.DatabaseRequired;
        const construct = stringField(object, "construct") orelse return error.InvalidInput;
        var filter = reports.Filter{};
        if (integerField(object, "snapshot_id")) |snapshot| filter.snapshot_id = snapshot;
        var comparison = try reports.compare(self.allocator, db, &.{construct}, filter);
        defer comparison.deinit(self.allocator);
        try reports.renderComparison(self.allocator, writer, comparison, .{ .json = true });
    }

    fn writeTopic(self: *Gateway, object: std.json.ObjectMap, writer: anytype) !void {
        const db = self.db orelse return error.DatabaseRequired;
        const topic = stringField(object, "id") orelse return error.InvalidInput;
        var report = try reports.reportTopic(self.allocator, db, topic, .{});
        defer report.deinit(self.allocator);
        try reports.renderTopic(self.allocator, writer, report, .{ .json = true });
    }

    fn writeExamples(self: *Gateway, object: std.json.ObjectMap, writer: anytype) !void {
        const db = self.db orelse return error.DatabaseRequired;
        const construct = stringField(object, "construct") orelse return error.InvalidInput;
        const requested = integerField(object, "limit") orelse 20;
        if (requested < 1 or requested > 100) return error.InvalidInput;
        var examples = try reports.findExamples(self.allocator, db, construct, .{}, (@intCast(requested)));
        defer examples.deinit(self.allocator);
        try reports.renderExamples(self.allocator, writer, examples, .{ .json = true });
    }

    fn writeCompare(self: *Gateway, object: std.json.ObjectMap, writer: anytype) !void {
        const db = self.db orelse return error.DatabaseRequired;
        const values = object.get("constructs") orelse return error.InvalidInput;
        if (values != .array or values.array.items.len == 0 or values.array.items.len > 50) return error.InvalidInput;
        var constructs = std.ArrayList([]const u8).empty;
        defer constructs.deinit(self.allocator);
        for (values.array.items) |value| {
            if (value != .string or value.string.len == 0) return error.InvalidInput;
            try constructs.append(self.allocator, value.string);
        }
        var comparison = try reports.compare(self.allocator, db, constructs.items, .{});
        defer comparison.deinit(self.allocator);
        try reports.renderComparison(self.allocator, writer, comparison, .{ .json = true });
    }

    fn generateExercise(self: *Gateway, object: std.json.ObjectMap, writer: anytype) !void {
        _ = self;
        const kind = stringField(object, "kind") orelse return error.InvalidInput;
        if (!std.mem.eql(u8, kind, "map_names")) return error.InvalidInput;
        const delivery = exercises.deliverGenerated(.{ .topic = stringField(object, "topic").?, .level = stringField(object, "level").? }, .{ .id = stringField(object, "id").?, .title = stringField(object, "title").?, .prompt = stringField(object, "prompt").?, .competency = stringField(object, "competency").?, .topic = stringField(object, "topic").?, .level = stringField(object, "level").?, .kind = .map_names, .expected_behavior = stringField(object, "expected_behavior").?, .provenance = stringField(object, "provenance").? });
        try writer.print("{{\"id\":\"{s}\",\"title\":\"{s}\",\"prompt\":\"{s}\",\"expected_behavior\":\"{s}\",\"accepted\":{s},\"generation_status\":\"{s}\",\"provenance\":\"{s}\"}}", .{ delivery.exercise.id, delivery.exercise.title, delivery.exercise.prompt, delivery.exercise.expected_behavior, if (delivery.accepted) "true" else "false", delivery.exercise.generation_status, delivery.exercise.provenance });
    }

    fn submitExercise(self: *Gateway, object: std.json.ObjectMap, writer: anytype) !void {
        const db = self.db orelse return error.DatabaseRequired;
        const id = stringField(object, "exercise_id") orelse return error.InvalidInput;
        const exercise = exercises.find(id) orelse return error.NotFound;
        const learner = integerField(object, "learner_id") orelse return error.InvalidInput;
        const source = stringField(object, "source") orelse return error.InvalidInput;
        const hash = stringField(object, "source_sha256") orelse return error.InvalidInput;
        const result = try exercises.submit(self.allocator, db, learner, exercise, source, hash);
        try writer.print("{{\"attempt_id\":{d},\"outcome\":\"{s}\",\"deterministic\":{s},\"evidence_authority\":\"rgp\"}}", .{ result.attempt_id, @tagName(result.outcome), if (result.deterministic) "true" else "false" });
    }

    fn recordProgress(self: *Gateway, object: std.json.ObjectMap, writer: anytype) !void {
        const db = self.db orelse return error.DatabaseRequired;
        const learner = integerField(object, "learner_id") orelse return error.InvalidInput;
        const lesson_id = stringField(object, "lesson_id") orelse return error.InvalidInput;
        const status = stringField(object, "status") orelse return error.InvalidInput;
        if (!std.mem.eql(u8, status, "not_started") and !std.mem.eql(u8, status, "in_progress") and !std.mem.eql(u8, status, "completed")) return error.InvalidInput;
        const position = integerField(object, "position") orelse return error.InvalidInput;
        if (position < 0) return error.InvalidInput;
        const lesson = learning.find(lesson_id) orelse return error.NotFound;
        const progress_id = try db.recordLessonProgress(learner, lesson.id, lesson.title, status, position);
        try writer.print("{{\"progress_id\":{d},\"lesson_id\":\"{s}\",\"status\":\"{s}\",\"evidence_authority\":\"rgp\"}}", .{ progress_id, lesson.id, status });
    }

    fn success(self: *Gateway, tool_name: []const u8, input: []const u8, output: []const u8) !Response {
        return self.finish(tool_name, input, output, true, null);
    }

    fn failure(self: *Gateway, tool_name: []const u8, code: ErrorCode, message: []const u8, input: []const u8) !Response {
        return self.finish(tool_name, input, "{}", false, .{ .code = code, .message = message });
    }

    fn finish(self: *Gateway, tool_name: []const u8, input: []const u8, output: []const u8, ok: bool, failure_info: ?struct { code: ErrorCode, message: []const u8 }) !Response {
        const input_sha = try digestHex(self.allocator, input);
        defer self.allocator.free(input_sha);
        const call_id = try prefixedDigest(self.allocator, "call", tool_name, input);
        errdefer self.allocator.free(call_id);
        const result_id = try prefixedDigest(self.allocator, "result", call_id, output);
        errdefer self.allocator.free(result_id);
        try self.calls.append(self.allocator, .{ .call_id = try self.allocator.dupe(u8, call_id), .result_id = try self.allocator.dupe(u8, result_id), .tool = try self.allocator.dupe(u8, tool_name), .input_sha256 = try self.allocator.dupe(u8, input_sha), .ok = ok });
        return .{ .call_id = call_id, .result_id = result_id, .ok = ok, .error_code = if (failure_info) |f| f.code else null, .error_message = if (failure_info) |f| try self.allocator.dupe(u8, f.message) else null, .output = try self.allocator.dupe(u8, output) };
    }
};

fn toolAllowed(mode_value: PermissionMode, tool: Tool) bool {
    const mutates_learner_state = tool == .submit_exercise or tool == .record_progress;
    return switch (mode_value) {
        .observe, .suggest => !mutates_learner_state,
        .learn, .edit, .agent => true,
    };
}

fn authorizePath(self: *const Gateway, path: []const u8) PolicyError!void {
    if (path.len == 0) return error.PathOutsideWorkspace;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return error.PathOutsideWorkspace;
    if (!std.fs.path.isAbsolute(path)) return;
    const root = self.policy.workspace_root orelse return error.PathOutsideWorkspace;
    if (!std.mem.startsWith(u8, path, root)) return error.PathOutsideWorkspace;
    if (path.len > root.len and path[root.len] != '/') return error.PathOutsideWorkspace;
}

fn parseTool(name: []const u8) ?Tool {
    if (!std.mem.startsWith(u8, name, "rgp.")) return null;
    inline for (std.meta.tags(Tool)) |tag| if (std.mem.eql(u8, name[4..], @tagName(tag))) return tag;
    return null;
}

fn validateInput(tool: Tool, object: std.json.ObjectMap) ?[]const u8 {
    const required: []const []const u8 = switch (tool) {
        .parse_file => &.{"source"},
        .get_lesson, .get_exercise, .get_construct, .get_idiom, .get_topic => &.{"id"},
        .generate_exercise => &.{ "topic", "level", "id", "title", "prompt", "competency", "expected_behavior", "provenance", "kind" },
        .submit_exercise => &.{ "exercise_id", "learner_id", "source", "source_sha256" },
        .record_progress => &.{ "learner_id", "lesson_id", "status", "position" },
        .get_progress => &.{"learner_id"},
        .analyze_file => &.{ "path", "source" },
        .analyze_repository => &.{ "path", "origin", "commit_sha" },
        .get_stats => &.{},
        .compare => &.{"constructs"},
        .find_examples => &.{"construct"},
    };
    for (required) |key| if (object.get(key) == null) return key;
    const string_required: []const []const u8 = switch (tool) {
        .parse_file => &.{"source"},
        .get_lesson, .get_exercise, .get_construct, .get_idiom, .get_topic => &.{"id"},
        .generate_exercise => &.{ "topic", "level", "id", "title", "prompt", "competency", "expected_behavior", "provenance", "kind" },
        .submit_exercise => &.{ "exercise_id", "source", "source_sha256" },
        .record_progress => &.{ "lesson_id", "status" },
        .analyze_file => &.{ "path", "source" },
        .analyze_repository => &.{ "path", "origin", "commit_sha" },
        else => &.{},
    };
    for (string_required) |key| if (stringField(object, key) == null) return key;
    const integer_required: []const []const u8 = switch (tool) {
        .submit_exercise, .get_progress => &.{"learner_id"},
        .record_progress => &.{ "learner_id", "position" },
        else => &.{},
    };
    for (integer_required) |key| if (integerField(object, key) == null) return key;
    return null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn digestHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const result = try allocator.alloc(u8, digest.len * 2);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    @memcpy(result, &encoded);
    return result;
}

fn prefixedDigest(allocator: std.mem.Allocator, prefix: []const u8, first: []const u8, second: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(prefix);
    hasher.update("\x00");
    hasher.update(first);
    hasher.update("\x00");
    hasher.update(second);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = try allocator.alloc(u8, 5 + digest.len * 2);
    @memcpy(hex[0..4], prefix[0..@min(prefix.len, 4)]);
    hex[4] = '-';
    const encoded = std.fmt.bytesToHex(digest, .lower);
    @memcpy(hex[5..], &encoded);
    return hex;
}

test "catalog is versioned and complete" {
    try std.testing.expectEqual(@as(usize, 15), catalog.len);
    try std.testing.expectEqualStrings("rgp.parse_file", catalog[0].name);
    try std.testing.expect(catalog[12].mutates_evidence);
}

test "gateway rejects unknown and malformed calls with stable ids" {
    var gateway = Gateway.init(std.testing.allocator, null);
    defer gateway.deinit();
    var first = try gateway.dispatch(.{ .tool = "rgp.missing", .input = "{}" });
    defer first.deinit(std.testing.allocator);
    var second = try gateway.dispatch(.{ .tool = "rgp.missing", .input = "{}" });
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!first.ok);
    try std.testing.expectEqual(ErrorCode.unknown_tool, first.error_code.?);
    try std.testing.expectEqualStrings(first.call_id, second.call_id);
    try std.testing.expectEqual(@as(usize, 2), gateway.history().len);
}

test "parse and exercise reads are deterministic gateway tools" {
    var gateway = Gateway.init(std.testing.allocator, null);
    defer gateway.deinit();
    var parsed = try gateway.dispatch(.{ .tool = "rgp.parse_file", .input = "{\"path\":\"x.rb\",\"source\":\"puts 1\\n\"}" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.ok);
    try std.testing.expect(std.mem.indexOf(u8, parsed.output, "x.rb") != null);
    var exercise = try gateway.dispatch(.{ .tool = "rgp.get_exercise", .input = "{\"id\":\"collections.map-names\"}" });
    defer exercise.deinit(std.testing.allocator);
    try std.testing.expect(exercise.ok);
}

test "missing and fabricated evidence cannot be treated as a statistic" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    var gateway = Gateway.init(std.testing.allocator, null);
    defer gateway.deinit();
    var missing = try gateway.dispatch(.{ .tool = "rgp.get_stats", .input = "{}" });
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!missing.ok);
    try std.testing.expectEqual(ErrorCode.database_required, missing.error_code.?);

    var unavailable = try gateway.dispatch(.{ .tool = "rgp.get_stats", .input = "{\"construct\":\"map\"}" });
    defer unavailable.deinit(std.testing.allocator);
    try std.testing.expect(!unavailable.ok);
    try std.testing.expectEqual(ErrorCode.database_required, unavailable.error_code.?);
    try std.testing.expectEqualStrings("{}", unavailable.output);

    var fabricated = try gateway.dispatch(.{ .tool = "rgp.made_up_stats", .input = "{}" });
    defer fabricated.deinit(std.testing.allocator);
    try std.testing.expect(!fabricated.ok);
    try std.testing.expectEqual(ErrorCode.unknown_tool, fabricated.error_code.?);
}

test "permission modes reject learner mutations and require edit approval" {
    var gateway = Gateway.init(std.testing.allocator, null);
    defer gateway.deinit();
    try std.testing.expectEqual(PermissionMode.learn, gateway.mode());

    gateway.setMode(.observe);
    var denied = try gateway.dispatch(.{ .tool = "rgp.submit_exercise", .input = "{\"exercise_id\":\"collections.map-names\",\"learner_id\":1,\"source\":\"users.map { |u| u.name }\",\"source_sha256\":\"x\"}" });
    defer denied.deinit(std.testing.allocator);
    try std.testing.expectEqual(ErrorCode.policy_denied, denied.error_code.?);

    gateway.setMode(.edit);
    try std.testing.expectError(PolicyError.EditApprovalRequired, gateway.authorize(.{ .write_path = .{ .path = "lib/example.rb", .approved = false } }));
    try gateway.authorize(.{ .write_path = .{ .path = "lib/example.rb", .approved = true } });
}

test "path and shell policy stays inside workspace and forbids unrestricted learning shells" {
    var gateway = Gateway.initWithPolicy(std.testing.allocator, null, .{ .mode = .learn, .workspace_root = "/workspace" });
    defer gateway.deinit();
    try gateway.authorize(.{ .read_path = "lib/example.rb" });
    try std.testing.expectError(PolicyError.PathOutsideWorkspace, gateway.authorize(.{ .read_path = "../secret.rb" }));
    try std.testing.expectError(PolicyError.PathOutsideWorkspace, gateway.authorize(.{ .read_path = "/workspace2/secret.rb" }));
    try std.testing.expectError(PolicyError.ShellDenied, gateway.authorize(.{ .shell = .{ .command = "rm -rf", .unrestricted = true } }));

    gateway.setMode(.agent);
    try gateway.authorize(.{ .shell = .{ .command = "bundle exec ruby", .unrestricted = true } });
}

test "cancellation and exercise limits are enforced before execution" {
    var gateway = Gateway.init(std.testing.allocator, null);
    defer gateway.deinit();
    try gateway.cancel("request-1");
    var cancelled = try gateway.dispatch(.{ .tool = "rgp.get_lesson", .input = "{\"id\":\"fundamentals\"}", .request_id = "request-1" });
    defer cancelled.deinit(std.testing.allocator);
    try std.testing.expectEqual(ErrorCode.cancelled, cancelled.error_code.?);
    try std.testing.expectError(PolicyError.ExerciseLimitExceeded, gateway.authorize(.{ .exercise = .{ .source_bytes = 65 * 1024 } }));
}

test "generated exercise gateway rejects unsupported contracts and returns reviewed fallback" {
    var gateway = Gateway.init(std.testing.allocator, null);
    defer gateway.deinit();
    var response = try gateway.dispatch(.{ .tool = "rgp.generate_exercise", .input = "{\"topic\":\"collections\",\"level\":\"beginner\",\"id\":\"bad\",\"title\":\"Do something\",\"prompt\":\"Maybe\",\"competency\":\"unknown\",\"expected_behavior\":\"maybe\",\"provenance\":\"provider:test\",\"kind\":\"map_names\"}" });
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.ok);
    try std.testing.expect(std.mem.indexOf(u8, response.output, "\"accepted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.output, "reviewed-static") != null);
}


test "gateway report operation uses the same provenance path as compare" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("api-fixture");
    const commit = try db.addCommit(repo, "api-sha");
    const file = try db.addFile(commit, "lib/a.rb", "hash");
    const construct = try db.addConstruct("map");
    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" }, &.{.{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 0, .end_offset = 3, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = construct }});
    var gateway = Gateway.init(std.testing.allocator, &db);
    defer gateway.deinit();
    var response = try gateway.dispatch(.{ .tool = "rgp.get_stats", .input = "{\"construct\":\"map\"}" });
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.ok);
    try std.testing.expect(std.mem.indexOf(u8, response.output, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.output, "\"classifier_version\":\"c\"") != null);
}
