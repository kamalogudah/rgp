const std = @import("std");
const Io = std.Io;
const registry_mod = @import("../agent/registry.zig");

/// Selection is explicit and observable even before an external adapter is
/// installed. This command never silently falls back to a different agent.
pub fn run(_: Io, _: std.mem.Allocator, args: []const []const u8, w: *Io.Writer) !u8 {
    var registry = registry_mod.Registry{};
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--agent")) {
            if (i + 1 >= args.len) return 2;
            registry.use(args[i + 1]) catch {
                try w.print("error: unknown agent `{s}`\n", .{args[i + 1]});
                return 2;
            };
            i += 1;
            text_start = i + 1;
        } else if (text_start == 0) text_start = i;
    }
    if (text_start >= args.len) return 2;
    const info = registry.info();
    if (!info.available) {
        try w.print("agent `{s}` is unavailable; install/configure it or use the offline RGP commands\n", .{info.name});
        return 2;
    }
    return 0;
}
