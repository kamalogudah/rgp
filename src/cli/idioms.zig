//! Report conservative, versioned idiom matches for one Ruby file.
const std = @import("std");
const Io = std.Io;
const prism = @import("../prism/parser.zig");
const observation = @import("../analysis/observation.zig");
const rules = @import("../analysis/idioms.zig");

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    var json = false;
    var path: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.startsWith(u8, arg, "-")) return usage(writer) else if (path == null) path = arg else return usage(writer);
    }
    const file_path = path orelse return usage(writer);
    const source = Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        try writer.print("error: cannot read `{s}`: {s}\n", .{ file_path, @errorName(err) });
        return 1;
    };
    defer allocator.free(source);
    var document = prism.parse(allocator, source, .{ .path = file_path }) catch |err| {
        try writer.print("error: cannot parse `{s}`: {s}\n", .{ file_path, @errorName(err) });
        return 1;
    };
    defer document.deinit();
    if (!document.success()) return 1;
    const observations = try observation.extract(allocator, &document);
    defer allocator.free(observations);
    const matches = try rules.detectSource(allocator, source, observations);
    defer allocator.free(matches);
    if (json) {
        try writer.print("{{\"path\":\"{s}\",\"rule_version\":\"{s}\",\"matches\":[", .{ file_path, rules.rule_version });
        for (matches, 0..) |match, i| {
            if (i > 0) try writer.writeByte(',');
            const obs = observations[match.observation_index];
            try writer.print("{{\"start_offset\":{d},\"end_offset\":{d},\"line\":{d},\"column\":{d},\"idiom_id\":\"{s}\",\"classification\":\"{s}\",\"confidence\":\"{s}\",\"reason\":\"{s}\"}}", .{ obs.start_offset, obs.end_offset, obs.line, obs.column, match.idiom_id, @tagName(match.classification), match.confidence, match.reason });
        }
        try writer.writeAll("]}\n");
    } else for (matches) |match| {
        const obs = observations[match.observation_index];
        try writer.print("{s}:{d}:{d}-{d} idiom={s} classification={s} confidence={s} reason={s}\n", .{ file_path, obs.line, obs.column, obs.end_offset, match.idiom_id, @tagName(match.classification), match.confidence, match.reason });
    }
    return 0;
}

fn usage(writer: *Io.Writer) !u8 {
    try writer.writeAll("Idioms usage:\n  rgp idioms <file.rb> [--json]\n");
    return 2;
}

test "idiom command usage is stable" {
    var output = Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(u8, 2), try usage(&output.writer));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "rgp idioms") != null);
}
