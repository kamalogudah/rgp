const std = @import("std");
const Io = std.Io;
const reports = @import("../reports/statistics.zig");
const storage = @import("../storage/sqlite.zig");

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    var construct: ?[]const u8 = null;
    var json = false;
    var markdown = false;
    var classification: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var ruby: ?[]const u8 = null;
    var cohort: ?[]const u8 = null;
    var limit: usize = 10;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--markdown")) markdown = true else if (std.mem.eql(u8, arg, "--production")) classification = "production" else if (std.mem.eql(u8, arg, "--test")) classification = "test" else if (std.mem.eql(u8, arg, "--project")) {
            i += 1;
            if (i >= args.len) return 2;
            project = args[i];
        } else if (std.mem.eql(u8, arg, "--ruby")) {
            i += 1;
            if (i >= args.len) return 2;
            ruby = args[i];
        } else if (std.mem.eql(u8, arg, "--cohort")) {
            i += 1;
            if (i >= args.len) return 2;
            cohort = args[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) return 2;
            limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (construct == null) construct = arg else return 2;
    }
    const name = construct orelse {
        try writer.writeAll("error: `rgp examples` requires a construct or idiom.\n");
        return 2;
    };
    try Io.Dir.cwd().createDirPath(io, ".rgp");
    var db = try storage.Database.open(allocator, ".rgp/rgp.db");
    defer db.deinit();
    var found = try reports.findExamples(allocator, &db, name, .{ .classification = classification, .repository_origin = project, .ruby_version = ruby, .cohort = cohort }, limit);
    defer found.deinit(allocator);
    try reports.renderExamples(allocator, writer, found, .{ .json = json, .markdown = markdown });
    return 0;
}
