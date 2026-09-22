const std = @import("std");
const Io = std.Io;
const learning = @import("../learning.zig");

pub fn run(_: Io, _: std.mem.Allocator, args: []const []const u8, w: *Io.Writer) !u8 {
    var chosen: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (chosen != null) return 2;
        chosen = arg;
    }
    if (chosen) |id| {
        const l = learning.find(id) orelse {
            try w.print("error: unknown lesson `{s}`; run `rgp learn` for the path.\n", .{id});
            return 2;
        };
        try w.print("Lesson: {s} ({s})\nPrerequisite: {s}\n\nConcept\n{s}\n\nBasic syntax\n{s}\n\nMental model\n{s}\n\nExamples\n{s}\n\nCorpus evidence\n{s}\n\nReal-world examples\n{s}\n\nAlternatives\n{s}\n\nExercise\n{s}\n\nFeedback\n{s}\n\nOptional depth\n{s}\n\nIntermediate depth\n{s}\n\nExperienced depth\n{s}\n\nTransfer notes\n{s}\n\nAnalyzer limits\n{s}\n", .{ l.title, l.id, l.prerequisite orelse "none", l.concept, l.syntax, l.mental_model, l.examples, l.corpus_evidence, l.real_examples, l.alternatives, l.exercise, l.feedback, l.optional_depth, l.intermediate_depth, l.experienced_depth, l.transfer_notes, l.analyzer_limits });
        return 0;
    }
    try w.writeAll("Ruby fundamentals path (offline)\n\n");
    for (learning.lessons, 0..) |l, i| {
        if (l.prerequisite) |p| try w.print("{d}. {s} — {s} (after {s})\n", .{ i + 1, l.id, l.title, p }) else try w.print("{d}. {s} — {s}\n", .{ i + 1, l.id, l.title });
    }
    try w.writeAll("\nChoose a lesson: rgp learn <id>\n");
    return 0;
}
