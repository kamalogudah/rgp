//! Optional fx ACP adapter. fx and provider credentials remain external to RGP.
const std = @import("std");
const contract = @import("../../agent/contract.zig");

pub const ProviderKind = enum { inherited, hosted, openai_compatible, local };
pub const ProviderConfig = struct {
    kind: ProviderKind = .inherited,
    name: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    model: ?[]const u8 = null,
    auth_env: ?[]const u8 = null,
};
pub const Config = struct {
    command: []const u8 = "fx",
    provider: ProviderConfig = .{},
    cwd: ?[]const u8 = null,
};

pub const FxAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config = .{},
    child: ?std.process.Child = null,
    input: ?std.Io.File.Writer = null,
    output: ?std.Io.File.Reader = null,
    next_request: u64 = 1,
    next_session: contract.SessionId = 1,
    session: ?contract.SessionId = null,
    wire_session: ?[]u8 = null,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) FxAdapter {
        return .{ .allocator = allocator, .io = io, .config = config };
    }

    pub fn providerDescription(self: *const FxAdapter) []const u8 {
        return switch (self.config.provider.kind) {
            .inherited => "inherited fx provider credentials",
            .hosted => "hosted provider configured through fx",
            .openai_compatible => "OpenAI-compatible endpoint configured through fx",
            .local => "local provider configured through fx",
        };
    }

    pub fn agent(self: *FxAdapter) contract.CodingAgent {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn start(ptr: *anyopaque, config: contract.SessionConfig) anyerror!contract.SessionId {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.config.command.len == 0) return contract.AdapterError.NotConfigured;
        self.closeProcess();
        var argv = [_][]const u8{ self.config.command, "acp" };
        const cwd = config.cwd orelse self.config.cwd;
        self.child = if (cwd) |path|
            std.process.spawn(self.io, .{ .argv = &argv, .cwd = .{ .path = path }, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe })
        else
            std.process.spawn(self.io, .{ .argv = &argv, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
        self.child catch |err| return mapSpawnError(err);
        errdefer self.closeProcess();
        self.input = .init(self.child.?.stdin.?, self.io, &.{});
        self.output = .init(self.child.?.stdout.?, self.io, &.{});

        _ = try self.request("initialize", "{\"protocolVersion\":1,\"clientCapabilities\":{\"streaming\":true,\"toolCalls\":true},\"clientInfo\":{\"name\":\"rgp\",\"version\":\"0.1\"}}", null);
        var params = std.ArrayList(u8).empty;
        defer params.deinit(self.allocator);
        try params.writer(self.allocator).print("{{\"cwd\":\".\",\"model\":{f}}}", .{JsonString{ .value = config.model orelse self.config.provider.model orelse "" }});
        const response = try self.request("session/new", params.items, null);
        const wire = findString(response, "sessionId") orelse return contract.AdapterError.ProtocolError;
        self.wire_session = try self.allocator.dupe(u8, wire);
        self.session = self.next_session;
        self.next_session += 1;
        self.initialized = true;
        return self.session.?;
    }

    fn send(ptr: *anyopaque, session: contract.SessionId, req: contract.AgentRequest) anyerror!contract.Response {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var text = std.ArrayList(u8).empty;
        defer text.deinit(self.allocator);
        self.prompt(session, req.text, null, null, &text) catch |err| {
            self.closeProcess();
            return err;
        };
        return .{ .text = try text.toOwnedSlice(self.allocator), .session_id = session };
    }

    fn stream(ptr: *anyopaque, session: contract.SessionId, req: contract.AgentRequest, sink: contract.StreamSink, context: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.prompt(session, req.text, sink, context, null) catch |err| {
            self.closeProcess();
            return err;
        };
    }

    fn cancel(ptr: *anyopaque, session: contract.SessionId) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.session == null or self.session.? != session) return contract.AdapterError.SessionNotFound;
        var params = std.ArrayList(u8).empty;
        defer params.deinit(self.allocator);
        params.writer(self.allocator).print("{{\"sessionId\":{f}}}", .{JsonString{ .value = self.wire_session.? }}) catch return contract.AdapterError.ProtocolError;
        self.request("session/cancel", params.items, null) catch {
            self.closeProcess();
            return contract.AdapterError.Cancelled;
        };
    }

    fn capabilities(_: *anyopaque) contract.Capabilities {
        return contract.Capabilities.with(&.{ .chat, .streaming, .tool_calling, .sessions, .permissions, .acp });
    }

    fn shutdown(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.closeProcess();
    }

    const vtable = contract.CodingAgent.VTable{ .startSession = start, .send = send, .stream = stream, .cancel = cancel, .capabilities = capabilities, .shutdown = shutdown };

    const Target = struct { sink: ?contract.StreamSink, context: ?*anyopaque, session: contract.SessionId, collected: ?*std.ArrayList(u8) };
    const JsonString = struct {
        value: []const u8,
        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            try std.json.Stringify.value(self.value, .{}, writer);
        }
    };

    fn cancelParams(self: *@This()) []const u8 {
        _ = self;
        return "{}";
    }

    fn prompt(self: *@This(), session: contract.SessionId, text: []const u8, sink: ?contract.StreamSink, context: ?*anyopaque, collected: ?*std.ArrayList(u8)) !void {
        if (!self.initialized or self.session == null or self.session.? != session or self.wire_session == null) return contract.AdapterError.SessionNotFound;
        var params = std.ArrayList(u8).empty;
        defer params.deinit(self.allocator);
        try params.writer(self.allocator).print("{{\"sessionId\":{f},\"prompt\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{ JsonString{ .value = self.wire_session.? }, JsonString{ .value = text } });
        _ = try self.request("session/prompt", params.items, .{ .sink = sink, .context = context, .session = session, .collected = collected });
    }

    fn request(self: *@This(), method: []const u8, params: []const u8, target: ?Target) ![]const u8 {
        const id = self.next_request;
        self.next_request += 1;
        var line = std.ArrayList(u8).empty;
        defer line.deinit(self.allocator);
        try line.writer(self.allocator).print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}\n", .{ id, JsonString{ .value = method }, params });
        try self.input.?.interface.writeAll(line.items);
        try self.input.?.interface.flush();
        while (true) {
            const raw = self.output.?.interface.takeDelimiterExclusive('\n') catch return contract.AdapterError.ProcessExited;
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return contract.AdapterError.ProtocolError;
            defer parsed.deinit();
            if (parsed.value.object.get("method")) |value| {
                if (value == .string and std.mem.eql(u8, value.string, "session/update")) {
                    try self.emitUpdate(parsed.value, target);
                    continue;
                }
            }
            const response_id = parsed.value.object.get("id") orelse continue;
            if (response_id != .integer or response_id.integer != @as(i64, @intCast(id))) continue;
            if (parsed.value.object.get("error") != null) return normalizeError(parsed.value);
            if (target) |event| if (event.sink) |sink| {
                const result = parsed.value.object.get("result") orelse return contract.AdapterError.ProtocolError;
                const final_text = findStringValue(result, "text") orelse "";
                if (event.collected) |out| try out.appendSlice(self.allocator, final_text);
                try sink(event.context.?, .{ .completed = .{ .text = final_text, .session_id = event.session } });
            };
            return raw;
        }
    }

    fn emitUpdate(self: *@This(), value: std.json.Value, target: ?Target) !void {
        const event = target orelse return;
        const params = value.object.get("params") orelse return;
        const text = findStringValue(params, "text") orelse return;
        if (event.collected) |out| try out.appendSlice(self.allocator, text);
        if (event.sink) |sink| {
            if (std.mem.indexOf(u8, text, "tool") != null)
                try sink(event.context.?, .{ .tool_update = .{ .name = "fx", .status = text } })
            else
                try sink(event.context.?, .{ .text = text });
        }
    }

    fn closeProcess(self: *@This()) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
        self.input = null;
        self.output = null;
        if (self.wire_session) |id| self.allocator.free(id);
        self.wire_session = null;
        self.session = null;
        self.initialized = false;
    }
};

fn mapSpawnError(_: anyerror) contract.AdapterError {
    return contract.AdapterError.FxNotFound;
}
fn normalizeError(value: std.json.Value) contract.AdapterError {
    const message = findStringValue(value, "message") orelse "";
    if (std.mem.indexOf(u8, message, "auth") != null or std.mem.indexOf(u8, message, "credential") != null) return contract.AdapterError.FxNotAuthenticated;
    return contract.AdapterError.ProtocolError;
}
fn findString(value: []const u8, key: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, value, .{}) catch return null;
    defer parsed.deinit();
    return findStringValue(parsed.value, key);
}
fn findStringValue(value: std.json.Value, key: []const u8) ?[]const u8 {
    switch (value) {
        .object => |object| {
            if (object.get(key)) |found| if (found == .string) return found.string;
            var it = object.iterator();
            while (it.next()) |entry| if (findStringValue(entry.value_ptr.*, key)) |result| return result;
        },
        .array => |array| for (array.items) |item| if (findStringValue(item, key)) |result| return result,
        else => {},
    }
    return null;
}

test "fx adapter exposes normalized capabilities and actionable missing executable error" {
    var adapter = FxAdapter.init(std.testing.allocator, std.testing.io, .{ .command = "rgp-command-that-does-not-exist" });
    const agent = adapter.agent();
    try std.testing.expect(agent.capabilities().supports(.chat));
    try std.testing.expect(agent.capabilities().supports(.streaming));
    try std.testing.expectEqualStrings("inherited fx provider credentials", adapter.providerDescription());
    try std.testing.expectError(contract.AdapterError.FxNotFound, agent.startSession(.{}));
    agent.shutdown();
}
