//! Offline repository concept map and selected cohort comparison command.
const std = @import("std");
const Io = std.Io;
const storage = @import("../storage/sqlite.zig");
const reports = @import("../reports/statistics.zig");
const concepts = @import("../reports/concepts.zig");

pub fn run(_: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    var project: ?[]const u8 = null;
    var compare_cohorts = std.ArrayList([]const u8).empty;
    defer compare_cohorts.deinit(allocator);
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            try writer.writeAll(usage);
            return 0;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--compare-cohort")) {
            i += 1;
            if (i >= args.len) return 2;
            try compare_cohorts.append(allocator, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            try writer.writeAll(usage);
            return 2;
        }
        if (project != null) {
            try writer.writeAll(usage);
            return 2;
        }
        project = arg;
    }
    const origin = project orelse {
        try writer.writeAll(usage);
        return 2;
    };
    var db = storage.Database.open(allocator, ".rgp/rgp.db") catch {
        try writer.writeAll("error: cannot open `.rgp/rgp.db`.\n");
        return 1;
    };
    defer db.deinit();
    var map = concepts.build(allocator, &db, .{ .repository_origin = origin }) catch {
        try writer.writeAll("error: repository has no completed offline analysis.\n");
        return 1;
    };
    defer map.deinit(allocator);
    if (json) return renderJson(writer, map);
    try writer.print("Repository concept map: {s}\n", .{origin});
    try writer.writeAll("Evidence is limited to completed local observations; raw syntax is not semantic equivalence.\n\nObserved concepts\n");
    for (map.observed) |name| {
        var title: []const u8 = "Unclassified observed construct";
        var prerequisite: []const u8 = "unknown";
        for (concepts.known) |concept| if (std.mem.eql(u8, concept.id, name)) {
            title = concept.title;
            prerequisite = concept.prerequisite orelse "none";
        };
        try writer.print("- {s}: {s}; prerequisite: {s}\n", .{ name, title, prerequisite });
    }
    try writer.writeAll("\nRepresentative source spans\n");
    for (map.examples) |example| try writer.print("- {s}@{s} {s}:{d}:{d} offsets={d}..{d}\n", .{ example.repository_origin, example.commit_sha, example.file_path, example.line, example.column, example.start_offset, example.end_offset });
    try writer.writeAll("\nAbsent concepts\n");
    for (map.absent) |concept| try writer.print("- {s} (prerequisite: {s})\n", .{ concept.id, concept.prerequisite orelse "none" });
    try writer.writeAll("\nUnknown observed constructs\n");
    if (map.unknown.len == 0) try writer.writeAll("- none\n") else for (map.unknown) |name| try writer.print("- {s}\n", .{name});
    if (compare_cohorts.items.len > 0) {
        try writer.writeAll("\nCohort comparison\n");
        const constructs = map.observed;
        for (compare_cohorts.items) |cohort| {
            var stats = try reports.compare(allocator, &db, constructs, .{ .cohort = cohort });
            defer stats.deinit(allocator);
            try writer.print("\n[{s}]\n", .{cohort});
            if (stats.statistics.len == 0) {
                try writer.writeAll("No completed observations; absent/unknown for this cohort.\n");
                continue;
            }
            try writer.print("Denominator: {d} observations; projects and filters are cohort-scoped.\n", .{stats.statistics[0].denominator});
            try writer.writeAll("construct    count    percent    confidence\n");
            for (stats.statistics) |stat| try writer.print("{s:<12} {d:<8} {d:.2}%    {s}\n", .{ stat.construct, stat.count, stat.percentage orelse 0, confidence(stat) });
            try writer.print("Snapshot/analyzer provenance: snapshot={d}, rgp={s}, prism={s}, classifier={s}, taxonomy={s}\n", .{ stats.statistics[0].snapshot_id orelse -1, stats.statistics[0].rgp_version, stats.statistics[0].prism_version, stats.statistics[0].classifier_version, stats.statistics[0].taxonomy_version });
            if (stats.incomplete) try writer.writeAll("Warning: matching analysis runs are incomplete.\n");
        }
    }
    try writer.writeAll("\nCorpus bias: this is a pinned, curated corpus; project/category selection, file classification, and missing analysis can skew comparisons.\n");
    return 0;
}

fn confidence(stat: storage.Statistic) []const u8 {
    if (stat.denominator == 0) return "none";
    if (stat.projects.len >= 3) return "high";
    if (stat.projects.len == 2) return "medium";
    return "low";
}

fn renderJson(writer: *Io.Writer, map: concepts.Map) !u8 {
    try writer.writeAll("{\"observed\":[");
    for (map.observed, 0..) |name, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{name});
    }
    try writer.writeAll("],\"absent\":[");
    for (map.absent, 0..) |concept, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":\"{s}\",\"prerequisite\":\"{s}\"}}", .{ concept.id, concept.prerequisite orelse "none" });
    }
    try writer.writeAll("],\"unknown\":[");
    for (map.unknown, 0..) |name, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{name});
    }
    try writer.writeAll("]}\n");
    return 0;
}

const usage = "\nUsage: rgp learn-repo <project-origin> [--compare-cohort <name>]... [--json]\n";
