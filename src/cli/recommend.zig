//! Evidence-backed lesson recommendations; no AI or network is required.
const std = @import("std");
const Io = std.Io;
const storage = @import("../storage/sqlite.zig");
const recommendations = @import("../recommendations.zig");

pub fn run(_: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    var learner_id: i64 = 0;
    var profile: storage.LearnerProfile = .beginner;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--learner")) { if (i + 1 >= args.len) return usage(writer); learner_id = std.fmt.parseInt(i64, args[i + 1], 10) catch return usage(writer); i += 1; }
        else if (std.mem.eql(u8, args[i], "--level") or std.mem.eql(u8, args[i], "--profile")) { if (i + 1 >= args.len) return usage(writer); profile = parseProfile(args[i + 1]) orelse return usage(writer); i += 1; }
        else return usage(writer);
    }
    if (learner_id == 0) { try writer.writeAll("Recommendations (beginner, no learner evidence):\n"); return render(writer, allocator, .beginner, &.{}, &.{}); }
    var db = storage.Database.open(allocator, ".rgp/rgp.db") catch |err| { try writer.print("error: cannot open learner state: {s}; run learner setup or omit --learner for the offline baseline.\n", .{@errorName(err)}); return 1; };
    defer db.deinit();
    const states = try db.competencyStates(allocator, learner_id); defer { for (states) |state| allocator.free(state.key); allocator.free(states); }
    const completed = try db.completedLessonKeys(allocator, learner_id); defer { for (completed) |key| allocator.free(key); allocator.free(completed); }
    var evidence = try allocator.alloc(recommendations.Evidence, states.len); defer allocator.free(evidence);
    for (states, 0..) |state, index| evidence[index] = .{ .key = state.key, .exposure = state.exposure, .practice = state.practice, .demonstrated = state.demonstrated };
    try writer.print("Recommendations ({s}) for learner {d}:\n", .{ @tagName(profile), learner_id });
    return render(writer, allocator, profile, evidence, completed);
}

fn render(writer: *Io.Writer, allocator: std.mem.Allocator, profile: storage.LearnerProfile, evidence: []const recommendations.Evidence, completed: []const []const u8) !u8 {
    const items = try recommendations.recommend(allocator, profile, evidence, completed); defer allocator.free(items);
    if (items.len == 0) { try writer.writeAll("No unmet recommendations; competency evidence supports the selected profile.\n"); return 0; }
    for (items) |item| try writer.print("- {s} ({s})\n  competency: {s}\n  supporting evidence level: {d}\n  why: {s}\n", .{ item.lesson.id, item.lesson.title, item.competency, item.evidence_level, item.reason });
    return 0;
}
fn parseProfile(value: []const u8) ?storage.LearnerProfile { if (std.mem.eql(u8, value, "beginner")) return .beginner; if (std.mem.eql(u8, value, "intermediate")) return .intermediate; if (std.mem.eql(u8, value, "senior")) return .senior; return null; }
fn usage(writer: *Io.Writer) !u8 { try writer.writeAll("Recommendations usage:\n  rgp recommend [--learner ID] [--level beginner|intermediate|senior]\n"); return 2; }
