//! Deterministic, offline Ruby source discovery and repository provenance.
const std = @import("std");
const Io = std.Io;

pub const Classification = enum { production, @"test", spec, benchmark, example, fixture, generated, vendor };
pub const Framework = enum { rails, hanami, sinatra, rake, rspec };
pub const File = struct { path: []u8, classification: Classification };
pub const Metadata = struct {
    commit_sha: ?[]u8 = null,
    ruby_version: ?[]u8 = null,
    framework: ?Framework = null,
    fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        if (self.commit_sha) |v| allocator.free(v);
        if (self.ruby_version) |v| allocator.free(v);
        self.* = .{};
    }
};
pub const Result = struct {
    files: []File,
    metadata: Metadata,
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.files) |file| allocator.free(file.path);
        allocator.free(self.files);
        self.metadata.deinit(allocator);
        self.* = undefined;
    }
};
pub const Options = struct { exclude: []const []const u8 = &.{} };

/// Recursively finds regular `.rb` files. Symlinks are never traversed or
/// reported; returned paths are repository-relative and sorted.
pub fn discover(io: Io, allocator: std.mem.Allocator, path: []const u8, options: Options) !Result {
    var root = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    return discoverDir(io, allocator, root, options);
}
pub fn discoverDir(io: Io, allocator: std.mem.Allocator, root: Io.Dir, options: Options) !Result {
    var files: std.ArrayList(File) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file.path);
        files.deinit(allocator);
    }
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.path, ".git/") or std.mem.eql(u8, entry.path, ".git")) {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        if (entry.kind == .directory) {
            if (excluded(entry.path, options.exclude)) walker.leave(io);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".rb") or excluded(entry.path, options.exclude)) continue;
        try files.append(allocator, .{ .path = try allocator.dupe(u8, entry.path), .classification = classify(entry.path) });
    }
    std.sort.heap(File, files.items, {}, struct {
        fn lessThan(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return .{ .files = try files.toOwnedSlice(allocator), .metadata = try inferMetadata(io, allocator, root) };
}
pub fn classify(path: []const u8) Classification {
    if (component(path, "vendor") or component(path, "third_party")) return .vendor;
    if (component(path, "fixture") or component(path, "fixtures")) return .fixture;
    if (component(path, "generated") or component(path, "generated_code") or std.mem.endsWith(u8, path, ".generated.rb")) return .generated;
    if (component(path, "benchmark") or component(path, "bench") or component(path, "benchmarks")) return .benchmark;
    if (component(path, "spec") or std.mem.endsWith(u8, path, "_spec.rb")) return .spec;
    if (component(path, "test") or component(path, "tests") or std.mem.endsWith(u8, path, "_test.rb")) return .@"test";
    if (component(path, "example") or component(path, "examples") or component(path, "sample")) return .example;
    return .production;
}
fn component(path: []const u8, wanted: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, wanted)) return true;
    return false;
}
fn excluded(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| if (glob(pattern, path)) return true;
    return false;
}
/// `*` and `?` do not cross separators; `**` does.
fn glob(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    if (pattern[0] == '*') {
        if (pattern.len > 1 and pattern[1] == '*') {
            var i: usize = 0;
            while (i <= path.len) : (i += 1) if (glob(pattern[2..], path[i..])) return true;
            return false;
        }
        var i: usize = 0;
        while (true) {
            if (glob(pattern[1..], path[i..])) return true;
            if (i == path.len or path[i] == '/') return false;
            i += 1;
        }
    }
    if (path.len == 0) return false;
    if (pattern[0] == '?') return path[0] != '/' and glob(pattern[1..], path[1..]);
    return pattern[0] == path[0] and glob(pattern[1..], path[1..]);
}
fn inferMetadata(io: Io, allocator: std.mem.Allocator, root: Io.Dir) !Metadata {
    var result = Metadata{};
    errdefer result.deinit(allocator);
    result.commit_sha = try gitSha(io, allocator, root);
    result.ruby_version = try rubyVersion(io, allocator, root);
    result.framework = try framework(io, allocator, root);
    return result;
}
fn readOptional(io: Io, allocator: std.mem.Allocator, root: Io.Dir, path: []const u8) !?[]u8 {
    return root.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
}
fn gitSha(io: Io, allocator: std.mem.Allocator, root: Io.Dir) !?[]u8 {
    const head = (try readOptional(io, allocator, root, ".git/HEAD")) orelse return null;
    defer allocator.free(head);
    const value = std.mem.trim(u8, head, " \t\r\n");
    if (sha(value)) return allocator.dupe(u8, value);
    const prefix = "ref: ";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const ref = value[prefix.len..];
    if (std.mem.indexOfScalar(u8, ref, '\\') != null or std.mem.startsWith(u8, ref, "/")) return null;
    const ref_path = try std.fmt.allocPrint(allocator, ".git/{s}", .{ref});
    defer allocator.free(ref_path);
    if (try readOptional(io, allocator, root, ref_path)) |contents| {
        defer allocator.free(contents);
        const ref_value = std.mem.trim(u8, contents, " \t\r\n");
        if (sha(ref_value)) return allocator.dupe(u8, ref_value);
    }
    // Repositories commonly pack refs after maintenance; resolving this local
    // file keeps SHA capture offline and independent of the Git executable.
    const packed_refs = (try readOptional(io, allocator, root, ".git/packed-refs")) orelse return null;
    defer allocator.free(packed_refs);
    var lines = std.mem.splitScalar(u8, packed_refs, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const candidate = fields.next() orelse continue;
        const candidate_ref = fields.next() orelse continue;
        if (std.mem.eql(u8, candidate_ref, ref) and sha(candidate)) return allocator.dupe(u8, candidate);
    }
    return null;
}
fn sha(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}
fn rubyVersion(io: Io, allocator: std.mem.Allocator, root: Io.Dir) !?[]u8 {
    const contents = (try readOptional(io, allocator, root, ".ruby-version")) orelse return null;
    defer allocator.free(contents);
    const version = std.mem.trim(u8, contents, " \t\r\n");
    return if (looksRubyVersion(version)) allocator.dupe(u8, version) else null;
}
fn looksRubyVersion(version: []const u8) bool {
    if (version.len < 3 or version[0] < '0' or version[0] > '9') return false;
    var dots: usize = 0;
    for (version) |byte| switch (byte) {
        '0'...'9' => {},
        '.' => dots += 1,
        else => return false,
    };
    return dots >= 1;
}
fn framework(io: Io, allocator: std.mem.Allocator, root: Io.Dir) !?Framework {
    const gemfile = (try readOptional(io, allocator, root, "Gemfile")) orelse return null;
    defer allocator.free(gemfile);
    if (std.mem.indexOf(u8, gemfile, "gem 'rails'") != null or std.mem.indexOf(u8, gemfile, "gem \"rails\"") != null) return .rails;
    if (std.mem.indexOf(u8, gemfile, "gem 'hanami'") != null or std.mem.indexOf(u8, gemfile, "gem \"hanami\"") != null) return .hanami;
    if (std.mem.indexOf(u8, gemfile, "gem 'sinatra'") != null or std.mem.indexOf(u8, gemfile, "gem \"sinatra\"") != null) return .sinatra;
    if (std.mem.indexOf(u8, gemfile, "gem 'rspec'") != null or std.mem.indexOf(u8, gemfile, "gem \"rspec\"") != null) return .rspec;
    return null;
}

test "classifies every corpus file category" {
    try std.testing.expectEqual(.production, classify("lib/app.rb"));
    try std.testing.expectEqual(.@"test", classify("test/app_test.rb"));
    try std.testing.expectEqual(.spec, classify("spec/app_spec.rb"));
    try std.testing.expectEqual(.benchmark, classify("benchmark/app.rb"));
    try std.testing.expectEqual(.example, classify("examples/app.rb"));
    try std.testing.expectEqual(.fixture, classify("test/fixtures/app.rb"));
    try std.testing.expectEqual(.generated, classify("generated/app.rb"));
    try std.testing.expectEqual(.vendor, classify("vendor/gem/app.rb"));
}

test "discovery excludes configured paths and symlinks but retains malformed Ruby" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib");
    try tmp.dir.createDirPath(std.testing.io, "ignored");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/good.rb", .data = "puts :ok\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/broken.rb", .data = "def missing(\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignored/nope.rb", .data = "puts :nope\n" });
    try std.posix.symlink("lib/good.rb", tmp.dir.handle, "linked.rb");
    var result = try discoverDir(std.testing.io, std.testing.allocator, tmp.dir, .{ .exclude = &.{"ignored/**"} });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqualStrings("lib/broken.rb", result.files[0].path);
    try std.testing.expectEqualStrings("lib/good.rb", result.files[1].path);
}

test "metadata captures local provenance and retains unknown facts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git/refs/heads");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git/refs/heads/main", .data = "0123456789abcdef0123456789abcdef01234567\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".ruby-version", .data = "3.3.1\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Gemfile", .data = "gem 'rails'\n" });
    var result = try discoverDir(std.testing.io, std.testing.allocator, tmp.dir, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", result.metadata.commit_sha.?);
    try std.testing.expectEqualStrings("3.3.1", result.metadata.ruby_version.?);
    try std.testing.expectEqual(Framework.rails, result.metadata.framework.?);
    var bare = std.testing.tmpDir(.{ .iterate = true });
    defer bare.cleanup();
    var unknown = try discoverDir(std.testing.io, std.testing.allocator, bare.dir, .{});
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expect(unknown.metadata.commit_sha == null and unknown.metadata.ruby_version == null and unknown.metadata.framework == null);
    try bare.dir.writeFile(std.testing.io, .{ .sub_path = ".ruby-version", .data = "not-a-ruby-version\n" });
    var invalid = try discoverDir(std.testing.io, std.testing.allocator, bare.dir, .{});
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expect(invalid.metadata.ruby_version == null);
}
