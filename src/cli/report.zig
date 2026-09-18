//! Report command: reproducible topic statistics from observations.
const std = @import("std");
const Io = std.Io;

const reports = @import("../reports/statistics.zig");
const storage = @import("../storage/sqlite.zig");

const default_database = ".rgp/rgp.db";

pub const Options = struct {
    topic: ?[]const u8 = null,
    json: bool = false,
    classification: ?[]const u8 = null,
    receiver_kind: ?[]const u8 = null,
    project_origin: ?[]const u8 = null,
};

pub const ParseResult = union(enum) {
    options: Options,
    help,
};

pub fn parseArgs(args: []const []const u8) !ParseResult {
    var options = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--production")) {
            options.classification = "production";
        } else if (std.mem.eql(u8, arg, "--test")) {
            options.classification = "test";
        } else if (std.mem.eql(u8, arg, "--spec")) {
            options.classification = "spec";
        } else if (std.mem.eql(u8, arg, "--receiver-kind")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.receiver_kind = args[i];
        } else if (std.mem.eql(u8, arg, "--project")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.project_origin = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (options.topic == null) {
            options.topic = arg;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .options = options };
}

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    const parsed = parseArgs(args) catch |err| {
        const message = switch (err) {
            error.UnknownOption => "error: unknown option; supported flags are `--json`, `--production`, `--test`, `--spec`, `--receiver-kind`, `--project`.\n",
            error.MissingValue => "error: option requires a value.\n",
            error.TooManyArguments => "error: `rgp report` accepts at most one topic.\n",
        };
        try writer.writeAll(message);
        try writer.writeAll(report_usage);
        return 2;
    };

    switch (parsed) {
        .help => {
            try writer.writeAll(report_usage);
            return 0;
        },
        .options => |options| {
            const topic = options.topic orelse "collections";

            var db = try openDatabase(io, allocator, writer, default_database);
            defer db.deinit();

            const filter = reports.Filter{
                .repository_origin = options.project_origin,
                .classification = options.classification,
                .receiver_kind = options.receiver_kind,
            };

            var report = reports.reportTopic(allocator, &db, topic, filter) catch |err| switch (err) {
                error.UnknownTopic => {
                    try writer.print("error: unknown topic `{s}`; run `rgp report --help` for supported topics.\n", .{topic});
                    return 2;
                },
                error.OutOfMemory => return error.OutOfMemory,
                error.Sqlite => {
                    try writer.writeAll("error: database query failed.\n");
                    return 1;
                },
            };
            defer report.deinit(allocator);

            try reports.renderTopic(allocator, writer, report, .{ .json = options.json });
            return 0;
        },
    }
}

const report_usage =
    "\nReport usage:\n" ++
    "  rgp report [topic] [--json] [--production] [--test] [--spec]\n" ++
    "                       [--receiver-kind <kind>] [--project <origin>]\n" ++
    "\n" ++
    "Topics:\n" ++
    "  conditionals, loops_and_iteration, collections,\n" ++
    "  collections.cardinality, collections.transformation,\n" ++
    "  collections.filtering, collections.aggregation,\n" ++
    "  methods, oop, blocks, exceptions\n";

fn openDatabase(io: Io, allocator: std.mem.Allocator, writer: *Io.Writer, path: []const u8) !storage.Database {
    Io.Dir.cwd().createDirPath(io, ".rgp") catch |err| {
        try writer.print("error: cannot create `.rgp` directory: {s}\n", .{@errorName(err)});
        return error.Io;
    };
    return storage.Database.open(allocator, path) catch |err| {
        try writer.print("error: cannot open database `{s}`: {s}\n", .{ path, @errorName(err) });
        return error.Io;
    };
}

test "parseArgs accepts topic and flags" {
    const opts = (try parseArgs(&.{ "collections", "--json", "--production" })).options;
    try std.testing.expectEqualStrings("collections", opts.topic.?);
    try std.testing.expect(opts.json);
    try std.testing.expectEqualStrings("production", opts.classification.?);
}

test "parseArgs defaults topic to null" {
    const opts = (try parseArgs(&.{})).options;
    try std.testing.expect(opts.topic == null);
}

test "parseArgs returns help" {
    const result = try parseArgs(&.{"--help"});
    try std.testing.expectEqual(ParseResult.help, result);
}

test "parseArgs rejects unknown options and extra topics" {
    try std.testing.expectError(error.UnknownOption, parseArgs(&.{"--fast"}));
    try std.testing.expectError(error.TooManyArguments, parseArgs(&.{ "a", "b" }));
}
