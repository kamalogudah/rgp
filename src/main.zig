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
    "  compare <construct>...  Compare construct counts and percentages\n" ++
    "  report [topic]          Report on a taxonomy topic\n" ++
    "  examples <construct>     Retrieve cited source examples\n" ++
    "  learn [lesson]           Follow the offline Ruby fundamentals path\n  practice [topic]          List practice exercises by topic or level\n" ++
    "  idioms <file>           Report conservative idiom matches\n" ++ "  agent <list|use|status> Manage coding-agent adapters (fx is optional)\n" ++
    "  ask [--agent name] <question> Ask through a selected coding agent\n" ++
    "  explain [--level profile] file.rb[:20-35] Explain a source range offline\n" ++
    "  recommend [--learner ID] [--level profile] Recommend evidence-backed lessons\n" ++
    "  tutor --learner ID --attempt ID [--step step] Socratic exercise tutoring\n" ++
    "  corpus                  Manage the analyzed corpus\n" ++
    "  parse <file>            Parse a Ruby file and emit JSON\n" ++
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
    if (args.len > 0 and std.mem.eql(u8, args[0], "compare")) {
        return rgp.cli.compare.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "report")) {
        return rgp.cli.report.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "corpus")) {
        return rgp.cli.corpus.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "examples")) {
        return rgp.cli.examples.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "practice")) {
        return rgp.cli.practice.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "learn")) {
        return rgp.cli.learn.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "idioms")) {
        return rgp.cli.idioms.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "ask")) {
        return rgp.cli.ask.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "explain")) {
        return rgp.cli.explain.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "recommend")) {
        return rgp.cli.recommend.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "tutor")) {
        return rgp.cli.tutor.run(io, allocator, args[1..], writer);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "agent")) {
        return rgp.cli.agent.run(io, allocator, args[1..], writer);
    }
    switch (try rgp.parseCommand(args)) {
        .help => try writer.writeAll(usage),
        .version => try writer.print("rgp {s}\n", .{rgp.version}),
    }
    return 0;
}

test "section 35 commands run end to end" {
    const allocator = std.testing.allocator;

    const cwd_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd_path);
    const exe = try std.fs.path.resolve(allocator, &.{ cwd_path, "zig-out/bin/rgp" });
    defer allocator.free(exe);

    var tmp = std.testing.tmpDir(.{ .iterate = false });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.rb",
        .data = "items.each { |i| i }\n" ++
            "for i in items\n" ++
            "end\n" ++
            "3.times { }\n" ++
            "while false\n" ++
            "end\n" ++
            "items.size\n" ++
            "items.count\n" ++
            "items.length\n" ++
            "items.map { |i| i }\n" ++
            "items.collect { |i| i }\n" ++
            "items.select { |i| i }\n" ++
            "items.filter { |i| i }\n" ++
            "items.reject { |i| i }\n" ++
            "items.reduce(0) { |s, i| s + i }\n" ++
            "items.inject(0) { |s, i| s + i }\n" ++
            "if true\n" ++
            "end\n" ++
            "unless false\n" ++
            "end\n" ++
            "case items\n" ++
            "when nil\n" ++
            "end\n" ++
            "begin\n" ++
            "rescue StandardError\n" ++
            "end\n",
    });

    const analyze = try runCommand(allocator, exe, tmp.dir, &.{ "analyze", "." });
    defer allocator.free(analyze.stdout);
    defer allocator.free(analyze.stderr);
    try std.testing.expect(std.mem.indexOf(u8, analyze.stdout, "analyzed") != null);

    const commands = [_][]const []const u8{
        &.{ "compare", "each", "for" },
        &.{ "compare", "times", "while" },
        &.{ "compare", "size", "count", "length" },
        &.{ "compare", "map", "collect" },
        &.{ "compare", "select", "filter", "reject" },
        &.{ "compare", "reduce", "inject" },
        &.{ "compare", "if", "unless" },
        &.{ "compare", "case", "if" },
        &.{ "compare", "block" },
        &.{ "report", "conditionals" },
        &.{ "report", "collections" },
        &.{ "report", "loops-and-iteration" },
    };

    for (commands) |args| {
        const result = try runCommand(allocator, exe, tmp.dir, args);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Denominator:") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, rgp.reports.raw_syntax_note) != null);
    }
}

fn runCommand(allocator: std.mem.Allocator, exe: []const u8, dir: std.Io.Dir, args: []const []const u8) !std.process.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.appendSlice(allocator, args);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try dir.realPath(std.testing.io, &path_buffer);

    return try std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = path_buffer[0..cwd_len] },
    });
}
