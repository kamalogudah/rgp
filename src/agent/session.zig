//! Durable agent-session lifecycle.
const std = @import("std");
const storage = @import("../storage/sqlite.zig");

pub const Session = struct {
    db: *storage.Database,
    id: i64,
    key: []const u8,

    pub fn beginPrompt(self: *Session, content: []const u8) !void {
        _ = try self.db.appendAgentMessage(self.id, "user", content, true);
        _ = try self.db.appendAgentMessage(self.id, "assistant", "", false);
    }
    pub fn completePrompt(self: *Session, answer: []const u8) !void {
        _ = try self.db.appendAgentMessage(self.id, "assistant", answer, true);
        try self.db.setAgentStatus(self.id, "active");
    }
    pub fn interrupt(self: *Session) !void {
        try self.db.setAgentStatus(self.id, "interrupted");
    }
    pub fn complete(self: *Session) !void {
        try self.db.setAgentStatus(self.id, "completed");
    }
    pub fn compact(_: *Session, writer: *std.Io.Writer) !void {
        try writer.writeAll("conversation compacted; authoritative learner state: rgp learner storage; authoritative corpus facts: rgp observations and pinned snapshot; tool provenance: rgp gateway call records");
    }
};

pub fn open(allocator: std.mem.Allocator, db: *storage.Database, key: []const u8, adapter: []const u8, learner: ?[]const u8, topic: ?[]const u8, cwd: ?[]const u8, snapshot: ?[]const u8) !Session {
    return .{ .db = db, .id = try db.upsertAgentSession(key, adapter, learner, topic, cwd, snapshot), .key = try allocator.dupe(u8, key) };
}

test "session persists context and marks interrupted streams" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    var session = try open(std.testing.allocator, &db, "shell-1", "fx", "learner-1", "collections", "/repo", "snapshot-1");
    defer std.testing.allocator.free(session.key);
    try session.beginPrompt("Explain map; token=secret");
    try session.interrupt();
    const status = try db.agentSessionStatus(session.id);
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("interrupted", status);
    try std.testing.expectEqual(@as(i64, 2), try db.agentMessageCount(session.id));
}
