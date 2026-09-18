//! Reproducible statistics and provenance rendering for construct comparisons
//! and topic reports.
const std = @import("std");
const storage = @import("../storage/sqlite.zig");

/// User-facing filter values. These map directly to the storage query but keep
/// the reporting layer independent of SQL parameter order.
pub const Filter = struct {
    snapshot_id: ?i64 = null,
    repository_origin: ?[]const u8 = null,
    classification: ?[]const u8 = null,
    receiver_kind: ?[]const u8 = null,
    rgp_version: ?[]const u8 = null,
    prism_version: ?[]const u8 = null,
    classifier_version: ?[]const u8 = null,
    taxonomy_version: ?[]const u8 = null,

    pub fn toStorageQuery(self: Filter) storage.StatisticsQuery {
        return .{
            .snapshot_id = self.snapshot_id,
            .repository_origin = self.repository_origin,
            .classification = self.classification,
            .receiver_kind = self.receiver_kind,
            .rgp_version = self.rgp_version,
            .prism_version = self.prism_version,
            .classifier_version = self.classifier_version,
            .taxonomy_version = self.taxonomy_version,
        };
    }
};

pub const Comparison = struct {
    filter: Filter,
    statistics: []storage.Statistic,
    incomplete: bool,

    pub fn deinit(self: *Comparison, allocator: std.mem.Allocator) void {
        for (self.statistics) |*stat| stat.deinit(allocator);
        allocator.free(self.statistics);
        self.* = .{ .filter = .{}, .statistics = &.{}, .incomplete = false };
    }
};

pub const TopicReport = struct {
    topic_id: []u8,
    title: []u8,
    filter: Filter,
    statistics: []storage.Statistic,
    incomplete: bool,

    pub fn deinit(self: *TopicReport, allocator: std.mem.Allocator) void {
        allocator.free(self.topic_id);
        allocator.free(self.title);
        for (self.statistics) |*stat| stat.deinit(allocator);
        allocator.free(self.statistics);
        self.* = .{ .topic_id = &.{}, .title = &.{}, .filter = .{}, .statistics = &.{}, .incomplete = false };
    }
};

pub const Error = error{
    OutOfMemory,
    Sqlite,
    UnknownTopic,
};

/// Compare a set of constructs under a single reproducible filter.
pub fn compare(allocator: std.mem.Allocator, db: *storage.Database, constructs: []const []const u8, filter: Filter) Error!Comparison {
    const q = filter.toStorageQuery();
    const statistics = try db.queryStatistics(allocator, constructs, q);
    const incomplete = try db.hasIncompleteRuns(q);
    return .{ .filter = filter, .statistics = statistics, .incomplete = incomplete };
}

/// Report on an educational topic from `taxonomy.toml`.
pub fn reportTopic(allocator: std.mem.Allocator, db: *storage.Database, topic_id: []const u8, filter: Filter) Error!TopicReport {
    const topic = topicById(topic_id) orelse return error.UnknownTopic;
    const q = filter.toStorageQuery();
    const statistics = try db.queryStatistics(allocator, topic.constructs, q);
    const incomplete = try db.hasIncompleteRuns(q);
    return .{
        .topic_id = try allocator.dupe(u8, topic.id),
        .title = try allocator.dupe(u8, topic.title),
        .filter = filter,
        .statistics = statistics,
        .incomplete = incomplete,
    };
}

pub const RenderOptions = struct {
    json: bool = false,
};

/// Render a comparison to the supplied writer.
pub fn renderComparison(allocator: std.mem.Allocator, writer: anytype, comparison: Comparison, options: RenderOptions) !void {
    if (options.json) {
        try renderComparisonJson(allocator, writer, comparison);
    } else {
        try renderComparisonTerminal(writer, comparison);
    }
}

/// Render a topic report to the supplied writer.
pub fn renderTopic(allocator: std.mem.Allocator, writer: anytype, report: TopicReport, options: RenderOptions) !void {
    if (options.json) {
        try renderTopicJson(allocator, writer, report);
    } else {
        try renderTopicTerminal(writer, report);
    }
}

fn renderComparisonTerminal(writer: anytype, comparison: Comparison) !void {
    try writer.writeAll("Comparing: ");
    for (comparison.statistics, 0..) |stat, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(stat.construct);
    }
    try writer.writeByte('\n');

    if (comparison.statistics.len == 0) {
        try writer.writeAll("No constructs requested.\n");
        return;
    }

    const head = comparison.statistics[0];
    try renderProvenance(writer, head);
    try renderFilter(writer, head.filters);
    try writer.print("Denominator: {d} observation(s)\n", .{head.denominator});
    if (head.denominator == 0) {
        try writer.writeAll("No completed observations match the current filters.\n");
        if (comparison.incomplete) try writer.writeAll("Note: at least one matching analysis run is incomplete.\n");
        return;
    }
    if (comparison.incomplete) try writer.writeAll("Note: at least one matching analysis run is incomplete.\n");

    try writer.writeAll("\nconstruct    count    percent    projects\n");
    try writer.writeAll("-------------------------------------------\n");
    for (comparison.statistics) |stat| {
        var pct_buffer: [32]u8 = undefined;
        const pct = formatPercentage(&pct_buffer, stat.percentage);
        try writer.print("{s:<12} {d:<8} {s:<10} {d}\n", .{ stat.construct, @as(usize, @intCast(stat.count)), pct, stat.projects.len });
    }
}

fn renderTopicTerminal(writer: anytype, report: TopicReport) !void {
    try writer.print("{s}\n", .{report.title});
    for (0..report.title.len) |_| try writer.writeByte('=');
    try writer.writeByte('\n');

    if (report.statistics.len == 0) {
        try writer.writeAll("No constructs defined for this topic.\n");
        return;
    }

    const head = report.statistics[0];
    try renderProvenance(writer, head);
    try renderFilter(writer, head.filters);
    try writer.print("Denominator: {d} observation(s)\n", .{head.denominator});
    if (head.denominator == 0) {
        try writer.writeAll("No completed observations match the current filters.\n");
        if (report.incomplete) try writer.writeAll("Note: at least one matching analysis run is incomplete.\n");
        return;
    }
    if (report.incomplete) try writer.writeAll("Note: at least one matching analysis run is incomplete.\n");

    try writer.writeAll("\nconstruct    count    percent    projects\n");
    try writer.writeAll("-------------------------------------------\n");
    for (report.statistics) |stat| {
        var pct_buffer: [32]u8 = undefined;
        const pct = formatPercentage(&pct_buffer, stat.percentage);
        try writer.print("{s:<12} {d:<8} {s:<10} {d}\n", .{ stat.construct, @as(usize, @intCast(stat.count)), pct, stat.projects.len });
    }
}

fn renderProvenance(writer: anytype, stat: storage.Statistic) !void {
    var snapshot_buffer: [64]u8 = undefined;
    const snapshot_text = if (stat.snapshot_id) |id|
        std.fmt.bufPrint(&snapshot_buffer, "{d}", .{id}) catch "?"
    else
        "none";
    try writer.print("Snapshot:    {s}\n", .{snapshot_text});
    try writer.print("Versions:    rgp={s} prism={s} classifier={s} taxonomy={s}\n", .{ stat.rgp_version, stat.prism_version, stat.classifier_version, stat.taxonomy_version });
}

fn renderFilter(writer: anytype, filters: storage.AppliedFilter) !void {
    try writer.writeAll("Filter:      ");
    var first = true;
    const pairs = .{
        .{ "repository", filters.repository_origin },
        .{ "classification", filters.classification },
        .{ "receiver_kind", filters.receiver_kind },
        .{ "rgp_version", filters.rgp_version },
        .{ "prism_version", filters.prism_version },
        .{ "classifier_version", filters.classifier_version },
        .{ "taxonomy_version", filters.taxonomy_version },
    };
    inline for (pairs) |pair| {
        const name = pair.@"0";
        const value = pair.@"1";
        if (value) |v| {
            if (!first) try writer.writeAll(", ");
            try writer.print("{s}={s}", .{ name, v });
            first = false;
        }
    }
    if (first) try writer.writeAll("none");
    try writer.writeByte('\n');
}

fn formatPercentage(buffer: []u8, percentage: ?f64) []const u8 {
    if (percentage) |p| {
        return std.fmt.bufPrint(buffer, "{d:.1}%", .{p}) catch "-";
    }
    return "-";
}

fn renderComparisonJson(allocator: std.mem.Allocator, writer: anytype, comparison: Comparison) !void {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const w = &output.writer;
    try w.writeAll("{\"filter\":");
    try renderFilterJson(w, comparison.filter);
    try w.writeAll(",\"incomplete\":");
    try w.print("{s}", .{if (comparison.incomplete) "true" else "false"});
    try w.writeAll(",\"statistics\":[");
    for (comparison.statistics, 0..) |stat, i| {
        if (i > 0) try w.writeByte(',');
        try renderStatisticJson(w, stat);
    }
    try w.writeAll("]}\n");
    try writer.writeAll(output.written());
}

fn renderTopicJson(allocator: std.mem.Allocator, writer: anytype, report: TopicReport) !void {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const w = &output.writer;
    try w.writeAll("{\"topic\":\"");
    try writeJsonString(w, report.topic_id);
    try w.writeAll("\",\"title\":\"");
    try writeJsonString(w, report.title);
    try w.writeAll("\",\"filter\":");
    try renderFilterJson(w, report.filter);
    try w.writeAll(",\"incomplete\":");
    try w.print("{s}", .{if (report.incomplete) "true" else "false"});
    try w.writeAll(",\"statistics\":[");
    for (report.statistics, 0..) |stat, i| {
        if (i > 0) try w.writeByte(',');
        try renderStatisticJson(w, stat);
    }
    try w.writeAll("]}\n");
    try writer.writeAll(output.written());
}

fn renderFilterJson(writer: anytype, filter: Filter) !void {
    try writer.writeByte('{');
    var first = true;
    if (filter.snapshot_id) |id| {
        try writer.print("\"snapshot_id\":{d}", .{id});
        first = false;
    }
    const string_pairs = .{
        .{ "repository_origin", filter.repository_origin },
        .{ "classification", filter.classification },
        .{ "receiver_kind", filter.receiver_kind },
        .{ "rgp_version", filter.rgp_version },
        .{ "prism_version", filter.prism_version },
        .{ "classifier_version", filter.classifier_version },
        .{ "taxonomy_version", filter.taxonomy_version },
    };
    inline for (string_pairs) |pair| {
        const name = pair.@"0";
        const value = pair.@"1";
        if (value) |v| {
            if (!first) try writer.writeByte(',');
            try writer.print("\"{s}\":\"", .{name});
            try writeJsonString(writer, v);
            try writer.writeByte('"');
            first = false;
        }
    }
    try writer.writeByte('}');
}

fn renderStatisticJson(writer: anytype, stat: storage.Statistic) !void {
    try writer.writeAll("{\"construct\":\"");
    try writeJsonString(writer, stat.construct);
    try writer.writeAll("\",\"snapshot_id\":");
    if (stat.snapshot_id) |id| {
        try writer.print("{d}", .{id});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"rgp_version\":\"{s}\",", .{stat.rgp_version});
    try writer.print("\"prism_version\":\"{s}\",", .{stat.prism_version});
    try writer.print("\"classifier_version\":\"{s}\",", .{stat.classifier_version});
    try writer.print("\"taxonomy_version\":\"{s}\",", .{stat.taxonomy_version});
    try writer.print("\"denominator\":{d},", .{stat.denominator});
    try writer.print("\"count\":{d},", .{stat.count});
    try writer.writeAll("\"percentage\":");
    if (stat.percentage) |p| {
        try writer.print("{d:.6}", .{p});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"projects\":[");
    for (stat.projects, 0..) |project, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"repository_id\":{d},\"origin\":\"", .{project.repository_id});
        try writeJsonString(writer, project.origin);
        try writer.print("\",\"count\":{d}}}", .{project.count});
    }
    try writer.writeAll("]}");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u00{x:0>2}", .{byte}) else try writer.writeByte(byte),
    };
}

const Topic = struct { id: []const u8, title: []const u8, constructs: []const []const u8 };

fn topicById(id: []const u8) ?Topic {
    const topics = [_]Topic{
        .{ .id = "conditionals", .title = "Conditionals", .constructs = &.{ "if", "unless", "case" } },
        .{ .id = "loops_and_iteration", .title = "Loops and Iteration", .constructs = &.{ "while", "until", "for", "each", "times" } },
        .{ .id = "collections", .title = "Collections", .constructs = &.{ "size", "length", "count", "map", "collect", "select", "filter", "reject", "reduce", "inject" } },
        .{ .id = "collections.cardinality", .title = "Collection Cardinality", .constructs = &.{ "size", "length", "count" } },
        .{ .id = "collections.transformation", .title = "Collection Transformation", .constructs = &.{ "map", "collect" } },
        .{ .id = "collections.filtering", .title = "Collection Filtering", .constructs = &.{ "select", "filter", "reject" } },
        .{ .id = "collections.aggregation", .title = "Collection Aggregation", .constructs = &.{ "reduce", "inject" } },
        .{ .id = "methods", .title = "Methods", .constructs = &.{"def"} },
        .{ .id = "oop", .title = "Object-Oriented Ruby", .constructs = &.{ "class", "module" } },
        .{ .id = "blocks", .title = "Blocks", .constructs = &.{"block"} },
        .{ .id = "exceptions", .title = "Exceptions", .constructs = &.{"rescue"} },
    };
    for (topics) |topic| {
        if (std.mem.eql(u8, topic.id, id)) return topic;
    }
    return null;
}

test "report renders empty corpus with explicit zero denominator" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    var comparison = try compare(std.testing.allocator, &db, &.{"each"}, .{});
    defer comparison.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), comparison.statistics.len);
    try std.testing.expectEqual(@as(i64, 0), comparison.statistics[0].denominator);
    try std.testing.expect(comparison.statistics[0].percentage == null);
    try std.testing.expect(!comparison.incomplete);
}

test "report topic maps taxonomy constructs" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("project-r");
    const commit = try db.addCommit(repo, "sha-r");
    const file = try db.addFile(commit, "lib/a.rb", "hash");
    const each = try db.addConstruct("each");
    const map = try db.addConstruct("map");
    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" }, &.{
        .{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = each },
        .{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 5, .end_offset = 8, .line = 2, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = map },
    });

    var report = try reportTopic(std.testing.allocator, &db, "loops_and_iteration", .{});
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("loops_and_iteration", report.topic_id);
    try std.testing.expectEqual(@as(usize, 5), report.statistics.len);
    try std.testing.expectEqual(@as(i64, 2), report.statistics[0].denominator);
}

test "percentage is calculated against shared denominator" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("project-p");
    const commit = try db.addCommit(repo, "sha-p");
    const file = try db.addFile(commit, "lib/a.rb", "hash");
    const size = try db.addConstruct("size");
    const length = try db.addConstruct("length");
    const count = try db.addConstruct("count");
    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" }, &.{
        .{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = size },
        .{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 5, .end_offset = 11, .line = 2, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = length },
        .{ .repository_id = repo, .commit_id = commit, .file_id = file, .start_offset = 12, .end_offset = 17, .line = 3, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = count },
    });

    var comparison = try compare(std.testing.allocator, &db, &.{ "size", "length", "count" }, .{});
    defer comparison.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), comparison.statistics.len);
    for (comparison.statistics) |stat| {
        try std.testing.expectEqual(@as(i64, 3), stat.denominator);
        try std.testing.expectEqual(@as(i64, 1), stat.count);
        try std.testing.expectApproxEqAbs(@as(f64, 33.333333), stat.percentage.?, 0.0001);
    }
}
