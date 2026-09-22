//! Deterministic, source-proven facts used by the explain command and agents.
const std = @import("std");
const observation = @import("analysis/observation.zig");
const idioms = @import("analysis/idioms.zig");

pub const Profile = enum { beginner, intermediate, senior };
pub const Fact = struct { construct: []const u8, idiom_id: []const u8, reason: []const u8, line: usize, end_line: usize, start_offset: usize, end_offset: usize, known: bool };

pub fn facts(allocator: std.mem.Allocator, source: []const u8, observations: []const observation.Observation, matches: []const idioms.Match, first_line: usize, last_line: usize) ![]Fact {
    var result = std.ArrayList(Fact).empty;
    errdefer result.deinit(allocator);
    for (matches) |match| {
        const obs = observations[match.observation_index];
        if (obs.line > last_line or lineAtOffset(source, obs.end_offset) < first_line) continue;
        var duplicate = false;
        for (result.items) |existing| {
            if (existing.start_offset == obs.start_offset and std.mem.eql(u8, existing.idiom_id, match.idiom_id)) duplicate = true;
        }
        if (duplicate) continue;
        try result.append(allocator, .{ .construct = obs.construct, .idiom_id = match.idiom_id, .reason = match.reason, .line = obs.line, .end_line = lineAtOffset(source, obs.end_offset), .start_offset = obs.start_offset, .end_offset = obs.end_offset, .known = match.classification == .proven_equivalence or !std.mem.eql(u8, match.confidence, "low") });
    }
    std.sort.block(Fact, result.items, {}, lessFact);
    return result.toOwnedSlice(allocator);
}
fn lessFact(_: void, a: Fact, b: Fact) bool { return a.start_offset < b.start_offset or (a.start_offset == b.start_offset and a.end_offset < b.end_offset); }
fn lineAtOffset(source: []const u8, offset: usize) usize { const end = @min(offset, source.len); return std.mem.count(u8, source[0..end], "\n") + 1; }
pub fn label(profile: Profile, fact: Fact) []const u8 {
    return switch (profile) {
        .beginner => if (std.mem.eql(u8, fact.idiom_id, "collection_filter")) "keeps elements that pass a test" else if (std.mem.eql(u8, fact.idiom_id, "collection_transformation")) "changes each element into a new value" else if (std.mem.eql(u8, fact.idiom_id, "nil_removal")) "removes nil values" else if (std.mem.eql(u8, fact.idiom_id, "deduplication")) "removes repeated values" else fact.reason,
        .intermediate => fact.reason,
        .senior => if (fact.known) fact.reason else "semantic intent is not proven by the AST",
    };
}
pub fn profileName(profile: Profile) []const u8 { return @tagName(profile); }

test "collection pipeline facts include filtering transformation nil removal and deduplication" {
    const source = "users.select(&:active?).map(&:email).compact.uniq\n";
    var document = try @import("prism/parser.zig").parse(std.testing.allocator, source, .{ .path = "pipeline.rb" });
    defer document.deinit();
    const observations = try observation.extract(std.testing.allocator, &document);
    defer std.testing.allocator.free(observations);
    const matches = try idioms.detectSource(std.testing.allocator, source, observations);
    defer std.testing.allocator.free(matches);
    const result = try facts(std.testing.allocator, source, observations, matches, 1, 1);
    defer std.testing.allocator.free(result);
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (result) |fact| try seen.put(fact.idiom_id, {});
    inline for ([_][]const u8{ "collection_filter", "collection_transformation", "nil_removal", "deduplication" }) |id| try std.testing.expect(seen.contains(id));
}
