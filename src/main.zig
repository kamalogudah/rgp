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
    "  analyze [path | --corpus]  Analyze a repository or the whole corpus\n" ++
    "  corpus                 Manage the analyzed corpus\n" ++
    "  parse <file>           Parse a Ruby file and emit JSON\n" ++
    "\n" ++
    "Run `rgp corpus` for corpus-management usage.\n";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const writer = &stdout.interface;

    const exit_code = run(args[1..], writer, init.io, init.arena.allocator()) catch |err| switch (err) {
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

fn run(args: []const []const u8, writer: *Io.Writer, io: Io, allocator: std.mem.Allocator) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "parse")) {
        if (args.len != 2) return error.unexpected_argument;
        const source = try Io.Dir.cwd().readFileAlloc(io, args[1], allocator, .limited(std.math.maxInt(usize)));
        defer allocator.free(source);
        var document = try rgp.prism.parse(allocator, source, .{ .path = args[1] });
        defer document.deinit();
        try rgp.traversal.writeJson(&document, writer);
        return 0;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "analyze")) {
        return rgp.cli.analyze.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "corpus")) {
        return rgp.cli.corpus.run(io, allocator, args[1..], writer);
    }
    switch (try rgp.parseCommand(args)) {
        .help => try writer.writeAll(usage),
        .version => try writer.print("rgp {s}\n", .{rgp.version}),
    }
    return 0;
}
