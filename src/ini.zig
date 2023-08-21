const std = @import("std");

pub fn Ini(comptime ReaderType: type, comptime max_line_size: comptime_int, comptime max_section_size: comptime_int) type {
    return struct {
        read_section: bool,
        read_buf: [max_line_size]u8,
        current_section: [max_section_size]u8,
        current_section_len: usize,
        reader: ReaderType,

        const Self = @This();

        pub fn init(reader: ReaderType) Self {
            var self = Self{
                .read_buf = undefined,
                .current_section = undefined,
                .current_section_len = 0,
                .reader = reader,
                .read_section = false,
            };

            return self;
        }

        const Item = struct {
            key: []const u8,
            value: []const u8,
            section: ?[]const u8,
        };

        pub fn next(self: *Self) !?Item {
            while (try self.reader.readUntilDelimiterOrEof(&self.read_buf, '\n')) |read_line| {
                //Trim the line
                var line = std.mem.trim(u8, read_line, " \t\r");

                //If the line is blank, skip it
                if (line.len == 0) {
                    continue;
                }

                //If the first char is a comment, skip it
                if (line[0] == '#' or line[0] == ';') {
                    continue;
                }

                //If the line starts with a [, then its the start of a new section
                if (line[0] == '[') {
                    //Find the index of the last ] in the line
                    const closing_idx = std.mem.lastIndexOf(u8, line, "]");

                    if (closing_idx) |idx| {
                        //Copy the section into the current section
                        @memcpy(self.current_section[0 .. idx - 1], line[1..idx]);

                        self.current_section_len = idx - 1;

                        //Mark that we have read a section
                        self.read_section = true;

                        continue;
                    } else {
                        return error.MissingClosingBracket;
                    }
                }

                const sep_idx = std.mem.indexOf(u8, line, "=") orelse return error.MissingKeyValueSeparator;

                var key = line[0..sep_idx];
                var value = line[sep_idx + 1 ..];

                //NOTE: the full line has already been pre-trimmed, so we dont have to worry about the outsides
                //Strip whitespace from end of key
                key = std.mem.trimRight(u8, key, " \t");
                //Strip whitespace from start of value
                value = std.mem.trimLeft(u8, value, " \t");

                return .{
                    .key = key,
                    .value = value,
                    .section = if (self.read_section) &self.current_section else null,
                };
            }

            return null;
        }
    };
}
