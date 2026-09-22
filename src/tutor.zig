//! Offline Socratic tutoring with targeted, monotonic reveals.
const std = @import("std");
const exercises = @import("exercises.zig");
const storage = @import("storage/sqlite.zig");

pub const Turn = struct { step: exercises.RevealLevel, question: []const u8, reveal: []const u8 };

pub fn turn(allocator: std.mem.Allocator, db: *storage.Database, learner_id: i64, attempt_id: i64, requested: exercises.RevealLevel, profile: storage.LearnerProfile) !Turn {
    const exercise = exercises.find("collections.map-names").?;
    const reveal = try exercises.reveal(allocator, db, learner_id, attempt_id, requested);
    const question = switch (requested) {
        .hint => if (profile == .senior) "What result shape does this code establish, and which Enumerable operation states that contract?" else "What should one input user contribute to the result?",
        .concept => if (profile == .beginner) "Which operation applies the same conversion to every item?" else "Why is map's return value different from each's side-effect-oriented traversal?",
        .partial_example => "What expression should replace the blank so each output value is the user's name?",
        .solution => "Can you explain why this solution transforms every input rather than merely iterating?",
        .evidence => "What evidence in your submission demonstrates the competency, and what edge case would you test next?",
    };
    _ = exercise;
    return .{ .step = requested, .question = question, .reveal = reveal };
}

test "socratic turns ask before revealing and support all learner profiles" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:"); defer db.deinit();
    const learner = try db.upsertLearner("tutor", "Ada", .beginner);
    const result = try exercises.submit(std.testing.allocator, &db, learner, exercises.exercises[0], "users.each { |u| names << u.name }", "tutor-source");
    inline for ([_]storage.LearnerProfile{ .beginner, .intermediate, .senior }) |profile| {
        const first = try turn(std.testing.allocator, &db, learner, result.attempt_id, .hint, profile);
        try std.testing.expect(first.question.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, first.reveal, "users.map") == null);
    }
}
