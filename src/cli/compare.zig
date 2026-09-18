//! Compare command: reproducible construct statistics from observations.
const std = @import("std");
const Io = std.Io;

const reports = @import("../reports/statistics.zig");
const storage = @import("../storage/sqlite.zig");
const manifest = @import("../corpus/manifest.zig");

const default_database = ".rgp/rgp.db";
const corpus_path = "corpus.toml";

pub const Options = struct {
    constructs: []const []const u8 = &.{},
    json: bool = false,
    classification: ?[]const u8 = null,
    receiver_kind: ?[]const u8 = null,
    project_origin: ?[]const u8 = null,
};

pub const ParseResult = union(enum) {
    options: Options,
    help,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParseResult {
    var options = Options{};
    var constructs = std.ArrayList([]const u8).empty;
    errdefer constructs.deinit(allocator);

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
        } else {
            try constructs.append(allocator, arg);
        }
    }

    options.constructs = try constructs.toOwnedSlice(allocator);
    return .{ .options = options };
}

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    const parsed = parseArgs(allocator, args) catch |err| {
        const message = switch (err) {
            error.UnknownOption => "error: unknown option; supported flags are `--json`, `--production`, `--test`, `--spec`, `--receiver-kind`, `--project`.\n",
            error.MissingValue => "error: option requires a value.\n",
            error.OutOfMemory => return error.OutOfMemory,
        };
        try writer.writeAll(message);
        try writer.writeAll(compare_usage);
        return 2;
    };

    switch (parsed) {
        .help => {
            try writer.writeAll(compare_usage);
            return 0;
        },
        .options => |options| {
            defer allocator.free(options.constructs);
            if (options.constructs.len == 0) {
                try writer.writeAll("error: `rgp compare` requires at least one construct.\n");
                try writer.writeAll(compare_usage);
                return 2;
            }

            var db = try openDatabase(io, allocator, writer, default_database);
            defer db.deinit();

            const origin = try resolveProjectOrigin(allocator, io, options.project_origin);
            defer if (origin) |o| allocator.free(o);

            const filter = reports.Filter{
                .repository_origin = origin,
                .classification = options.classification,
                .receiver_kind = options.receiver_kind,
            };

            var comparison = reports.compare(allocator, &db, options.constructs, filter) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Sqlite => {
                    try writer.writeAll("error: database query failed.\n");
                    return 1;
                },
                error.UnknownTopic => unreachable,
            };
            defer comparison.deinit(allocator);

            try reports.renderComparison(allocator, writer, comparison, .{ .json = options.json });
            return 0;
        },
    }
}

const compare_usage =
    "\nCompare usage:\n" ++
    "  rgp compare <construct>... [--json] [--production] [--test] [--spec]\n" ++
    "                             [--receiver-kind <kind>] [--project <origin>]\n" ++
    "\n" ++
    "Examples:\n" ++
    "  rgp compare size count length\n" ++
    "  rgp compare each for --production\n" ++
    "  rgp compare size count length --receiver-kind array --json\n";

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

fn resolveProjectOrigin(allocator: std.mem.Allocator, io: Io, project: ?[]const u8) !?[]u8 {
    const input = project orelse return null;

    // If it already looks like a URL or path, use it directly.
    if (std.mem.startsWith(u8, input, "https://") or std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "git@") or std.mem.startsWith(u8, input, "/") or std.mem.startsWith(u8, input, ".")) {
        return try allocator.dupe(u8, input);
    }

    // Otherwise try to resolve it as a corpus id.
    const bytes = Io.Dir.cwd().readFileAlloc(io, corpus_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return try allocator.dupe(u8, input),
        else => return err,
    };
    defer allocator.free(bytes);
    const lr = manifest.load(allocator, bytes);
    defer lr.deinit(allocator);
    if (lr.manifest) |m| {
        if (m.findById(input)) |index| {
            return try allocator.dupe(u8, m.repositories[index].source);
        }
    }
    return try allocator.dupe(u8, input);
}

test "parseArgs collects constructs and flags" {
    const opts = (try parseArgs(std.testing.allocator, &.{ "size", "count", "--json", "--production" })).options;
    defer std.testing.allocator.free(opts.constructs);
    try std.testing.expectEqual(@as(usize, 2), opts.constructs.len);
    try std.testing.expect(opts.json);
    try std.testing.expectEqualStrings("production", opts.classification.?);
}

test "parseArgs returns help" {
    const result = try parseArgs(std.testing.allocator, &.{"--help"});
    try std.testing.expectEqual(ParseResult.help, result);
}

test "parseArgs rejects unknown options" {
    try std.testing.expectError(error.UnknownOption, parseArgs(std.testing.allocator, &.{"--fast"}));
}
