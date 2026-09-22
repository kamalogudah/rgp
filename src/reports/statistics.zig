//! Reproducible statistics and provenance rendering for construct comparisons
//! and topic reports.
const std = @import("std");
const storage = @import("../storage/sqlite.zig");
const taxonomy = @import("../config/taxonomy.zig");

const build_options = @import("config_options");
const taxonomy_text = build_options.taxonomy_text;
const idioms_text = build_options.idioms_text;

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
    ruby_version: ?[]const u8 = null,
    cohort: ?[]const u8 = null,

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
            .ruby_version = self.ruby_version,
            .cohort = self.cohort,
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

pub const CohortDelta = struct {
    cohort: []u8,
    from_observations: i64,
    to_observations: i64,
    from_projects: i64,
    to_projects: i64,

    pub fn deinit(self: *CohortDelta, allocator: std.mem.Allocator) void {
        allocator.free(self.cohort);
    }
};

pub const HistoricalChange = struct {
    construct: []u8,
    from_count: i64,
    to_count: i64,
    from_denominator: i64,
    to_denominator: i64,
    from_percentage: ?f64,
    to_percentage: ?f64,
    absolute_change: i64,
    normalized_change: ?f64,

    pub fn deinit(self: *HistoricalChange, allocator: std.mem.Allocator) void {
        allocator.free(self.construct);
    }
};

pub const SnapshotComparison = struct {
    from_snapshot: i64,
    to_snapshot: i64,
    changes: []HistoricalChange,
    cohorts: []CohortDelta,

    pub fn deinit(self: *SnapshotComparison, allocator: std.mem.Allocator) void {
        for (self.changes) |*change| change.deinit(allocator);
        allocator.free(self.changes);
        for (self.cohorts) |*cohort| cohort.deinit(allocator);
        allocator.free(self.cohorts);
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
    IncompatibleAnalyzers,
};

/// Compare a set of constructs under a single reproducible filter.
pub fn compare(allocator: std.mem.Allocator, db: *storage.Database, constructs: []const []const u8, filter: Filter) Error!Comparison {
    const q = filter.toStorageQuery();
    const statistics = try db.queryStatistics(allocator, constructs, q);
    const incomplete = try db.hasIncompleteRuns(q);
    return .{ .filter = filter, .statistics = statistics, .incomplete = incomplete };
}

/// Compare two pinned snapshots. Counts are absolute; normalized changes are
/// percentage-point changes against each snapshot's own denominator.
pub fn compareSnapshots(allocator: std.mem.Allocator, db: *storage.Database, constructs: []const []const u8, filter: Filter, from_snapshot: i64, to_snapshot: i64) Error!SnapshotComparison {
    var from_filter = filter;
    from_filter.snapshot_id = from_snapshot;
    var to_filter = filter;
    to_filter.snapshot_id = to_snapshot;
    const from_stats = try db.queryStatistics(allocator, constructs, from_filter.toStorageQuery());
    defer { for (from_stats) |*stat| stat.deinit(allocator); allocator.free(from_stats); }
    const to_stats = try db.queryStatistics(allocator, constructs, to_filter.toStorageQuery());
    defer { for (to_stats) |*stat| stat.deinit(allocator); allocator.free(to_stats); }
    if (from_stats.len != to_stats.len) return error.Sqlite;
    for (from_stats, to_stats) |before, after| {
        if (!std.mem.eql(u8, before.classifier_version, after.classifier_version) or !std.mem.eql(u8, before.taxonomy_version, after.taxonomy_version)) return error.IncompatibleAnalyzers;
    }
    var changes = try allocator.alloc(HistoricalChange, constructs.len);
    errdefer allocator.free(changes);
    for (from_stats, to_stats, 0..) |before, after, i| {
        changes[i] = .{ .construct = try allocator.dupe(u8, constructs[i]), .from_count = before.count, .to_count = after.count, .from_denominator = before.denominator, .to_denominator = after.denominator, .from_percentage = before.percentage, .to_percentage = after.percentage, .absolute_change = after.count - before.count, .normalized_change = if (before.percentage != null and after.percentage != null) after.percentage.? - before.percentage.? else null };
    }
    const from_cohorts = try db.queryCohorts(allocator, from_filter.toStorageQuery());
    defer { for (from_cohorts) |*cohort| cohort.deinit(allocator); allocator.free(from_cohorts); }
    const to_cohorts = try db.queryCohorts(allocator, to_filter.toStorageQuery());
    defer { for (to_cohorts) |*cohort| cohort.deinit(allocator); allocator.free(to_cohorts); }
    var cohorts = std.ArrayList(CohortDelta).empty;
    errdefer { for (cohorts.items) |*cohort| cohort.deinit(allocator); cohorts.deinit(allocator); }
    for (from_cohorts) |before| {
        var found = false;
        for (to_cohorts) |after| if (std.mem.eql(u8, before.cohort, after.cohort)) { try cohorts.append(allocator, .{ .cohort = try allocator.dupe(u8, before.cohort), .from_observations = before.observations, .to_observations = after.observations, .from_projects = before.projects, .to_projects = after.projects }); found = true; break; };
        if (!found) try cohorts.append(allocator, .{ .cohort = try allocator.dupe(u8, before.cohort), .from_observations = before.observations, .to_observations = 0, .from_projects = before.projects, .to_projects = 0 });
    }
    for (to_cohorts) |after| {
        var found = false;
        for (from_cohorts) |before| if (std.mem.eql(u8, before.cohort, after.cohort)) { found = true; break; };
        if (!found) try cohorts.append(allocator, .{ .cohort = try allocator.dupe(u8, after.cohort), .from_observations = 0, .to_observations = after.observations, .from_projects = 0, .to_projects = after.projects });
    }
    return .{ .from_snapshot = from_snapshot, .to_snapshot = to_snapshot, .changes = changes, .cohorts = try cohorts.toOwnedSlice(allocator) };
}

/// Report on an educational topic from `taxonomy.toml`.
pub fn reportTopic(allocator: std.mem.Allocator, db: *storage.Database, topic_id: []const u8, filter: Filter) Error!TopicReport {
    var loaded = taxonomy.load(allocator, taxonomy_text, idioms_text) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnknownTopic,
    };
    defer loaded.deinit();
    const configured = loaded.topic(topic_id) orelse return error.UnknownTopic;
    const q = filter.toStorageQuery();
    const statistics = try db.queryStatistics(allocator, configured.constructs, q);
    const incomplete = try db.hasIncompleteRuns(q);
    return .{
        .topic_id = try allocator.dupe(u8, configured.id),
        .title = try allocator.dupe(u8, configured.title),
        .filter = filter,
        .statistics = statistics,
        .incomplete = incomplete,
    };
}

pub const Examples = struct {
    construct: []u8,
    items: []storage.SourceObservation,
    filter: Filter,
    pub fn deinit(self: *Examples, allocator: std.mem.Allocator) void {
        allocator.free(self.construct);
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub fn findExamples(allocator: std.mem.Allocator, db: *storage.Database, construct: []const u8, filter: Filter, limit: usize) Error!Examples {
    return .{ .construct = try allocator.dupe(u8, construct), .items = db.findExamples(allocator, construct, filter.toStorageQuery(), limit) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Sqlite, .filter = filter };
}

pub const RenderOptions = struct {
    json: bool = false,
    markdown: bool = false,
};

pub const raw_syntax_note = "These figures are raw syntax frequencies from the current corpus; they describe how often each construct appears, not semantic equivalence.";

pub fn renderExamples(allocator: std.mem.Allocator, writer: anytype, examples: Examples, options: RenderOptions) !void {
    if (options.json) {
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try output.writer.print("{{\"construct\":\"{s}\",\"examples\":[", .{examples.construct});
        for (examples.items, 0..) |item, i| {
            if (i > 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"repository\":\"{s}\",\"commit\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"start_offset\":{d},\"end_offset\":{d}}}", .{ item.repository_origin, item.commit_sha, item.file_path, item.line, item.column, item.start_offset, item.end_offset });
        }
        try output.writer.writeAll("]}\n");
        try writer.writeAll(output.written());
    } else if (options.markdown) {
        try writer.print("# Examples: `{s}`\n\nRepository | Pinned commit | File | Source range\n---|---|---|---\n", .{examples.construct});
        for (examples.items) |item| try writer.print("{s} | `{s}` | `{s}` | `{d}:{d} (offsets {d}..{d})\n", .{ item.repository_origin, item.commit_sha, item.file_path, item.line, item.column, item.start_offset, item.end_offset });
    } else {
        try writer.print("Examples for `{s}`\n", .{examples.construct});
        for (examples.items) |item| try writer.print("{s}@{s} {s}:{d}:{d} offsets={d}..{d}\n", .{ item.repository_origin, item.commit_sha, item.file_path, item.line, item.column, item.start_offset, item.end_offset });
        if (examples.items.len == 0) try writer.writeAll("No matching examples.\n");
    }
}

/// Render a comparison to the supplied writer.
pub fn renderComparison(allocator: std.mem.Allocator, writer: anytype, comparison: Comparison, options: RenderOptions) !void {
    if (options.json) {
        try renderComparisonJson(allocator, writer, comparison);
    } else if (options.markdown) {
        try renderComparisonMarkdown(writer, comparison);
    } else {
        try renderComparisonTerminal(writer, comparison);
    }
}

/// Render a topic report to the supplied writer.
pub fn renderTopic(allocator: std.mem.Allocator, writer: anytype, report: TopicReport, options: RenderOptions) !void {
    if (options.json) {
        try renderTopicJson(allocator, writer, report);
    } else if (options.markdown) {
        try renderTopicMarkdown(writer, report);
    } else {
        try renderTopicTerminal(writer, report);
    }
}

fn renderComparisonMarkdown(writer: anytype, comparison: Comparison) !void {
    try writer.print("# Construct comparison\n\n{s}\n\n", .{raw_syntax_note});
    if (comparison.statistics.len == 0) {
        try writer.writeAll("No constructs requested.\n");
        return;
    }
    const head = comparison.statistics[0];
    try writer.print("- Denominator: {d} observations\n- Filter: ", .{head.denominator});
    try renderFilter(writer, head.filters);
    try writer.writeAll("\n| Construct | Count | Frequency | Projects |\n|---|---:|---:|---:|\n");
    for (comparison.statistics) |stat| {
        var pct: [32]u8 = undefined;
        try writer.print("| `{s}` | {d} | {s} | {d} |\n", .{ stat.construct, stat.count, formatPercentage(&pct, stat.percentage), stat.projects.len });
    }
}

fn renderComparisonTerminal(writer: anytype, comparison: Comparison) !void {
    try writer.writeAll("Comparing: ");
    for (comparison.statistics, 0..) |stat, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(stat.construct);
    }
    try writer.writeByte('\n');
    try writer.writeAll(raw_syntax_note);
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

fn renderTopicMarkdown(writer: anytype, report: TopicReport) !void {
    try writer.print("# {s}\n\n{s}\n\n", .{ report.title, raw_syntax_note });
    if (report.statistics.len == 0) {
        try writer.writeAll("No constructs defined for this topic.\n");
        return;
    }
    const head = report.statistics[0];
    try writer.print("- Denominator: {d} observations\n- Filter: ", .{head.denominator});
    try renderFilter(writer, head.filters);
    try writer.writeAll("\n| Construct | Count | Frequency | Projects |\n|---|---:|---:|---:|\n");
    for (report.statistics) |stat| {
        var pct: [32]u8 = undefined;
        try writer.print("| `{s}` | {d} | {s} | {d} |\n", .{ stat.construct, stat.count, formatPercentage(&pct, stat.percentage), stat.projects.len });
    }
    if (report.incomplete) try writer.writeAll("\n> Warning: at least one matching analysis run is incomplete.\n");
}

fn renderTopicTerminal(writer: anytype, report: TopicReport) !void {
    try writer.print("{s}\n", .{report.title});
    for (0..report.title.len) |_| try writer.writeByte('=');
    try writer.writeByte('\n');
    try writer.writeAll(raw_syntax_note);
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
        .{ "ruby_version", filters.ruby_version },
        .{ "cohort", filters.cohort },
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
    try w.writeAll(",\"note\":\"");
    try writeJsonString(w, raw_syntax_note);
    try w.writeAll("\",\"statistics\":[");
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
    try w.writeAll(",\"note\":\"");
    try writeJsonString(w, raw_syntax_note);
    try w.writeAll("\",\"statistics\":[");
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
        .{ "ruby_version", filter.ruby_version },
        .{ "cohort", filter.cohort },
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

test "checked-in taxonomy has fifteen sections, aliases, and mappings" {
    var loaded = try taxonomy.load(std.testing.allocator, taxonomy_text, idioms_text);
    defer loaded.deinit();
    var sections: usize = 0;
    for (loaded.topics) |topic| {
        if (topic.parent == null) sections += 1;
    }
    try std.testing.expectEqual(@as(usize, 15), sections);
    try std.testing.expect(loaded.topic("loops-and-iteration") != null);
    try std.testing.expectEqualStrings("collections.transformation", loaded.topicForConstruct("map").?);
    try std.testing.expectEqualStrings("collections", loaded.topicForIdiom("map").?);
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

test "golden comparison terminal output covers empty dataset" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    var comparison = try compare(std.testing.allocator, &db, &.{"each"}, .{});
    defer comparison.deinit(std.testing.allocator);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try renderComparisonTerminal(&output.writer, comparison);

    const expected = "Comparing: each\n" ++
        raw_syntax_note ++ "\n" ++
        "Snapshot:    none\n" ++
        "Versions:    rgp=unknown prism=unknown classifier=unknown taxonomy=unknown\n" ++
        "Filter:      none\n" ++
        "Denominator: 0 observation(s)\n" ++
        "No completed observations match the current filters.\n";
    try std.testing.expectEqualStrings(expected, output.written());
}

test "golden comparison terminal output covers filtered dataset" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    const repo = try db.addRepository("project-f");
    const commit = try db.addCommit(repo, "sha-f");
    const prod = try db.addFileClassified(commit, "lib/a.rb", "hash", "production");
    const test_file = try db.addFileClassified(commit, "test/a_test.rb", "hash2", "test");
    const each = try db.addConstruct("each");
    _ = try db.persistCompleted(.{ .repository_id = repo, .commit_id = commit, .rgp_version = "r", .prism_version = "p", .classifier_version = "c", .taxonomy_version = "t" }, &.{
        .{ .repository_id = repo, .commit_id = commit, .file_id = prod, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = each },
        .{ .repository_id = repo, .commit_id = commit, .file_id = test_file, .start_offset = 0, .end_offset = 4, .line = 1, .column = 1, .node_kind = "PM_CALL_NODE", .raw_json = "{}", .construct_id = each },
    });

    var comparison = try compare(std.testing.allocator, &db, &.{"each"}, .{ .classification = "production" });
    defer comparison.deinit(std.testing.allocator);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try renderComparisonTerminal(&output.writer, comparison);

    const expected = "Comparing: each\n" ++
        raw_syntax_note ++ "\n" ++
        "Snapshot:    none\n" ++
        "Versions:    rgp=r prism=p classifier=c taxonomy=t\n" ++
        "Filter:      classification=production\n" ++
        "Denominator: 1 observation(s)\n" ++
        "\n" ++
        "construct    count    percent    projects\n" ++
        "-------------------------------------------\n" ++
        "each         1        100.0%     1\n";
    try std.testing.expectEqualStrings(expected, output.written());
}

test "golden report terminal output covers empty dataset" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    var report = try reportTopic(std.testing.allocator, &db, "conditionals", .{});
    defer report.deinit(std.testing.allocator);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try renderTopicTerminal(&output.writer, report);

    const expected = "Conditionals\n" ++
        "============\n" ++
        raw_syntax_note ++ "\n" ++
        "Snapshot:    none\n" ++
        "Versions:    rgp=unknown prism=unknown classifier=unknown taxonomy=unknown\n" ++
        "Filter:      none\n" ++
        "Denominator: 0 observation(s)\n" ++
        "No completed observations match the current filters.\n";
    try std.testing.expectEqualStrings(expected, output.written());
}

test "golden comparison json output covers empty dataset" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    var comparison = try compare(std.testing.allocator, &db, &.{"each"}, .{});
    defer comparison.deinit(std.testing.allocator);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try renderComparisonJson(std.testing.allocator, &output.writer, comparison);

    const expected =
        "{\"filter\":{},\"incomplete\":false,\"note\":\"" ++ raw_syntax_note ++
        "\",\"statistics\":[{\"construct\":\"each\",\"snapshot_id\":null," ++
        "\"rgp_version\":\"unknown\",\"prism_version\":\"unknown\"," ++
        "\"classifier_version\":\"unknown\",\"taxonomy_version\":\"unknown\"," ++
        "\"denominator\":0,\"count\":0,\"percentage\":null,\"projects\":[]}]}\n";
    try std.testing.expectEqualStrings(expected, output.written());
}

test "golden report json output covers empty dataset" {
    var db = try storage.Database.open(std.testing.allocator, ":memory:");
    defer db.deinit();

    var report = try reportTopic(std.testing.allocator, &db, "conditionals", .{});
    defer report.deinit(std.testing.allocator);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try renderTopicJson(std.testing.allocator, &output.writer, report);

    const expected =
        "{\"topic\":\"conditionals\",\"title\":\"Conditionals\",\"filter\":{}," ++
        "\"incomplete\":false,\"note\":\"" ++ raw_syntax_note ++
        "\",\"statistics\":[" ++
        "{\"construct\":\"if\",\"snapshot_id\":null,\"rgp_version\":\"unknown\",\"prism_version\":\"unknown\"," ++
        "\"classifier_version\":\"unknown\",\"taxonomy_version\":\"unknown\",\"denominator\":0,\"count\":0,\"percentage\":null,\"projects\":[]}," ++
        "{\"construct\":\"unless\",\"snapshot_id\":null,\"rgp_version\":\"unknown\",\"prism_version\":\"unknown\"," ++
        "\"classifier_version\":\"unknown\",\"taxonomy_version\":\"unknown\",\"denominator\":0,\"count\":0,\"percentage\":null,\"projects\":[]}," ++
        "{\"construct\":\"case\",\"snapshot_id\":null,\"rgp_version\":\"unknown\",\"prism_version\":\"unknown\"," ++
        "\"classifier_version\":\"unknown\",\"taxonomy_version\":\"unknown\",\"denominator\":0,\"count\":0,\"percentage\":null,\"projects\":[]}]}\n";
    try std.testing.expectEqualStrings(expected, output.written());
}


pub fn renderSnapshotComparison(writer: anytype, comparison: SnapshotComparison, json: bool) !void {
    if (json) {
        try writer.print("{{\"from_snapshot\":{d},\"to_snapshot\":{d},\"changes\":[", .{ comparison.from_snapshot, comparison.to_snapshot });
        for (comparison.changes, 0..) |change, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"construct\":\"{s}\",\"absolute_change\":{d},\"normalized_change\":", .{ change.construct, change.absolute_change });
            if (change.normalized_change) |value| try writer.print("{d:.6}", .{value}) else try writer.writeAll("null");
            try writer.writeAll("}");
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.print("Historical comparison: snapshot {d} -> {d}\n", .{ comparison.from_snapshot, comparison.to_snapshot });
        for (comparison.changes) |change| {
            if (change.normalized_change) |value| try writer.print("{s}: absolute {d}, normalized {d:.2} percentage points\n", .{ change.construct, change.absolute_change, value }) else try writer.print("{s}: absolute {d}, normalized unavailable\n", .{ change.construct, change.absolute_change });
        }
        try writer.writeAll("Cohort composition (observations/projects):\n");
        for (comparison.cohorts) |cohort| try writer.print("{s}: {d}/{d} -> {d}/{d}\n", .{ cohort.cohort, cohort.from_observations, cohort.from_projects, cohort.to_observations, cohort.to_projects });
    }
}
