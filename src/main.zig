const std = @import("std");
const Io = std.Io;
const rgp = @import("rgp");

const usage =
    "RGP — Ruby: The Good Parts\n" ++
    "Learn Ruby from how Ruby is actually written.\n" ++
    "\n" ++
    "Usage:\n" ++
    "  rgp [command]\n" ++
    "\n" ++
    "Commands:\n" ++
    "  help, --help, -h       Show this help\n" ++
    "  --version, -V          Show the RGP version\n" ++
    "\n" ++
    "Analysis, corpus, reporting, learning, and practice commands will be\n" ++
    "introduced through the roadmap. Run `rgp --help` to see available commands.\n";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const writer = &stdout.interface;

    const exit_code = run(args[1..], writer) catch |err| switch (err) {
        error.unknown_command => blk: {
            try writer.print("error: unknown command `{s}`. Run `rgp --help` for usage.\n", .{args[1]});
            break :blk @as(u8, 2);
        },
        error.unexpected_argument => blk: {
            try writer.print("error: this command does not accept additional arguments. Run `rgp --help` for usage.\n", .{});
            break :blk @as(u8, 2);
        },
        else => return err,
    };

    try writer.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(args: []const []const u8, writer: *Io.Writer) !u8 {
    switch (try rgp.parseCommand(args)) {
        .help => try writer.writeAll(usage),
        .version => try writer.print("rgp {s}\n", .{rgp.version}),
    }
    return 0;
}
