//! Offline source explanations with deterministic AST/idiom citations.
const std = @import("std");
const Io = std.Io;
const prism = @import("../prism/parser.zig");
const observation = @import("../analysis/observation.zig");
const idioms = @import("../analysis/idioms.zig");
const explanation = @import("../explain.zig");
const registry_mod = @import("../agent/registry.zig");

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8, writer: *Io.Writer) !u8 {
    var profile: explanation.Profile = .beginner;
    var agent: ?[]const u8 = null;
    var spec: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--level") or std.mem.eql(u8, args[i], "--profile")) {
            if (i + 1 >= args.len) return usage(writer);
            profile = parseProfile(args[i + 1]) orelse { try writer.print("error: unknown learner profile `{s}`; use beginner, intermediate, or senior.\n", .{args[i + 1]}); return 2; };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--agent")) {
            if (i + 1 >= args.len) return usage(writer);
            agent = args[i + 1]; i += 1;
        } else if (std.mem.startsWith(u8, args[i], "-")) return usage(writer) else if (spec == null) spec = args[i] else return usage(writer);
    }
    const requested = spec orelse return usage(writer);
    const parsed = parseSpec(requested) catch |err| { try writer.print("error: invalid source range `{s}`: {s}; use file.rb or file.rb:20-35.\n", .{ requested, @errorName(err) }); return 2; };
    const source = Io.Dir.cwd().readFileAlloc(io, parsed.path, allocator, .limited(10 * 1024 * 1024)) catch |err| { try writer.print("error: cannot read `{s}`: {s}\n", .{ parsed.path, @errorName(err) }); return 1; }; defer allocator.free(source);
    const lines = lineCount(source);
    const last_line = if (parsed.last_line == std.math.maxInt(usize)) lines else parsed.last_line;
    if (parsed.first_line == 0 or last_line < parsed.first_line or last_line > lines) { try writer.print("error: invalid source range `{s}`; file has {d} lines.\n", .{ requested, lines }); return 2; }
    var document = prism.parse(allocator, source, .{ .path = parsed.path }) catch |err| { try writer.print("error: cannot parse `{s}`: {s}\n", .{ parsed.path, @errorName(err) }); return 1; }; defer document.deinit();
    if (!document.success()) { try writer.print("error: parse errors in `{s}`:\n", .{parsed.path}); for (document.diagnostics()) |diagnostic| if (diagnostic.severity == .syntax_error) try writer.print("  {s}:{d}:{d}: {s}\n", .{ parsed.path, diagnostic.location.line, diagnostic.location.column, diagnostic.message }); return 1; }
    const observations = try observation.extract(allocator, &document); defer allocator.free(observations);
    const matches = try idioms.detectSource(allocator, source, observations); defer allocator.free(matches);
    const found = try explanation.facts(allocator, source, observations, matches, parsed.first_line, last_line); defer allocator.free(found);
    try writer.print("Explanation ({s}) for {s}:{d}-{d}\n", .{ explanation.profileName(profile), parsed.path, parsed.first_line, last_line });
    if (agent) |name| { var registry = registry_mod.Registry{}; registry.use(name) catch { try writer.print("agent `{s}` is unavailable; showing deterministic offline explanation.\n", .{name}); return render(writer, profile, parsed.path, found); }; if (!registry.info().available) try writer.print("agent `{s}` is unavailable; showing deterministic offline explanation.\n", .{name}); }
    return render(writer, profile, parsed.path, found);
}
fn render(writer: *Io.Writer, profile: explanation.Profile, path: []const u8, found: []const explanation.Fact) !u8 { if (found.len == 0) { try writer.writeAll("No recognized deterministic idiom facts in this range; semantic intent is unknown.\n"); return 0; } for (found) |fact| try writer.print("- {s} [{s}:{d}-{d}]\n", .{ explanation.label(profile, fact), path, fact.line, fact.end_line }); if (profile == .senior) try writer.writeAll("Facts are AST/idiom observations; runtime behavior and unobserved intent are not inferred.\n"); return 0; }
const Range = struct { path: []const u8, first_line: usize = 1, last_line: usize = std.math.maxInt(usize) };
fn parseSpec(spec: []const u8) !Range { const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return .{ .path = spec, .last_line = std.math.maxInt(usize) }; if (colon == 0 or colon + 1 >= spec.len) return error.missing_range; const range = spec[colon + 1 ..]; const dash = std.mem.indexOfScalar(u8, range, '-') orelse return error.missing_end; if (dash == 0 or dash + 1 >= range.len) return error.invalid_bounds; return .{ .path = spec[0..colon], .first_line = try std.fmt.parseInt(usize, range[0..dash], 10), .last_line = try std.fmt.parseInt(usize, range[dash + 1 ..], 10) }; }
fn parseProfile(value: []const u8) ?explanation.Profile { if (std.mem.eql(u8, value, "beginner")) return .beginner; if (std.mem.eql(u8, value, "intermediate")) return .intermediate; if (std.mem.eql(u8, value, "senior")) return .senior; return null; }
fn lineCount(source: []const u8) usize { return std.mem.count(u8, source, "\n") + @as(usize, if (source.len == 0 or source[source.len - 1] != '\n') 1 else 0); }
fn usage(writer: *Io.Writer) !u8 { try writer.writeAll("Explain usage:\n  rgp explain [--level beginner|intermediate|senior] file.rb[:start-end]\n"); return 2; }
