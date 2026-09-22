const std = @import("std");
const Io = std.Io;
const registry_mod = @import("../agent/registry.zig");

pub fn run(_: Io, _: std.mem.Allocator, args: []const []const u8, w: *Io.Writer) !u8 {
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        const registry = registry_mod.Registry{};
        for (registry.list()) |adapter| try w.print("{s}{s} [{s}]\n", .{ adapter.name, if (std.mem.eql(u8, adapter.name, registry.selected)) " *" else "", if (adapter.available) "available" else "unavailable" });
        return 0;
    }
    if (std.mem.eql(u8, args[0], "status")) {
        const info = (registry_mod.Registry{}).info();
        try w.print("selected: {s}\ndefault: {s}\nstatus: {s}\n", .{ info.name, if (info.default) "yes" else "no", if (info.available) "available" else "unavailable" });
        return 0;
    }
    if (std.mem.eql(u8, args[0], "use") and args.len == 2) {
        var registry = registry_mod.Registry{};
        registry.use(args[1]) catch |err| if (err == error.UnknownAdapter) {
            try w.print("error: unknown agent `{s}`\n", .{args[1]});
            return 2;
        } else return err;
        try w.print("selected: {s} (process-local)\n", .{registry.selected});
        return 0;
    }
    return 2;
}

test "agent CLI reports optional fx without breaking offline operation" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(u8, 0), try run(undefined, std.testing.allocator, &.{"status"}, &output.writer));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "selected: fx") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "unavailable") != null);
}
