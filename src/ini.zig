const std = @import("std");
const builtin = @import("builtin");

///Stringifies the struct
pub fn stringify(writer: anytype, data: anytype) !void {
    const Type = @TypeOf(data);

    const type_info: std.builtin.Type.Struct = @typeInfo(Type).Struct;

    inline for (type_info.fields) |field| {
        const field_type_info: std.builtin.Type = @typeInfo(field.type);

        const field_contents = @field(data, field.name);

        try std.fmt.format(writer, "{s} = ", .{field.name});
        switch (field_type_info) {
            .Int, .Float => try std.fmt.format(writer, "{d}", .{field_contents}),
            .Bool => try std.fmt.format(writer, "{}", .{field_contents}),
            .Array => |array_info| {
                if (array_info.child != u8) {
                    @compileError("Unknown array child type " ++ @typeName(array_info.child));
                }

                try std.fmt.format(writer, "{s}", .{&field_contents});
            },
            .Pointer => |pointer_info| {
                if (pointer_info.child != u8) {
                    @compileError("Unknown pointer child type " ++ @typeName(pointer_info.child));
                }

                if (pointer_info.size != .Slice) {
                    @compileError("Unable to format non-slices!");
                }

                try std.fmt.format(writer, "{s}", .{field_contents});
            },
            else => @compileError("Unknown type " ++ @typeName(field.type)),
        }
        try std.fmt.format(writer, line_ending, .{});
    }
}

pub fn readStruct(reader: anytype, comptime T: type, allocator: std.mem.Allocator) !T {
    const Ini = IniReader(@TypeOf(reader), 4096, 4096);

    var ini = Ini.init(reader);

    const type_info = @typeInfo(T).Struct;

    var ret = T{};

    while (try ini.next()) |next| {
        inline for (type_info.fields) |field| {
            if (std.mem.eql(u8, field.name, next.key)) {
                const field_type_info = @typeInfo(field.type);
                switch (field_type_info) {
                    .Int => @field(ret, field.name) = try std.fmt.parseInt(field.type, next.value, 0),
                    .Float => @field(ret, field.name) = try std.fmt.parseFloat(field.type, next.value),
                    .Bool => {
                        if (std.ascii.eqlIgnoreCase(next.value, "true") or
                            std.ascii.eqlIgnoreCase(next.value, "yes"))
                        {
                            @field(ret, field.name) = true;
                        } else if (std.ascii.eqlIgnoreCase(next.value, "false") or
                            std.ascii.eqlIgnoreCase(next.value, "no"))
                        {
                            @field(ret, field.name) = false;
                        } else {
                            return error.ParseErrorInvalidBool;
                        }
                    },
                    .Pointer => |pointer_info| {
                        if (pointer_info.child != u8) {
                            @compileError("Unknown pointer child type " ++ @typeName(pointer_info.child));
                        }

                        if (pointer_info.size != .Slice) {
                            @compileError("Unable to format non-slices!");
                        }

                        @field(ret, field.name) = try allocator.dupe(u8, next.value);
                    },
                    else => @compileError("Unknown type " ++ @typeName(field.type)),
                }
                break;
            }
        }
    }

    return ret;
}

pub const line_ending = if (builtin.os.tag == .windows) "\r\n" else "\n";

test "read basic struct" {
    var str =
        \\boolean_1=yes
        \\boolean_2=no
        \\boolean_3=true
        \\boolean_4=false
        \\
        \\int_1 =   0
        \\int_2 =   044
        \\int_3 =   05783
        \\int_4 =   051412
        \\int_5 =   078990  
        \\
        \\float_1 = 1.014185
        \\float_2 = 41941.15617
    ;
    var stream = std.io.fixedBufferStream(str);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const TestRead = struct {
        boolean_1: bool = true,
        boolean_2: bool = false,
        boolean_3: bool = true,
        boolean_4: bool = false,
        int_1: i32 = 0,
        int_2: u32 = 44,
        int_3: u128 = 5783,
        int_4: i32 = 51412,
        int_5: i64 = 78990,
        float_1: f64 = 1.014185,
        float_2: f32 = 41941.15617,
    };

    try std.testing.expectEqualDeep(TestRead{}, try readStruct(stream.reader(), TestRead, arena.allocator()));
}

test "write basic struct" {
    const str = "boolean_1 = true" ++ line_ending ++ "boolean_2 = false" ++ line_ending;

    const TestWrite = struct {
        boolean_1: bool = true,
        boolean_2: bool = false,
    };

    var data = TestWrite{};

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try stringify(out.writer(), data);

    try std.testing.expectEqualStrings(str, out.items);
}

pub fn IniReader(comptime ReaderType: type, comptime max_line_size: comptime_int, comptime max_section_size: comptime_int) type {
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
