//! fx boundary placeholder. It is deliberately optional: the deterministic
//! RGP core remains usable when fx is not installed.
const contract = @import("../../agent/contract.zig");

pub const FxAdapter = struct {
    pub fn agent(self: *FxAdapter) contract.CodingAgent {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn start(_: *anyopaque, _: contract.SessionConfig) anyerror!contract.SessionId {
        return contract.AdapterError.NotConfigured;
    }
    fn send(_: *anyopaque, _: contract.SessionId, _: contract.AgentRequest) anyerror!contract.Response {
        return contract.AdapterError.NotConfigured;
    }
    fn stream(_: *anyopaque, _: contract.SessionId, _: contract.AgentRequest, _: contract.StreamSink, _: *anyopaque) anyerror!void {
        return contract.AdapterError.NotConfigured;
    }
    fn cancel(_: *anyopaque, _: contract.SessionId) anyerror!void {
        return contract.AdapterError.NotConfigured;
    }
    fn capabilities(_: *anyopaque) contract.Capabilities {
        return .{};
    }
    fn shutdown(_: *anyopaque) void {}
    const vtable = contract.CodingAgent.VTable{ .startSession = start, .send = send, .stream = stream, .cancel = cancel, .capabilities = capabilities, .shutdown = shutdown };
};
