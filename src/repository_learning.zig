const std = @import("std");
const storage = @import("storage/sqlite.zig");

pub const Question = struct {
    key: []u8,
    concept: []u8,
    prompt: []u8,
    expected_fact: []u8,
    observation: storage.SourceObservation,
    pub fn deinit(self: *Question, a: std.mem.Allocator) void {
        a.free(self.key);
        a.free(self.concept);
        a.free(self.prompt);
        a.free(self.expected_fact);
    }
};

pub fn generate(a: std.mem.Allocator, o: storage.SourceObservation, concept: []const u8) !Question {
    if (concept.len == 0 or o.commit_sha.len == 0 or o.line < 1 or o.end_offset < o.start_offset) return error.InvalidPinnedFact;
    const key = try std.fmt.allocPrint(a, "{s}:{d}:{d}:{d}", .{ o.commit_sha, o.start_offset, o.end_offset, o.id });
    errdefer a.free(key);
    const label = try a.dupe(u8, concept);
    errdefer a.free(label);
    const prompt = try std.fmt.allocPrint(a, "At {s}@{s} {s}:{d}:{d}, what role does `{s}` play? Name the construct and explain its local purpose.", .{ o.repository_origin, o.commit_sha, o.file_path, o.line, o.column, concept });
    errdefer a.free(prompt);
    const fact = try std.fmt.allocPrint(a, "Pinned fact: {s}@{s} {s}:{d}:{d} is classified as `{s}`; this is syntax evidence, not semantic equivalence.", .{ o.repository_origin, o.commit_sha, o.file_path, o.line, o.column, concept });
    return .{ .key = key, .concept = label, .prompt = prompt, .expected_fact = fact, .observation = o };
}

pub fn validateAnswer(answer: []const u8, concept: []const u8) bool {
    return answer.len > 0 and std.mem.indexOf(u8, answer, concept) != null;
}

pub fn persistQuestion(db: *storage.Database, learner: i64, session: []const u8, q: Question) !i64 {
    const sid = try db.startRepositoryReadingSession(learner, session, q.observation.repository_origin, q.observation.commit_sha);
    return db.saveReadingQuestion(sid, q.key, q.concept, q.prompt, q.expected_fact, q.observation);
}

pub fn persistAnswer(db: *storage.Database, learner: i64, session: []const u8, q: Question, response: []const u8) !bool {
    const qid = try persistQuestion(db, learner, session, q);
    const accepted = validateAnswer(response, q.concept);
    _ = try db.recordReadingAnswer(learner, qid, response, accepted, if (accepted) "validated pinned fact" else "answer needs the construct name");
    if (accepted) {
        const competency = try db.getOrAddCompetency(q.concept, q.concept);
        const ek = try std.fmt.allocPrint(db.allocator, "repository-reading-{d}", .{qid});
        defer db.allocator.free(ek);
        const sid = try std.fmt.allocPrint(db.allocator, "{s}@{s}:{s}:{d}:{d}", .{ q.observation.repository_origin, q.observation.commit_sha, q.observation.file_path, q.observation.start_offset, q.observation.end_offset });
        defer db.allocator.free(sid);
        _ = try db.recordCompetencyEvidence(.{ .learner_id = learner, .competency_id = competency, .evidence_key = ek, .dimension = .demonstrated, .level = 2, .source_type = "repository_reading", .source_id = sid, .detail = q.expected_fact, .attributed_to = "learner" });
    }
    return accepted;
}
