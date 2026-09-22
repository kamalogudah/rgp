//! Provider-neutral coding-agent contract. RGP core owns these types; adapters
//! own process/protocol conversion and external lifecycle details.
const std = @import("std");

pub const SessionId = u64;
pub const AdapterError = error{ UnsupportedCapability, SessionNotFound, Cancelled, NotConfigured, InvalidRequest, FxNotFound, FxNotAuthenticated, ProtocolError, ProcessExited };
pub const Capability = enum(u8) { chat, streaming, tool_calling, sessions, resume_session, file_read, file_write, shell, permissions, subagents, skills, mcp, acp, context_compaction, local_models };

pub const Capabilities = struct {
    bits: u32 = 0,
    pub fn with(values: []const Capability) Capabilities {
        var result = Capabilities{};
        for (values) |value| result.bits |= @as(u32, 1) << @as(u5, @intCast(@intFromEnum(value)));
        return result;
    }
    pub fn supports(self: Capabilities, capability: Capability) bool {
        return (self.bits & (@as(u32, 1) << @as(u5, @intCast(@intFromEnum(capability))))) != 0;
    }
};

pub const SessionConfig = struct { learner_id: ?[]const u8 = null, topic: ?[]const u8 = null, model: ?[]const u8 = null, cwd: ?[]const u8 = null };
pub const AgentRequest = struct { text: []const u8, session_id: ?SessionId = null, require: ?Capability = null };
pub const Response = struct { text: []const u8, session_id: SessionId, complete: bool = true };
pub const StreamEvent = union(enum) { text: []const u8, tool_update: struct { name: []const u8, status: []const u8 }, completed: Response, cancelled, error_message: []const u8 };
pub const StreamSink = *const fn (*anyopaque, StreamEvent) anyerror!void;

pub const CodingAgent = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        startSession: *const fn (*anyopaque, SessionConfig) anyerror!SessionId,
        send: *const fn (*anyopaque, SessionId, AgentRequest) anyerror!Response,
        stream: *const fn (*anyopaque, SessionId, AgentRequest, StreamSink, *anyopaque) anyerror!void,
        cancel: *const fn (*anyopaque, SessionId) anyerror!void,
        capabilities: *const fn (*anyopaque) Capabilities,
        shutdown: *const fn (*anyopaque) void,
    };
    pub fn startSession(self: CodingAgent, config: SessionConfig) !SessionId {
        return self.vtable.startSession(self.ptr, config);
    }
    pub fn send(self: CodingAgent, session: SessionId, request: AgentRequest) !Response {
        if (request.require) |required| if (!self.capabilities().supports(required)) return AdapterError.UnsupportedCapability;
        return self.vtable.send(self.ptr, session, request);
    }
    pub fn stream(self: CodingAgent, session: SessionId, request: AgentRequest, sink: StreamSink, context: *anyopaque) !void {
        if (!self.capabilities().supports(.streaming)) return AdapterError.UnsupportedCapability;
        return self.vtable.stream(self.ptr, session, request, sink, context);
    }
    pub fn cancel(self: CodingAgent, session: SessionId) !void {
        return self.vtable.cancel(self.ptr, session);
    }
    pub fn capabilities(self: CodingAgent) Capabilities {
        return self.vtable.capabilities(self.ptr);
    }
    pub fn shutdown(self: CodingAgent) void {
        self.vtable.shutdown(self.ptr);
    }
};

test "fake adapter contract covers capabilities, unsupported features, streaming, and cancellation" {
    const Fake = struct {
        next: SessionId = 0,
        cancelled: bool = false,
        active: bool = false,
        fn start(ptr: *anyopaque, _: SessionConfig) anyerror!SessionId {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.next += 1;
            self.active = true;
            return self.next;
        }
        fn send(ptr: *anyopaque, session: SessionId, request: AgentRequest) anyerror!Response {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.active or session == 0) return AdapterError.SessionNotFound;
            return .{ .text = request.text, .session_id = session };
        }
        fn stream(ptr: *anyopaque, session: SessionId, request: AgentRequest, sink: StreamSink, context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (session == 0) return AdapterError.SessionNotFound;
            try sink(context, .{ .text = request.text });
            try sink(context, .{ .completed = .{ .text = "done", .session_id = session } });
            self.cancelled = false;
        }
        fn cancel(ptr: *anyopaque, session: SessionId) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (session == 0 or !self.active) return AdapterError.SessionNotFound;
            self.cancelled = true;
        }
        fn caps(_: *anyopaque) Capabilities {
            return Capabilities.with(&.{ .chat, .streaming, .sessions });
        }
        fn shutdown(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.active = false;
        }
    };
    var fake = Fake{};
    const vtable = CodingAgent.VTable{ .startSession = Fake.start, .send = Fake.send, .stream = Fake.stream, .cancel = Fake.cancel, .capabilities = Fake.caps, .shutdown = Fake.shutdown };
    const agent = CodingAgent{ .ptr = &fake, .vtable = &vtable };
    const session = try agent.startSession(.{});
    const response = try agent.send(session, .{ .text = "hello", .require = .chat });
    try std.testing.expectEqualStrings("hello", response.text);
    try std.testing.expectError(AdapterError.UnsupportedCapability, agent.send(session, .{ .text = "write", .require = .file_write }));
    var chunks: usize = 0;
    const sink = struct {
        fn receive(ptr: *anyopaque, event: StreamEvent) anyerror!void {
            const count: *usize = @ptrCast(@alignCast(ptr));
            switch (event) {
                .text, .completed => count.* += 1,
                else => {},
            }
        }
    }.receive;
    try agent.stream(session, .{ .text = "stream" }, sink, &chunks);
    try std.testing.expectEqual(@as(usize, 2), chunks);
    try agent.cancel(session);
    try std.testing.expect(fake.cancelled);
    agent.shutdown();
    try std.testing.expectError(AdapterError.SessionNotFound, agent.send(session, .{ .text = "closed" }));
}
