//! CLI adapter for the offline Socratic tutor.
const std = @import("std");
const Io = std.Io;
const storage = @import("../storage/sqlite.zig");
const exercises = @import("../exercises.zig");
const tutor = @import("../tutor.zig");

pub fn run(_: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    var learner_id: i64 = 0; var attempt_id: i64 = 0; var step: exercises.RevealLevel = .hint; var profile: storage.LearnerProfile = .beginner; var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--learner")) { if (i + 1 >= args.len) return usage(writer); learner_id = std.fmt.parseInt(i64, args[i + 1], 10) catch return usage(writer); i += 1; }
        else if (std.mem.eql(u8, args[i], "--attempt")) { if (i + 1 >= args.len) return usage(writer); attempt_id = std.fmt.parseInt(i64, args[i + 1], 10) catch return usage(writer); i += 1; }
        else if (std.mem.eql(u8, args[i], "--step")) { if (i + 1 >= args.len) return usage(writer); step = parseStep(args[i + 1]) orelse return usage(writer); i += 1; }
        else if (std.mem.eql(u8, args[i], "--level")) { if (i + 1 >= args.len) return usage(writer); profile = parseProfile(args[i + 1]) orelse return usage(writer); i += 1; }
        else return usage(writer);
    }
    if (learner_id == 0 or attempt_id == 0) { try writer.writeAll("error: Socratic tutoring requires --learner ID and --attempt ID; request --step hint first.\n"); return 2; }
    var db = storage.Database.open(allocator, ".rgp/rgp.db") catch |err| { try writer.print("error: cannot open learner state: {s}\n", .{@errorName(err)}); return 1; }; defer db.deinit();
    const result = tutor.turn(allocator, &db, learner_id, attempt_id, step, profile) catch |err| { try writer.print("error: cannot tutor attempt {d}: {s}\n", .{ attempt_id, @errorName(err) }); return 1; };
    try writer.print("Socratic step: {s}\nQuestion: {s}\nReveal: {s}\n", .{ @tagName(result.step), result.question, result.reveal });
    return 0;
}
fn parseStep(value: []const u8) ?exercises.RevealLevel { inline for ([_]exercises.RevealLevel{ .hint, .concept, .partial_example, .solution, .evidence }) |step| if (std.mem.eql(u8, value, @tagName(step))) return step; return null; }
fn parseProfile(value: []const u8) ?storage.LearnerProfile { if (std.mem.eql(u8, value, "beginner")) return .beginner; if (std.mem.eql(u8, value, "intermediate")) return .intermediate; if (std.mem.eql(u8, value, "senior")) return .senior; return null; }
fn usage(writer: *Io.Writer) !u8 { try writer.writeAll("Tutor usage:\n  rgp tutor --learner ID --attempt ID [--step hint|concept|partial_example|solution|evidence] [--level profile]\n"); return 2; }
