const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("zini", .{ .source_file = .{ .path = "src/ini.zig" } });
}
