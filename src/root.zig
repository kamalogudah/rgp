//! RGP's reusable, deterministic domain core.
//!
//! The CLI adapts process arguments and I/O to this package. Parser, corpus,
//! storage, learning, and agent modules belong here as they are introduced.

const std = @import("std");

pub const version = "0.1.0-dev";

pub const Command = enum {
    help,
    version,
};

pub const ParseError = error{
    unknown_command,
    unexpected_argument,
};

/// Parse RGP command arguments after the executable name.
///
/// The result intentionally has no process or I/O dependency, so callers such
/// as a future interactive shell can reuse the same command contract.
pub fn parseCommand(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .help;

    const command = args[0];
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        if (args.len == 1) return .help;
        return error.unexpected_argument;
    }
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-V")) {
        if (args.len == 1) return .version;
        return error.unexpected_argument;
    }

    return error.unknown_command;
}

test "parse help commands" {
    try std.testing.expectEqual(.help, try parseCommand(&.{}));
    try std.testing.expectEqual(.help, try parseCommand(&.{"help"}));
    try std.testing.expectEqual(.help, try parseCommand(&.{"--help"}));
    try std.testing.expectEqual(.help, try parseCommand(&.{"-h"}));
}

test "parse version commands" {
    try std.testing.expectEqual(.version, try parseCommand(&.{"--version"}));
    try std.testing.expectEqual(.version, try parseCommand(&.{"-V"}));
}

test "reject invalid command arguments" {
    try std.testing.expectError(error.unknown_command, parseCommand(&.{"analyze"}));
    try std.testing.expectError(error.unexpected_argument, parseCommand(&.{ "--version", "extra" }));
}
