const std = @import("std");
const contract = @import("contract.zig");
const fx = @import("../agents/fx/adapter.zig");

pub const AdapterInfo = struct { name: []const u8, default: bool, available: bool, capabilities: contract.Capabilities };
pub const adapters = [_]AdapterInfo{.{ .name = "fx", .default = true, .available = false, .capabilities = .{} }};

pub const Registry = struct {
    selected: []const u8 = "fx",
    pub fn list(_: Registry) []const AdapterInfo {
        return &adapters;
    }
    pub fn use(self: *Registry, name: []const u8) !void {
        for (adapters) |adapter| if (std.mem.eql(u8, name, adapter.name)) {
            self.selected = adapter.name;
            return;
        };
        return error.UnknownAdapter;
    }
    pub fn info(self: Registry) AdapterInfo {
        for (adapters) |adapter| if (std.mem.eql(u8, self.selected, adapter.name)) return adapter;
        return adapters[0];
    }
    pub fn selectedAgent(self: *Registry, fx_adapter: *fx.FxAdapter) !contract.CodingAgent {
        if (!std.mem.eql(u8, self.selected, "fx")) return error.UnknownAdapter;
        return fx_adapter.agent();
    }
};

test "registry defaults to fx and supports explicit selection" {
    var registry = Registry{};
    try std.testing.expectEqualStrings("fx", registry.info().name);
    try std.testing.expect(registry.info().default);
    try std.testing.expect(!registry.info().available);
    try registry.use("fx");
    try std.testing.expectError(error.UnknownAdapter, registry.use("missing"));
}
