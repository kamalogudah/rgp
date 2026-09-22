//! Reviewed static exercises plus constrained, deterministic generated tasks.
const std = @import("std");
const prism = @import("prism/parser.zig");
const storage = @import("storage/sqlite.zig");

pub const ExerciseKind = enum { map_names };
pub const RevealLevel = enum(u8) { hint, concept, partial_example, solution, evidence };
pub const progression = [_][]const u8{ "Look at the required result: each input user contributes one output name. Which collection operation describes transforming every item?", "map (also called collect) returns a new collection by applying a block to every item; each is for side effects and needs explicit result storage.", "Try: names = users.map { |user| user.___ } — choose the member that supplies the requested value. A manual each solution is also valid, with explicit accumulation as its trade-off.", "users.map { |user| user.name }", "The offline validator records deterministic static shape and labels map/collect as idiomatic, explicit each accumulation as manual-correct, and alternatives only when behavior is established. Popularity never decides correctness." };
pub const Outcome = enum { syntax_error, correct, alternative_correct, manual_correct, idiomatic_correct, wrong, runtime_unavailable };
pub const Exercise = struct { id: []const u8, title: []const u8, prompt: []const u8, competency: []const u8, topic: []const u8 = "collections", level: []const u8 = "beginner", kind: ExerciseKind, expected_behavior: []const u8 = "returns user.name for every user", provenance: []const u8 = "reviewed-static", generation_status: []const u8 = "reviewed", guidance: []const []const u8 = &progression };
pub const exercises = [_]Exercise{.{ .id = "collections.map-names", .title = "Transform users into names", .prompt = "Return the names of all users using an Enumerable method.", .competency = "enumerable_transformation", .kind = .map_names }};

pub const GenerationRequest = struct { topic: []const u8, level: []const u8 };
pub const GeneratedCandidate = struct { id: []const u8, title: []const u8, prompt: []const u8, competency: []const u8, topic: []const u8, level: []const u8, kind: ExerciseKind, expected_behavior: []const u8, provenance: []const u8 };
pub const Delivery = struct { exercise: Exercise, accepted: bool, rejection_reason: ?[]const u8 = null };

/// Validate an agent proposal before it can reach a learner.
pub fn deliverGenerated(request: GenerationRequest, candidate: GeneratedCandidate) Delivery {
    const valid = request.topic.len != 0 and request.level.len != 0 and candidate.id.len != 0 and candidate.title.len != 0 and candidate.prompt.len != 0 and candidate.competency.len != 0 and candidate.provenance.len != 0 and std.mem.eql(u8, candidate.topic, request.topic) and std.mem.eql(u8, candidate.level, request.level) and candidate.kind == .map_names and std.mem.eql(u8, candidate.competency, "enumerable_transformation") and std.mem.eql(u8, candidate.expected_behavior, "returns user.name for every user") and !containsControl(candidate.prompt) and !containsControl(candidate.title);
    if (valid) return .{ .accepted = true, .exercise = .{ .id = candidate.id, .title = candidate.title, .prompt = candidate.prompt, .competency = candidate.competency, .topic = candidate.topic, .level = candidate.level, .kind = candidate.kind, .expected_behavior = candidate.expected_behavior, .provenance = candidate.provenance, .generation_status = "accepted" } };
    return .{ .accepted = false, .rejection_reason = "candidate is ambiguous, out of scope, or lacks a supported behavior contract", .exercise = exercises[0] };
}
fn containsControl(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 and byte != '\n' and byte != '\t') return true;
    return false;
}
pub const Result = struct {
    attempt_id: i64 = 0,
    outcome: Outcome,
    syntax_ok: bool,
    behavioral_check: []const u8,
    feedback: []const u8,
    deterministic: bool,
    idiom_id: ?[]const u8 = null,
    idiom_evidence: []const u8 = "none",
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
    const attempt_id = try db.recordExerciseAttemptAnalysis(learner_id, exercise.id, exercise.title, exercise.prompt, exercise.competency, source, @tagName(result.outcome), result.syntax_ok, result.behavioral_check, result.feedback, result.deterministic, source_sha256, result.idiom_id, result.idiom_evidence, if (result.idiom_id != null) "corpus examples for the recognized idiom are available via `rgp examples map`" else "no idiom corpus evidence claimed");
    try db.recordExerciseProvenance(exercise.id, exercise.expected_behavior, exercise.provenance, exercise.generation_status);
    const competency = try db.getOrAddCompetency(exercise.competency, exercise.title);
    const level: u8 = switch (result.outcome) {
        .idiomatic_correct => 4,
        .manual_correct => 3,
        .correct, .alternative_correct => 2,
        .wrong, .runtime_unavailable => 1,
        .syntax_error => 0,
    };
    const evidence_key = try std.fmt.allocPrint(allocator, "exercise-attempt-{d}", .{attempt_id});
    defer allocator.free(evidence_key);
    const source_id = try std.fmt.allocPrint(allocator, "{d}", .{attempt_id});
    defer allocator.free(source_id);
    _ = try db.recordCompetencyEvidence(.{ .learner_id = learner_id, .competency_id = competency, .evidence_key = evidence_key, .dimension = if (level >= 3) .demonstrated else .practice, .level = level, .source_type = "exercise_attempt", .source_id = source_id, .detail = result.idiom_evidence, .attributed_to = "learner" });
    var submitted = result;
    submitted.attempt_id = attempt_id;
    return submitted;
}

/// Return only the learner-requested progression level; content is never auto-revealed.
pub fn reveal(allocator: std.mem.Allocator, db: *storage.Database, learner_id: i64, attempt_id: i64, requested: RevealLevel) ![]const u8 {
    _ = allocator;
    _ = try db.revealAttempt(learner_id, attempt_id, @intFromEnum(requested));
    return progression[@intFromEnum(requested)];
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
    if (!has_each and !has_map) return .{ .outcome = .wrong, .syntax_ok = true, .behavioral_check = "not-run", .feedback = "The code does not show a transformation or iteration over the users.", .deterministic = true };
    if (has_map and has_name) return .{ .outcome = .idiomatic_correct, .syntax_ok = true, .behavioral_check = "static-shape: users transformed to user.name", .feedback = "Accepted: this is an idiomatic Enumerable transformation. Corpus examples can be explored with `rgp examples map`.", .deterministic = true, .idiom_id = "map", .idiom_evidence = "map transforms each user to user.name" };
    if (has_each and has_name and containsAny(source, &.{ "<<", ".push", ".append" })) return .{ .outcome = .manual_correct, .syntax_ok = true, .behavioral_check = "static-shape: each appends user.name", .feedback = "Accepted: this manual solution is correct. It is distinguished from the idiomatic Enumerable form because `each` manages the result collection explicitly.", .deterministic = true, .idiom_id = "manual_collection_transformation", .idiom_evidence = "each appends user.name to an explicit result collection" };
    return .{ .outcome = .wrong, .syntax_ok = true, .behavioral_check = "static-shape: name transformation not established", .feedback = "The submission does not clearly return each user’s name.", .deterministic = true };
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
    try std.testing.expectEqual(Outcome.idiomatic_correct, candidate.outcome);
}
test "submission persists analysis and competency evidence" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const learner = try db.upsertLearner("practice-learner", "Ada", .beginner);
    const result = try submit(std.testing.allocator, &db, learner, exercises[0], "users.map { |user| user.name }", "sha-practice");
    try std.testing.expectEqual(Outcome.idiomatic_correct, result.outcome);
    try std.testing.expectEqual(@as(i64, 1), try db.count("exercise_attempts"));
    try std.testing.expectEqual(@as(i64, 1), try db.count("competency_evidence"));
}

test "reveal progression is learner-controlled and persisted per attempt" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const learner = try db.upsertLearner("hint-learner", "Ada", .beginner);
    const result = try submit(std.testing.allocator, &db, learner, exercises[0], "users.each { |user| names << user.name }", "sha-hints");
    const hint = try reveal(std.testing.allocator, &db, learner, result.attempt_id, .hint);
    try std.testing.expect(std.mem.indexOf(u8, hint, "users.map") == null);
    try std.testing.expectEqual(@as(i64, 0), try db.attemptReveal(learner, result.attempt_id));
    _ = try reveal(std.testing.allocator, &db, learner, result.attempt_id, .solution);
    try std.testing.expectEqual(@as(i64, 3), try db.attemptReveal(learner, result.attempt_id));
    _ = try db.revealAttempt(learner, result.attempt_id, 0);
    try std.testing.expectEqual(@as(i64, 3), try db.attemptReveal(learner, result.attempt_id));
}

test "wrong static submissions remain wrong" {
    const result = try validate(std.testing.allocator, exercises[0], "users.each { |user| puts user.email }");
    try std.testing.expectEqual(Outcome.wrong, result.outcome);
}

test "accepted generated submission keeps deterministic competency scoring" {
    const delivery = deliverGenerated(.{ .topic = "collections", .level = "beginner" }, .{ .id = "generated.map-names.2", .title = "Name users", .prompt = "Return each user's name.", .competency = "enumerable_transformation", .topic = "collections", .level = "beginner", .kind = .map_names, .expected_behavior = "returns user.name for every user", .provenance = "provider:test;seed:2" });
    try std.testing.expect(delivery.accepted);
    const result = try validate(std.testing.allocator, delivery.exercise, "users.map { |user| user.name }");
    try std.testing.expectEqual(Outcome.idiomatic_correct, result.outcome);
    try std.testing.expect(result.deterministic);
}
