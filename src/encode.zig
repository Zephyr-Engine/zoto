const std = @import("std");
const wire = @import("wire.zig");
const types = @import("types.zig");
const message = @import("message.zig");

/// Encode a protobuf message to any writer.
/// The message type must have a `pub const _fields` declaration.
pub fn encode(msg: anytype, writer: *std.Io.Writer) !void {
    const T = @TypeOf(msg);
    comptime types.validateMessage(T);
    try encodeFields(T, T._fields, msg, writer);
}

/// Encode directly into a byte slice. Returns the number of bytes written.
pub fn encodeToSlice(msg: anytype, buf: []u8) !usize {
    var writer = std.Io.Writer.fixed(buf);
    try encode(msg, &writer);
    return writer.end;
}

/// Calculate the encoded size of a message without writing anything.
/// Useful for pre-allocating buffers.
pub fn encodedSize(msg: anytype) usize {
    const T = @TypeOf(msg);
    comptime types.validateMessage(T);
    return encodedFieldsSize(T, T._fields, msg);
}

/// Encode a protobuf message directly to a file.
/// The message type must have a `pub const _fields` declaration.
pub fn encodeToFile(msg: anytype, filename: []const u8, io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, filename, .{});
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    try encode(msg, &fw.interface);
    try fw.interface.flush();
}

/// Calculate encoded size using an explicit fields declaration.
pub fn encodedFieldsSize(comptime T: type, comptime fields_decl: anytype, msg: T) usize {
    var discard_buf: [64]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buf);
    encodeFields(T, fields_decl, msg, &discarding.writer) catch unreachable;
    return @intCast(discarding.fullCount());
}

// ============================================================================
// Internal encoding logic
// ============================================================================

/// Encode struct fields using an explicit fields declaration.
pub fn encodeFields(comptime T: type, comptime fields_decl: anytype, msg: T, writer: *std.Io.Writer) !void {
    // Iterate annotated fields in declaration order
    inline for (comptime std.meta.fieldNames(@TypeOf(fields_decl))) |field_name| {
        const opts = comptime types.toFieldOptions(@field(fields_decl, field_name));
        const value = @field(msg, field_name);
        const FieldType = @TypeOf(value);

        try encodeField(FieldType, opts, value, writer);
    }
}

fn encodeField(comptime FieldType: type, comptime opts: types.FieldOptions, value: FieldType, writer: *std.Io.Writer) !void {
    // Handle optionals: skip null values
    if (comptime isOptional(FieldType)) {
        if (value) |v| {
            const Inner = @typeInfo(FieldType).optional.child;
            try encodeField(Inner, opts, v, writer);
        }
        return;
    }

    // Handle slices (repeated fields and bytes)
    if (comptime isSlice(FieldType)) {
        const Child = std.meta.Elem(FieldType);

        // []const u8 -> bytes/string field
        if (Child == u8) {
            if (opts.omit_default and value.len == 0) return;
            try wire.writeBytesField(writer, opts.number, value);
            return;
        }

        // Packed repeated numeric field
        if (opts.encoding == .pack) {
            if (value.len == 0) return;
            try encodePackedRepeated(Child, opts, value, writer);
            return;
        }

        // Standard repeated field (one tag per element)
        for (value) |elem| {
            try encodeSingleValue(Child, opts, elem, writer);
        }
        return;
    }

    // Scalar / sub-message: check omit_default
    if (opts.omit_default and isDefaultValue(FieldType, value)) return;

    try encodeSingleValue(FieldType, opts, value, writer);
}

fn encodeSingleValue(comptime T: type, comptime opts: types.FieldOptions, value: T, writer: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .bool => {
            try wire.writeVarintField(writer, opts.number, if (value) 1 else 0);
        },

        .int => |info| {
            switch (opts.encoding) {
                .sint => {
                    const signed: i64 = if (info.signedness == .signed) @as(i64, value) else @intCast(value);
                    try wire.writeVarintField(writer, opts.number, wire.zigzagEncode(signed));
                },
                .fixed, .sfixed => {
                    if (info.bits <= 32) {
                        try wire.writeFixed32Field(writer, opts.number, @bitCast(@as(u32, @bitCast(@as(i32, @intCast(value))))));
                    } else {
                        try wire.writeFixed64Field(writer, opts.number, @bitCast(@as(u64, @bitCast(@as(i64, @intCast(value))))));
                    }
                },
                else => {
                    // Default varint encoding
                    const as_u64: u64 = if (info.signedness == .signed)
                        @bitCast(@as(i64, value))
                    else
                        @intCast(value);
                    try wire.writeVarintField(writer, opts.number, as_u64);
                },
            }
        },

        .float => |info| {
            if (info.bits == 32) {
                try wire.writeFixed32Field(writer, opts.number, @bitCast(value));
            } else if (info.bits == 64) {
                try wire.writeFixed64Field(writer, opts.number, @bitCast(value));
            } else {
                @compileError("Unsupported float size");
            }
        },

        .@"enum" => {
            try wire.writeVarintField(writer, opts.number, @intFromEnum(value));
        },

        .@"struct" => {
            // Sub-message: encode as length-delimited
            const sub_fields = comptime message.fieldsFor(T);
            const size = encodedFieldsSize(T, sub_fields, value);
            try wire.encodeTag(writer, opts.number, .length_delimited);
            try wire.encodeVarint(writer, @intCast(size));
            try encodeFields(T, sub_fields, value, writer);
        },

        else => @compileError("Unsupported field type: " ++ @typeName(T)),
    }
}

fn encodePackedRepeated(comptime Elem: type, comptime opts: types.FieldOptions, values: []const Elem, writer: *std.Io.Writer) !void {
    // Calculate packed payload size
    var discard_buf: [64]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buf);
    for (values) |v| {
        try encodePackedElement(Elem, opts, v, &discarding.writer);
    }

    // Write tag + length + packed data
    try wire.encodeTag(writer, opts.number, .length_delimited);
    try wire.encodeVarint(writer, discarding.fullCount());
    for (values) |v| {
        try encodePackedElement(Elem, opts, v, writer);
    }
}

fn encodePackedElement(comptime T: type, comptime opts: types.FieldOptions, value: T, writer: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .int => |info| {
            switch (opts.encoding) {
                .pack, .default => {
                    const as_u64: u64 = if (info.signedness == .signed)
                        @bitCast(@as(i64, value))
                    else
                        @intCast(value);
                    try wire.encodeVarint(writer, as_u64);
                },
                .sint => {
                    const signed: i64 = if (info.signedness == .signed) @as(i64, value) else @intCast(value);
                    try wire.encodeVarint(writer, wire.zigzagEncode(signed));
                },
                .fixed, .sfixed => {
                    if (info.bits <= 32) {
                        try writer.writeAll(&@as([4]u8, @bitCast(@as(u32, @bitCast(@as(i32, @intCast(value)))))));
                    } else {
                        try writer.writeAll(&@as([8]u8, @bitCast(@as(u64, @bitCast(@as(i64, @intCast(value)))))));
                    }
                },
            }
        },
        .float => |info| {
            if (info.bits == 32) {
                try writer.writeAll(&@as([4]u8, @bitCast(value)));
            } else {
                try writer.writeAll(&@as([8]u8, @bitCast(value)));
            }
        },
        .@"enum" => {
            try wire.encodeVarint(writer, @intFromEnum(value));
        },
        .bool => {
            try wire.encodeVarint(writer, if (value) @as(u64, 1) else 0);
        },
        else => @compileError("Packed encoding not supported for " ++ @typeName(T)),
    }
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn isSlice(comptime T: type) bool {
    return @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice;
}

fn isDefaultValue(comptime T: type, value: T) bool {
    switch (@typeInfo(T)) {
        .bool => return value == false,
        .int => return value == 0,
        .float => return value == 0.0,
        .@"enum" => return @intFromEnum(value) == 0,
        .@"struct" => return false, // sub-messages always encode
        else => return false,
    }
}

const testing = std.testing;

const SimpleMsg = struct {
    pub const _fields = .{
        .id = .{ .number = 1 },
        .name = .{ .number = 2 },
        .active = .{ .number = 3 },
    };
    id: u32 = 0,
    name: []const u8 = "",
    active: bool = false,
};

test "encode u32" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: u32 = 0,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = 150 }, &buf);
    try testing.expect(n > 0);
    // field 1, varint: tag=0x08, value=150 (0x96 0x01)
    try testing.expectEqual(0x08, buf[0]);
}

test "encode i32 default varint" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: i32 = 0,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = -1 }, &buf);
    try testing.expect(n > 0);
}

test "encode i32 sint encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .encoding = .sint } };
        x: i32 = 0,
    };
    var buf: [32]u8 = undefined;
    // sint encoding of -1 is zigzag 1, which is smaller than default
    const n_sint = try encodeToSlice(Msg{ .x = -1 }, &buf);
    // Should be compact: tag (1 byte) + varint 1 (1 byte) = 2 bytes
    try testing.expectEqual(2, n_sint);
}

test "encode u32 fixed encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .encoding = .fixed } };
        x: u32 = 0,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = 42 }, &buf);
    // tag (1 byte) + 4 bytes fixed = 5 bytes
    try testing.expectEqual(5, n);
}

test "encode i64 sfixed encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .encoding = .sfixed } };
        x: i64 = 0,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = -100 }, &buf);
    // tag (1 byte) + 8 bytes fixed64 = 9 bytes
    try testing.expectEqual(9, n);
}

test "encode bool" {
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(SimpleMsg{ .active = true }, &buf);
    try testing.expect(n > 0);
}

test "encode f32" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: f32 = 0.0,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = 3.14 }, &buf);
    // tag (1 byte) + 4 bytes = 5
    try testing.expectEqual(5, n);
}

test "encode f64" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: f64 = 0.0,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = 3.14159 }, &buf);
    // tag (1 byte) + 8 bytes = 9
    try testing.expectEqual(9, n);
}

test "encode []const u8" {
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(SimpleMsg{ .name = "hello" }, &buf);
    try testing.expect(n > 0);
}

test "encode enum" {
    const Color = enum(u8) { red = 0, green = 1, blue = 2 };
    const Msg = struct {
        pub const _fields = .{ .color = .{ .number = 1 } };
        color: Color = .red,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .color = .blue }, &buf);
    try testing.expect(n > 0);
}

test "encode optional: null omitted" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: ?u32 = null,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = null }, &buf);
    try testing.expectEqual(0, n);
}

test "encode optional: non-null included" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: ?u32 = null,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = 42 }, &buf);
    try testing.expect(n > 0);
}

test "encode repeated non-packed" {
    const Msg = struct {
        pub const _fields = .{ .vals = .{ .number = 1 } };
        vals: []const u32 = &.{},
    };
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(Msg{ .vals = &.{ 1, 2, 3 } }, &buf);
    // Each element gets its own tag+varint
    try testing.expect(n > 0);
}

test "encode repeated packed" {
    const Msg = struct {
        pub const _fields = .{ .vals = .{ .number = 1, .encoding = .pack } };
        vals: []const u32 = &.{},
    };
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(Msg{ .vals = &.{ 1, 2, 3 } }, &buf);
    // Packed: single tag + length + packed data
    try testing.expect(n > 0);
    // Should be smaller than non-packed (one tag vs three)
    const Msg2 = struct {
        pub const _fields = .{ .vals = .{ .number = 1 } };
        vals: []const u32 = &.{},
    };
    var buf2: [64]u8 = undefined;
    const n2 = try encodeToSlice(Msg2{ .vals = &.{ 1, 2, 3 } }, &buf2);
    try testing.expect(n < n2);
}

test "encode empty repeated packed omitted" {
    const Msg = struct {
        pub const _fields = .{ .vals = .{ .number = 1, .encoding = .pack } };
        vals: []const u32 = &.{},
    };
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(Msg{ .vals = &.{} }, &buf);
    try testing.expectEqual(0, n);
}

test "omit_default: zero values omitted" {
    var buf: [64]u8 = undefined;
    // All defaults → nothing encoded
    const n = try encodeToSlice(SimpleMsg{}, &buf);
    try testing.expectEqual(0, n);
}

test "omit_default: non-zero values encoded" {
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(SimpleMsg{ .id = 1 }, &buf);
    try testing.expect(n > 0);
}

test "omit_default false: zero value still encoded" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .omit_default = false } };
        x: u32 = 0,
    };
    var buf: [32]u8 = undefined;
    const n = try encodeToSlice(Msg{ .x = 0 }, &buf);
    try testing.expect(n > 0);
}

test "encode sub-message" {
    const Inner = struct {
        pub const _fields = .{ .val = .{ .number = 1 } };
        val: u32 = 0,
    };
    const Outer = struct {
        pub const _fields = .{ .inner = .{ .number = 1 } };
        inner: Inner = .{},
    };
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(Outer{ .inner = .{ .val = 42 } }, &buf);
    try testing.expect(n > 0);
}

test "encodedSize matches encodeToSlice" {
    const msg = SimpleMsg{ .id = 42, .name = "hello", .active = true };
    const size = encodedSize(msg);
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(msg, &buf);
    try testing.expectEqual(size, n);
}

test "encode multiple fields" {
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(SimpleMsg{ .id = 1, .name = "a", .active = true }, &buf);
    // Should have all three fields encoded
    try testing.expect(n > 0);
    // Verify it's bigger than just one field
    var buf2: [64]u8 = undefined;
    const n2 = try encodeToSlice(SimpleMsg{ .id = 1 }, &buf2);
    try testing.expect(n > n2);
}

test "encodeToFile writes correct data" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    const io = threaded.io();
    const msg = SimpleMsg{ .id = 42, .name = "file test", .active = true };

    try encodeToFile(msg, "/tmp/zoto_encode_test.pb", io);

    // Read back and verify it matches encodeToSlice
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(msg, &buf);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, "/tmp/zoto_encode_test.pb", .{ .mode = .read_only });
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    const file_data = try fr.interface.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(file_data);

    try testing.expectEqualSlices(u8, buf[0..n], file_data);
}
