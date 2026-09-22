//! Static exercises and deterministic submission validation.
const std = @import("std");
const prism = @import("prism/parser.zig");
const storage = @import("storage/sqlite.zig");

pub const ExerciseKind = enum { map_names };
pub const Outcome = enum { syntax_error, correct, alternative_correct, manual_correct, idiomatic_correct, wrong, runtime_unavailable };
pub const Exercise = struct { id: []const u8, title: []const u8, prompt: []const u8, competency: []const u8, kind: ExerciseKind };
pub const exercises = [_]Exercise{.{ .id = "collections.map-names", .title = "Transform users into names", .prompt = "Return the names of all users using an Enumerable method.", .competency = "enumerable_transformation", .kind = .map_names }};
pub const Result = struct {
    outcome: Outcome,
    syntax_ok: bool,
    behavioral_check: []const u8,
    feedback: []const u8,
    deterministic: bool,
    pub fn idiomatic(self: Result) bool {
        return self.outcome == .idiomatic_correct;
    }
};

pub fn find(id: []const u8) ?Exercise {
    for (exercises) |exercise| if (std.mem.eql(u8, exercise.id, id)) return exercise;
    return null;
}

/// Parse first. Behavioral correctness is only asserted by a sandbox runner;
pub fn submit(allocator: std.mem.Allocator, db: *storage.Database, learner_id: i64, exercise: Exercise, source: []const u8, source_sha256: []const u8) !Result {
    const result = try validate(allocator, exercise, source);
    _ = try db.recordExerciseAttempt(learner_id, exercise.id, exercise.title, exercise.prompt, exercise.competency, source, @tagName(result.outcome), result.syntax_ok, result.behavioral_check, result.feedback, result.deterministic, source_sha256);
    return result;
}

/// the offline core never executes submitted Ruby on the host.
pub fn validate(allocator: std.mem.Allocator, exercise: Exercise, source: []const u8) !Result {
    var document = try prism.parse(allocator, source, .{ .path = "<submission>" });
    defer document.deinit();
    if (!document.success()) return .{ .outcome = .syntax_error, .syntax_ok = false, .behavioral_check = "not-run", .feedback = "The submission has a Ruby syntax error.", .deterministic = true };
    return switch (exercise.kind) {
        .map_names => validateMapNames(source),
    };
}

fn validateMapNames(source: []const u8) Result {
    const has_each = containsAny(source, &.{ ".each", " each do", " each {" });
    const has_map = containsAny(source, &.{ ".map", ".collect", " map do", " map {", " collect do", " collect {" });
    const has_name = std.mem.indexOf(u8, source, ".name") != null;
    if (!has_each and !has_map) return .{ .outcome = .wrong, .syntax_ok = true, .behavioral_check = "not-run", .feedback = "The code does not show a transformation or iteration over the users.", .deterministic = false };
    if (has_map and has_name) return .{ .outcome = .runtime_unavailable, .syntax_ok = true, .behavioral_check = "unavailable", .feedback = "Ruby execution is unavailable in the offline validator; correctness was not asserted.", .deterministic = false };
    if (has_each and has_name) return .{ .outcome = .runtime_unavailable, .syntax_ok = true, .behavioral_check = "unavailable", .feedback = "Ruby execution is unavailable in the offline validator; correctness was not asserted.", .deterministic = false };
    return .{ .outcome = .wrong, .syntax_ok = true, .behavioral_check = "unavailable", .feedback = "The submission does not clearly return each user’s name.", .deterministic = false };
}
fn containsAny(source: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, source, needle) != null) return true;
    return false;
}

test "static exercise distinguishes syntax from unavailable behavioral validation" {
    const exercise = find("collections.map-names").?;
    const invalid = try validate(std.testing.allocator, exercise, "def broken(");
    try std.testing.expectEqual(Outcome.syntax_error, invalid.outcome);
    const candidate = try validate(std.testing.allocator, exercise, "users.map { |user| user.name }");
    try std.testing.expectEqual(Outcome.runtime_unavailable, candidate.outcome);
    try std.testing.expect(!candidate.deterministic);
}
test "wrong static submissions remain wrong" {
    const result = try validate(std.testing.allocator, exercises[0], "users.each { |user| puts user.email }");
    try std.testing.expectEqual(Outcome.wrong, result.outcome);
}
