const std = @import("std");
const Io = std.Io;
const registry_mod = @import("../agent/registry.zig");
const storage = @import("../storage/sqlite.zig");
const sessions = @import("../agent/session.zig");
const gateway = @import("../agent/gateway.zig");

/// Selection is explicit and observable even before an external adapter is
/// installed. This command never silently falls back to a different agent.
pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8, w: *Io.Writer) !u8 {
    var registry = registry_mod.Registry{};
    var i: usize = 0;
    var text_start: usize = 0;
    var session_key: []const u8 = "default";
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--resume")) {
            if (i + 1 >= args.len) return 2;
            if (std.mem.eql(u8, args[i], "--resume")) {
                i += 1;
                session_key = args[i];
            }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--agent")) {
            if (i + 1 >= args.len) return 2;
            if (std.mem.eql(u8, args[i], "--resume")) {
                i += 1;
                session_key = args[i];
            }
            registry.use(args[i + 1]) catch {
                try w.print("error: unknown agent `{s}`\n", .{args[i + 1]});
                return 2;
            };
            i += 1;
            text_start = i + 1;
        } else if (text_start == 0) text_start = i;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "--interactive")) return interactive(io, allocator, w, session_key);
    if (text_start >= args.len) return 2;
    try Io.Dir.cwd().createDirPath(io, ".rgp");
    var db = try storage.Database.open(allocator, ".rgp/rgp.db");
    defer db.deinit();
    var session = try sessions.open(allocator, &db, session_key, registry.selected, null, null, null, null);
    defer allocator.free(session.key);
    var tools = gateway.Gateway.init(allocator, &db);
    defer tools.deinit();
    var preflight = try tools.dispatch(.{ .tool = "rgp.get_stats", .input = "{}" });
    defer preflight.deinit(allocator);
    try w.print("deterministic preflight: {s} ({s})\n", .{ if (preflight.ok) "completed" else "unavailable", preflight.result_id });
    try session.beginPrompt(args[text_start..][0]);
    const info = registry.info();
    if (!info.available) {
        try session.interrupt();
        try w.print("agent `{s}` is unavailable; install/configure it or use the offline RGP commands\n", .{info.name});
        return 2;
    }
    return 0;
}
fn interactive(io: Io, allocator: std.mem.Allocator, w: *Io.Writer, session_key: []const u8) !u8 {
    try Io.Dir.cwd().createDirPath(io, ".rgp");
    var db = try storage.Database.open(allocator, ".rgp/rgp.db");
    defer db.deinit();
    var session = try sessions.open(allocator, &db, session_key, "fx", null, null, null, null);
    defer allocator.free(session.key);
    try w.writeAll("rgp> ");
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.Reader.init(.stdin(), io, &buffer);
    while (true) {
        const line = reader.interface.takeDelimiterExclusive('\n') catch break;
        if (std.mem.eql(u8, line, ":quit")) break;
        if (std.mem.eql(u8, line, ":compact")) {
            try session.compact(w);
            try w.writeAll("\nrgp> ");
            continue;
        }
        if (line.len == 0) {
            try w.writeAll("rgp> ");
            continue;
        }
        try session.beginPrompt(line);
        try session.interrupt();
        try w.writeAll("saved interrupted turn\nrgp> ");
    }
    return 0;
}
