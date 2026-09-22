//! Deterministic lesson recommendations from evidence, prerequisites, and profile.
const std = @import("std");
const learning = @import("learning.zig");
const storage = @import("storage/sqlite.zig");

pub const Evidence = struct { key: []const u8, exposure: i64 = 0, practice: i64 = 0, demonstrated: i64 = 0 };
pub const Recommendation = struct { lesson: learning.Lesson, competency: []const u8, reason: []const u8, evidence_level: i64, mastery: bool };

pub fn competencyForLesson(id: []const u8) []const u8 {
    const ids = [_][]const u8{ "fundamentals", "conditionals", "loops", "arrays", "hashes", "enumerable", "methods", "blocks", "classes-modules", "exceptions" };
    const keys = [_][]const u8{ "ruby_fundamentals", "conditionals", "iteration", "arrays", "hashes", "enumerable_transformation", "methods", "blocks", "classes_modules", "exceptions" };
    for (ids, 0..) |value, i| if (std.mem.eql(u8, id, value)) return keys[i];
    return id;
}

pub fn recommend(allocator: std.mem.Allocator, profile: storage.LearnerProfile, evidence: []const Evidence, completed: []const []const u8) ![]Recommendation {
    var result = std.ArrayList(Recommendation).empty;
    errdefer result.deinit(allocator);
    for (learning.lessons) |lesson| {
        const is_completed = contains(completed, lesson.id);
        const state = stateFor(evidence, competencyForLesson(lesson.id));
        const prerequisite_done = if (lesson.prerequisite) |p| contains(completed, p) else true;
        if (!prerequisite_done) continue;
        const threshold: i64 = switch (profile) { .beginner => 2, .intermediate => 3, .senior => 4 };
        const level = @max(state.practice, state.demonstrated);
        const mastery = state.demonstrated >= threshold;
        if (mastery) continue;
        const reason = if (is_completed and state.demonstrated == 0) "lesson completed, but completion alone is not mastery; submit practice evidence" else if (state.demonstrated > 0) "demonstrated evidence exists, but this profile requires more evidence" else if (state.practice > 0) "practice evidence exists; demonstrate the competency with an exercise" else "no competency evidence yet; this is the next prerequisite-aware lesson";
        try result.append(allocator, .{ .lesson = lesson, .competency = competencyForLesson(lesson.id), .reason = reason, .evidence_level = level, .mastery = false });
        if (result.items.len == 3) break;
    }
    return result.toOwnedSlice(allocator);
}

fn stateFor(evidence: []const Evidence, key: []const u8) Evidence { for (evidence) |state| if (std.mem.eql(u8, state.key, key)) return state; return .{ .key = key }; }
fn contains(values: []const []const u8, wanted: []const u8) bool { for (values) |value| if (std.mem.eql(u8, value, wanted)) return true; return false; }

test "lesson completion does not imply mastery and profiles require progressively stronger evidence" {
    const completed = [_][]const u8{"fundamentals"};
    const none = try recommend(std.testing.allocator, .beginner, &.{}, &completed); defer std.testing.allocator.free(none);
    try std.testing.expect(none.len > 0);
    try std.testing.expectEqualStrings("fundamentals", none[0].lesson.id);
    const evidence = [_]Evidence{.{ .key = "ruby_fundamentals", .practice = 2, .demonstrated = 2 }};
    const beginner = try recommend(std.testing.allocator, .beginner, &evidence, &.{}); defer std.testing.allocator.free(beginner);
    const senior = try recommend(std.testing.allocator, .senior, &evidence, &.{}); defer std.testing.allocator.free(senior);
    try std.testing.expect(beginner.len > 0);
    try std.testing.expect(senior.len > 0);
    try std.testing.expectEqualStrings("conditionals", beginner[0].lesson.id);
}
