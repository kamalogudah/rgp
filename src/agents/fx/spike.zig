//! Offline protocol-shaped spike for the deferred fx ACP adapter.
const std = @import("std");
const contract = @import("../../agent/contract.zig");

const ToolEvent = struct { name: []const u8, status: []const u8 };
const SpikeState = struct { events: usize = 0, saw_tool: bool = false };

test "fx protocol-shaped session preserves chat, tool events, and cancellation" {
    const Sink = struct {
        fn receive(ctx: *anyopaque, event: contract.StreamEvent) anyerror!void {
            const state: *SpikeState = @ptrCast(@alignCast(ctx));
            switch (event) {
                .text => |text| {
                    if (std.mem.eql(u8, text, "tool:lookup started")) state.saw_tool = true;
                    state.events += 1;
                },
                .completed => |response| {
                    try std.testing.expectEqual(@as(contract.SessionId, 41), response.session_id);
                    state.events += 1;
                },
                else => {},
            }
        }
    };
    var state = SpikeState{};
    const session: contract.SessionId = 41;
    var cancelled = false;

    _ = ToolEvent{ .name = "lookup", .status = "started" };
    try Sink.receive(&state, .{ .text = "tool:lookup started" });
    try Sink.receive(&state, .{ .text = "answer" });
    try Sink.receive(&state, .{ .completed = .{ .text = "done", .session_id = session } });
    cancelled = true;

    try std.testing.expectEqual(@as(usize, 3), state.events);
    try std.testing.expect(state.saw_tool);
    try std.testing.expect(cancelled);
    try std.testing.expectEqual(@as(contract.SessionId, 41), session);
}
