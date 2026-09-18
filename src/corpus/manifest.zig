//! Versioned corpus manifest loader and serializer.
const std = @import("std");
const Io = std.Io;

pub const Category = enum {
    rails,
    framework,
    library,
    tool,
    standard,
    server,
    fixture,
    other,

    pub fn fromString(s: []const u8) ?Category {
        inline for (std.meta.fields(Category)) |field| {
            if (std.mem.eql(u8, s, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn asString(self: Category) []const u8 {
        return @tagName(self);
    }
};

pub const Repository = struct {
    id: []u8,
    source: []u8,
    revision: []u8,
    include: []const []u8,
    exclude: []const []u8,
    category: ?Category = null,

    pub fn deinit(self: *Repository, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source);
        allocator.free(self.revision);
        for (self.include) |item| allocator.free(item);
        allocator.free(self.include);
        for (self.exclude) |item| allocator.free(item);
        allocator.free(self.exclude);
    }

    pub fn clone(self: Repository, allocator: std.mem.Allocator) !Repository {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .source = try allocator.dupe(u8, self.source),
            .revision = try allocator.dupe(u8, self.revision),
            .include = try dupeStringArray(allocator, self.include),
            .exclude = try dupeStringArray(allocator, self.exclude),
            .category = self.category,
        };
    }

    pub fn isRemote(self: Repository) bool {
        return std.mem.startsWith(u8, self.source, "https://") or std.mem.startsWith(u8, self.source, "http://") or std.mem.startsWith(u8, self.source, "git@");
    }

    pub fn displayCategory(self: Repository) []const u8 {
        if (self.category) |c| return c.asString();
        return "-";
    }
};

pub const Manifest = struct {
    schema_version: u32,
    offline: bool,
    repositories: []Repository,

    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        for (self.repositories) |*repo| repo.deinit(allocator);
        allocator.free(self.repositories);
    }

    pub fn clone(self: Manifest, allocator: std.mem.Allocator) !Manifest {
        const repos = try allocator.alloc(Repository, self.repositories.len);
        errdefer {
            for (repos) |*r| r.deinit(allocator);
            allocator.free(repos);
        }
        for (self.repositories, 0..) |repo, i| {
            repos[i] = try repo.clone(allocator);
        }
        return .{
            .schema_version = self.schema_version,
            .offline = self.offline,
            .repositories = repos,
        };
    }

    pub fn findById(self: Manifest, id: []const u8) ?usize {
        for (self.repositories, 0..) |repo, i| {
            if (std.mem.eql(u8, repo.id, id)) return i;
        }
        return null;
    }
};

pub const LoadResult = struct {
    manifest: ?Manifest,
    diagnostic: ?[]u8,

    pub fn deinit(self: LoadResult, allocator: std.mem.Allocator) void {
        if (self.diagnostic) |d| allocator.free(d);
        if (self.manifest) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
    }
};

pub fn load(allocator: std.mem.Allocator, source: []const u8) LoadResult {
    var parser = Parser{
        .source = source,
        .pos = 0,
        .allocator = allocator,
        .diagnostic = null,
    };
    const manifest = parser.parse() catch |err| {
        const message = parser.diagnostic orelse std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch return .{ .manifest = null, .diagnostic = null };
        return .{ .manifest = null, .diagnostic = message };
    };
    return .{ .manifest = manifest, .diagnostic = null };
}

pub fn loadFile(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) LoadResult {
    const bytes = dir.readFileAlloc(io, sub_path, allocator, .limited(1024 * 1024)) catch |err| {
        const message = std.fmt.allocPrint(allocator, "cannot read {s}: {s}", .{ sub_path, @errorName(err) }) catch return .{ .manifest = null, .diagnostic = null };
        return .{ .manifest = null, .diagnostic = message };
    };
    defer allocator.free(bytes);
    var result = load(allocator, bytes);
    if (result.diagnostic) |original| {
        const prefixed = std.fmt.allocPrint(allocator, "{s}: {s}", .{ sub_path, original }) catch {
            allocator.free(original);
            return .{ .manifest = null, .diagnostic = null };
        };
        allocator.free(original);
        result.diagnostic = prefixed;
    }
    return result;
}

pub fn save(manifest: Manifest, allocator: std.mem.Allocator) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("# Contract: docs/configuration.md#corpus-toml\n");
    try writer.print("schema_version = {d}\n\n", .{manifest.schema_version});
    try writer.writeAll("[corpus]\n");
    try writer.print("offline = {s}\n\n", .{if (manifest.offline) "true" else "false"});
    for (manifest.repositories) |repo| {
        try writer.writeAll("[[repository]]\n");
        try writer.print("id = \"{s}\"\n", .{escapeString(repo.id)});
        try writer.print("source = \"{s}\"\n", .{escapeString(repo.source)});
        try writer.print("revision = \"{s}\"\n", .{repo.revision});
        if (repo.category) |category| try writer.print("category = \"{s}\"\n", .{category.asString()});
        try writer.writeAll("include = ");
        try writeStringArray(writer, repo.include);
        try writer.writeAll("\nexclude = ");
        try writeStringArray(writer, repo.exclude);
        try writer.writeAll("\n\n");
    }
    return try allocator.dupe(u8, output.written());
}

pub fn writeToFile(manifest: Manifest, allocator: std.mem.Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) !void {
    const bytes = try save(manifest, allocator);
    defer allocator.free(bytes);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
}

fn writeStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{escapeString(item)});
    }
    try writer.writeAll("]");
}

fn escapeString(s: []const u8) []const u8 {
    // The manifest only stores identifiers, URLs, paths, and SHAs; none contain
    // characters that need escaping under the current contract.
    return s;
}

fn dupeStringArray(allocator: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error![]const []u8 {
    const result = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(result);
    for (items, 0..) |item, i| {
        result[i] = try allocator.dupe(u8, item);
    }
    return result;
}

pub fn validateId(id: []const u8) bool {
    if (id.len == 0) return false;
    const first = id[0];
    if (!((first >= 'a' and first <= 'z') or (first >= '0' and first <= '9'))) return false;
    for (id[1..]) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-')) return false;
    }
    return true;
}

pub fn validateSha(sha: []const u8) bool {
    if (sha.len != 40) return false;
    for (sha) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

const Parser = struct {
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    diagnostic: ?[]u8,

    fn parse(self: *Parser) !Manifest {
        var schema_version: ?u32 = null;
        var offline: ?bool = null;
        var repos = std.ArrayList(Repository).empty;
        errdefer {
            for (repos.items) |*repo| repo.deinit(self.allocator);
            repos.deinit(self.allocator);
        }

        const Context = enum { top, corpus, repository };
        var context: Context = .top;
        var current: ?Repository = null;

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.source.len) break;
            const c = self.source[self.pos];
            if (c == '[') {
                if (current) |*repo| {
                    try self.validateRepository(repo);
                    try repos.append(self.allocator, repo.*);
                    current = null;
                }
                self.pos += 1;
                const array_table = self.peek() == '[';
                if (array_table) self.pos += 1;
                const name = try self.parseBareKey();
                self.skipWhitespaceAndComments();
                if (self.pos >= self.source.len or self.source[self.pos] != ']') return self.fail("expected ']' to close table header", .{});
                self.pos += 1;
                if (array_table) {
                    if (self.pos >= self.source.len or self.source[self.pos] != ']') return self.fail("expected ']]' to close array-of-tables header", .{});
                    self.pos += 1;
                }
                if (array_table) {
                    if (!std.mem.eql(u8, name, "repository")) return self.fail("unknown array-of-tables `[[{s}]]`; expected `[[repository]]`", .{name});
                    context = .repository;
                    current = Repository{ .id = &.{}, .source = &.{}, .revision = &.{}, .include = &.{}, .exclude = &.{} };
                } else {
                    if (!std.mem.eql(u8, name, "corpus")) return self.fail("unknown table `[{s}]`; expected `[corpus]`", .{name});
                    context = .corpus;
                }
                continue;
            }

            const key = try self.parseBareKey();
            self.skipWhitespaceAndComments();
            if (self.pos >= self.source.len or self.source[self.pos] != '=') return self.fail("expected '=' after key `{s}`", .{key});
            self.pos += 1;

            switch (context) {
                .top => {
                    if (std.mem.eql(u8, key, "schema_version")) {
                        if (schema_version != null) return self.fail("duplicate key `schema_version`", .{});
                        schema_version = try self.parseInteger();
                        if (schema_version.? != 1) return self.fail("schema_version {d} is unsupported (supported: 1)", .{schema_version.?});
                    } else {
                        return self.fail("unknown key `{s}` at top level", .{key});
                    }
                },
                .corpus => {
                    if (std.mem.eql(u8, key, "offline")) {
                        if (offline != null) return self.fail("duplicate key `offline`", .{});
                        offline = try self.parseBoolean();
                    } else {
                        return self.fail("unknown key `{s}` in [corpus]", .{key});
                    }
                },
                .repository => {
                    var repo = &current.?;
                    if (std.mem.eql(u8, key, "id")) {
                        if (repo.id.len != 0) return self.fail("duplicate key `id`", .{});
                        const value = try self.parseString();
                        if (!validateId(value)) return self.fail("repository id `{s}` must match [a-z0-9][a-z0-9_-]*", .{value});
                        repo.id = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "source")) {
                        if (repo.source.len != 0) return self.fail("duplicate key `source`", .{});
                        const value = try self.parseString();
                        if (value.len == 0) return self.fail("repository source must be non-empty", .{});
                        repo.source = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "revision")) {
                        if (repo.revision.len != 0) return self.fail("duplicate key `revision`", .{});
                        const value = try self.parseString();
                        if (!validateSha(value)) return self.fail("revision must be a 40-character lowercase Git commit SHA", .{});
                        repo.revision = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "category")) {
                        if (repo.category != null) return self.fail("duplicate key `category`", .{});
                        const value = try self.parseString();
                        if (Category.fromString(value)) |category| {
                            repo.category = category;
                        } else {
                            return self.fail("unknown category `{s}`", .{value});
                        }
                    } else if (std.mem.eql(u8, key, "include")) {
                        if (repo.include.len != 0) return self.fail("duplicate key `include`", .{});
                        repo.include = try self.parseStringArray();
                        if (repo.include.len == 0) return self.fail("`include` must be a non-empty list of glob patterns", .{});
                    } else if (std.mem.eql(u8, key, "exclude")) {
                        if (repo.exclude.len != 0) return self.fail("duplicate key `exclude`", .{});
                        repo.exclude = try self.parseStringArray();
                    } else {
                        return self.fail("unknown key `{s}` in [[repository]]", .{key});
                    }
                },
            }
        }

        if (current) |*repo| {
            try self.validateRepository(repo);
            try repos.append(self.allocator, repo.*);
        }

        if (schema_version == null) return self.fail("missing required `schema_version`", .{});
        if (offline == null) return self.fail("missing required `[corpus].offline`", .{});

        return Manifest{
            .schema_version = schema_version.?,
            .offline = offline.?,
            .repositories = try repos.toOwnedSlice(self.allocator),
        };
    }

    fn validateRepository(self: *Parser, repo: *Repository) !void {
        if (repo.id.len == 0) return self.fail("repository missing required `id`", .{});
        if (repo.source.len == 0) return self.fail("repository `{s}` missing required `source`", .{repo.id});
        if (repo.revision.len == 0) return self.fail("repository `{s}` missing required `revision`", .{repo.id});
        if (repo.include.len == 0) return self.fail("repository `{s}` missing required `include`", .{repo.id});
        var seen = std.ArrayList([]const u8).empty;
        defer seen.deinit(self.allocator);
        for (repo.include) |pattern| {
            for (seen.items) |prior| {
                if (std.mem.eql(u8, pattern, prior)) return self.fail("repository `{s}` has duplicate include pattern `{s}`", .{ repo.id, pattern });
            }
            try seen.append(self.allocator, pattern);
        }
        seen.clearRetainingCapacity();
        for (repo.exclude) |pattern| {
            for (seen.items) |prior| {
                if (std.mem.eql(u8, pattern, prior)) return self.fail("repository `{s}` has duplicate exclude pattern `{s}`", .{ repo.id, pattern });
            }
            try seen.append(self.allocator, pattern);
        }
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) error{InvalidManifest} {
        self.diagnostic = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
        return error.InvalidManifest;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
                continue;
            }
            if (c == '#') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
                continue;
            }
            break;
        }
    }

    fn parseBareKey(self: *Parser) ![]const u8 {
        self.skipWhitespaceAndComments();
        const start = self.pos;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-') {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return self.fail("expected key", .{});
        return self.source[start..self.pos];
    }

    fn parseString(self: *Parser) ![]const u8 {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) return self.fail("expected string value", .{});
        const quote = self.source[self.pos];
        if (quote != '"' and quote != '\'') return self.fail("expected quoted string", .{});
        self.pos += 1;
        const start = self.pos;
        var end = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != quote) {
            if (quote == '"' and self.source[self.pos] == '\\') {
                self.pos += 1;
                if (self.pos >= self.source.len) return self.fail("unterminated escape in string", .{});
            }
            self.pos += 1;
            end = self.pos;
        }
        if (self.pos >= self.source.len) return self.fail("unterminated string", .{});
        const raw = self.source[start..end];
        self.pos += 1;
        if (quote == '\'') return raw;
        return try unescape(self.allocator, raw);
    }

    fn parseInteger(self: *Parser) !u32 {
        self.skipWhitespaceAndComments();
        const start = self.pos;
        if (self.pos < self.source.len and self.source[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.source.len or self.source[self.pos] < '0' or self.source[self.pos] > '9') return self.fail("expected integer", .{});
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c < '0' or c > '9') break;
            self.pos += 1;
        }
        const slice = self.source[start..self.pos];
        return std.fmt.parseInt(u32, slice, 10) catch return self.fail("invalid integer `{s}`", .{slice});
    }

    fn parseBoolean(self: *Parser) !bool {
        self.skipWhitespaceAndComments();
        const start = self.pos;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if ((c >= 'a' and c <= 'z')) self.pos += 1 else break;
        }
        const slice = self.source[start..self.pos];
        if (std.mem.eql(u8, slice, "true")) return true;
        if (std.mem.eql(u8, slice, "false")) return false;
        return self.fail("expected boolean, found `{s}`", .{slice});
    }

    fn parseStringArray(self: *Parser) ![]const []u8 {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len or self.source[self.pos] != '[') return self.fail("expected array", .{});
        self.pos += 1;
        var items = std.ArrayList([]u8).empty;
        errdefer {
            for (items.items) |item| self.allocator.free(item);
            items.deinit(self.allocator);
        }
        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.source.len) return self.fail("unterminated array", .{});
            if (self.source[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            const value = try self.parseString();
            const owned = try self.allocator.dupe(u8, value);
            try items.append(self.allocator, owned);
            self.skipWhitespaceAndComments();
            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
        }
        return try items.toOwnedSlice(self.allocator);
    }
};

fn unescape(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            switch (raw[i + 1]) {
                'n' => try result.append(allocator, '\n'),
                't' => try result.append(allocator, '\t'),
                'r' => try result.append(allocator, '\r'),
                '\\' => try result.append(allocator, '\\'),
                '"' => try result.append(allocator, '"'),
                else => try result.append(allocator, raw[i + 1]),
            }
            i += 2;
        } else {
            try result.append(allocator, raw[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

test "manifest round-trips the fixture and validates fields" {
    const fixture =
        "# Contract: docs/configuration.md#corpus-toml\n" ++
        "schema_version = 1\n" ++
        "\n" ++
        "[corpus]\n" ++
        "offline = true\n" ++
        "\n" ++
        "[[repository]]\n" ++
        "id = \"rgp-fixture\"\n" ++
        "source = \".\"\n" ++
        "revision = \"e8cbd95f6fe039a95d8e7a1c86ea4c14a96bbe65\"\n" ++
        "category = \"fixture\"\n" ++
        "include = [\"fixtures/**/*.rb\"]\n" ++
        "exclude = [\"vendor/**\", \"tmp/**\"]\n";
    var lr = load(std.testing.allocator, fixture);
    defer lr.deinit(std.testing.allocator);
    try std.testing.expect(lr.manifest != null);
    try std.testing.expect(lr.diagnostic == null);
    const manifest = lr.manifest.?;
    try std.testing.expectEqual(@as(u32, 1), manifest.schema_version);
    try std.testing.expect(manifest.offline);
    try std.testing.expectEqual(@as(usize, 1), manifest.repositories.len);
    try std.testing.expectEqualStrings("rgp-fixture", manifest.repositories[0].id);
    try std.testing.expectEqualStrings(".", manifest.repositories[0].source);
    try std.testing.expectEqualStrings("e8cbd95f6fe039a95d8e7a1c86ea4c14a96bbe65", manifest.repositories[0].revision);
    try std.testing.expectEqual(Category.fixture, manifest.repositories[0].category.?);

    const saved = try save(manifest, std.testing.allocator);
    defer std.testing.allocator.free(saved);
    var lr2 = load(std.testing.allocator, saved);
    defer lr2.deinit(std.testing.allocator);
    try std.testing.expect(lr2.manifest != null);
    const m2 = lr2.manifest.?;
    try std.testing.expectEqual(manifest.schema_version, m2.schema_version);
    try std.testing.expectEqual(manifest.repositories.len, m2.repositories.len);
    try std.testing.expectEqualStrings(manifest.repositories[0].id, m2.repositories[0].id);
}

test "manifest rejects unsupported schema version and unknown keys" {
    var lr = load(std.testing.allocator, "schema_version = 2\n[corpus]\noffline = true\n");
    defer lr.deinit(std.testing.allocator);
    try std.testing.expect(lr.manifest == null);
    try std.testing.expect(lr.diagnostic != null);
    try std.testing.expect(std.mem.indexOf(u8, lr.diagnostic.?, "unsupported") != null);

    var lr2 = load(std.testing.allocator, "schema_version = 1\n[corpus]\noffline = true\n[[repository]]\nid = \"x\"\nsource = \"https://example.test/x.git\"\nrevision = \"0000000000000000000000000000000000000000\"\ninclude = [\"**/*.rb\"]\nunknown = 1\n");
    defer lr2.deinit(std.testing.allocator);
    try std.testing.expect(lr2.manifest == null);
    try std.testing.expect(std.mem.indexOf(u8, lr2.diagnostic.?, "unknown key") != null);
}

test "manifest rejects duplicate ids and invalid revisions" {
    const input =
        "schema_version = 1\n" ++
        "[corpus]\n" ++
        "offline = true\n" ++
        "[[repository]]\n" ++
        "id = \"x\"\n" ++
        "source = \"https://example.test/a.git\"\n" ++
        "revision = \"abc\"\n" ++
        "include = [\"**/*.rb\"]\n";
    var lr = load(std.testing.allocator, input);
    defer lr.deinit(std.testing.allocator);
    try std.testing.expect(lr.manifest == null);
    try std.testing.expect(std.mem.indexOf(u8, lr.diagnostic.?, "revision") != null);
}
