//! Versioned core API contracts shared by hosted adapters and offline callers.
//! The API is transport-neutral; the gateway remains the JSON adapter.
const std = @import("std");

pub const version = "rgp.api.v1";
pub const max_page_size: u32 = 100;

pub const Operation = enum { corpus, analyze, stats, compare, examples, learn, practice, explain, progress };
pub const Scope = enum { read, analyze, learn, write };
pub const ErrorCode = enum { invalid_request, unauthenticated, forbidden, not_found, conflict, invalid_cursor, limit_exceeded, cancelled, unavailable, failed };
pub const JobState = enum { queued, running, completed, failed, cancelled };

pub const AuthContext = struct {
    principal: []const u8,
    learner_id: ?i64 = null,
    hosted: bool = false,
    scopes: []const Scope = &.{},
};

pub const PageRequest = struct { cursor: ?[]const u8 = null, limit: u32 = 20 };
pub const PageInfo = struct { next_cursor: ?[]const u8 = null, has_more: bool = false };

pub const Request = struct {
    request_id: []const u8,
    operation: Operation,
    auth: AuthContext,
    page: PageRequest = .{},
    payload_json: []const u8 = "{}",
};

pub const Provenance = struct {
    api_version: []const u8 = version,
    evidence_authority: []const u8 = "rgp",
    deterministic: bool = true,
    corpus_snapshot: ?i64 = null,
    rgp_version: ?[]const u8 = null,
    prism_version: ?[]const u8 = null,
    classifier_version: ?[]const u8 = null,
    taxonomy_version: ?[]const u8 = null,
};

pub const Response = struct {
    request_id: []const u8,
    ok: bool,
    error_code: ?ErrorCode = null,
    error_message: ?[]const u8 = null,
    page: PageInfo = .{},
    provenance: Provenance = .{},
};

pub const Job = struct {
    id: []const u8,
    state: JobState = .queued,
    progress: u8 = 0,
    cancel_requested: bool = false,

    pub fn requestCancel(self: *Job) void {
        if (self.state == .queued or self.state == .running) self.cancel_requested = true;
    }

    pub fn checkpoint(self: *Job) error{Cancelled}!void {
        if (self.cancel_requested) {
            self.state = .cancelled;
            return error.Cancelled;
        }
    }
};

pub const ValidationError = error{InvalidRequest, Unauthenticated, Forbidden, InvalidCursor, LimitExceeded};

pub fn validate(request: Request) ValidationError!void {
    if (request.request_id.len == 0 or request.auth.principal.len == 0) return error.InvalidRequest;
    if (request.page.limit == 0 or request.page.limit > max_page_size) return error.LimitExceeded;
    if (request.page.cursor) |cursor| {
        if (cursor.len == 0 or cursor.len > 256 or std.mem.indexOfAny(u8, cursor, "\r\n") != null) return error.InvalidCursor;
    }
    if (request.auth.hosted and request.auth.learner_id == null) return error.Unauthenticated;
}

pub fn authorizeLearner(auth: AuthContext, learner_id: i64) ValidationError!void {
    if (learner_id <= 0) return error.InvalidRequest;
    if (auth.hosted and auth.learner_id != learner_id) return error.Forbidden;
}

test "v1 request validation bounds pagination and hosted identity" {
    try validate(.{ .request_id = "r1", .operation = .stats, .auth = .{ .principal = "local" }, .page = .{ .limit = 100 } });
    try std.testing.expectError(error.LimitExceeded, validate(.{ .request_id = "r1", .operation = .stats, .auth = .{ .principal = "local" }, .page = .{ .limit = 101 } }));
    try std.testing.expectError(error.Unauthenticated, validate(.{ .request_id = "r1", .operation = .progress, .auth = .{ .principal = "user", .hosted = true } }));
    try std.testing.expectError(error.Forbidden, authorizeLearner(.{ .principal = "user", .learner_id = 7, .hosted = true }, 8));
}

test "v1 jobs cancel cooperatively at checkpoints" {
    var job = Job{ .id = "job-1", .state = .running, .progress = 4 };
    job.requestCancel();
    try std.testing.expectError(error.Cancelled, job.checkpoint());
    try std.testing.expectEqual(JobState.cancelled, job.state);
}
