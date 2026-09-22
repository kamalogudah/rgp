const std = @import("std");
const Io = std.Io;
const exercises = @import("../exercises.zig");

pub fn run(_: Io, _: std.mem.Allocator, args: []const []const u8, w: *Io.Writer) !u8 {
    var topic: ?[]const u8 = null;
    var level: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--level")) {
            i += 1;
            if (i >= args.len) return 2;
            level = args[i];
        } else if (topic == null) topic = args[i] else return 2;
    }
    var shown: usize = 0;
    for (exercises.exercises) |exercise| {
        if (topic) |wanted| if (!std.mem.eql(u8, wanted, exercise.topic)) continue;
        if (level) |wanted| if (!std.mem.eql(u8, wanted, exercise.level)) continue;
        try w.print("{s} [{s}] {s}\n  {s}\n", .{ exercise.id, exercise.level, exercise.title, exercise.prompt });
        shown += 1;
    }
    if (shown == 0) try w.writeAll("No matching practice exercises.\n");
    return 0;
}

test "practice filters by topic and level" {
    try std.testing.expectEqualStrings("collections", exercises.exercises[0].topic);
    try std.testing.expectEqualStrings("beginner", exercises.exercises[0].level);
}
