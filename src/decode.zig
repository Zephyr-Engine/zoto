const std = @import("std");
const wire = @import("wire.zig");
const types = @import("types.zig");
const message = @import("message.zig");

pub const DecodeError = error{
    MalformedVarint,
    MalformedTag,
    UnknownWireType,
    WireTypeMismatch,
    UnexpectedEof,
    MessageTooLarge,
    EndOfStream,
    Overflow,
    InvalidEnumValue,
};

/// Decode a protobuf message from any reader.
/// Allocator is needed for repeated fields and bytes — the caller owns
/// all returned memory.
pub fn decode(comptime T: type, reader: *std.Io.Reader, allocator: std.mem.Allocator) !T {
    comptime types.validateMessage(T);
    // Read until EOF for a top-level message
    return decodeMessage(T, T._fields, reader, null, allocator);
}

/// Decode from a byte slice. Convenience wrapper.
pub fn decodeFromSlice(comptime T: type, data: []const u8, allocator: std.mem.Allocator) !T {
    comptime types.validateMessage(T);
    var reader = std.Io.Reader.fixed(data);
    return decodeMessage(T, T._fields, &reader, @as(usize, data.len), allocator);
}

/// Decode a protobuf message from a file.
/// The caller owns all returned memory — use `deinit` to free.
pub fn decodeFromFile(comptime T: type, filename: []const u8, io: std.Io, allocator: std.mem.Allocator, options: types.FileOptions) !T {
    comptime types.validateMessage(T);
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);
    var default_buf: [4096]u8 = undefined;
    const buf = options.buffer orelse &default_buf;
    var fr = file.reader(io, buf);
    const data = try fr.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(data);
    return decodeFromSlice(T, data, allocator);
}

/// Free all memory allocated during decode (repeated fields, byte slices).
pub fn deinit(msg: anytype, allocator: std.mem.Allocator) void {
    const T = @TypeOf(msg);
    if (!types.isMessage(T)) return;
    deinitWithFields(T, T._fields, msg, allocator);
}

/// Free all memory using an explicit fields declaration.
pub fn deinitWithFields(comptime T: type, comptime fields_decl: anytype, msg: T, allocator: std.mem.Allocator) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(fields_decl))) |field_name| {
        const value = @field(msg, field_name);
        const FieldType = @TypeOf(value);
        deinitField(FieldType, value, allocator);
    }
}

fn deinitField(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    if (comptime isOptional(T)) {
        if (value) |v| {
            const Inner = @typeInfo(T).optional.child;
            deinitField(Inner, v, allocator);
        }
        return;
    }

    if (comptime isSlice(T)) {
        const Child = std.meta.Elem(T);
        if (Child == u8) {
            if (value.len > 0) allocator.free(value);
            return;
        }
        // Free sub-message contents in repeated fields
        if (@typeInfo(Child) == .@"struct") {
            const sub_fields = comptime message.fieldsFor(Child);
            for (value) |elem| {
                deinitWithFields(Child, sub_fields, elem, allocator);
            }
        }
        if (value.len > 0) allocator.free(value);
        return;
    }

    // Recursively free sub-message fields
    if (@typeInfo(T) == .@"struct") {
        const sub_fields = comptime message.fieldsFor(T);
        inline for (comptime std.meta.fieldNames(@TypeOf(sub_fields))) |field_name| {
            const fv = @field(value, field_name);
            deinitField(@TypeOf(fv), fv, allocator);
        }
    }
}

// ============================================================================
// Internal decoding
// ============================================================================

/// Decode a message using an explicit fields declaration.
pub fn decodeMessage(comptime T: type, comptime fields_decl: anytype, reader: *std.Io.Reader, limit: ?usize, allocator: std.mem.Allocator) !T {
    var result: T = comptime defaults(T);

    // Temporary ArrayLists for repeated fields
    const field_names = comptime std.meta.fieldNames(@TypeOf(fields_decl));

    // We need dynamic arrays for repeated fields. Use a tuple of ArrayLists.
    var repeated = comptime initRepeatedLists(T, fields_decl);

    var bytes_read: usize = 0;
    while (true) {
        // Check length limit for sub-messages
        if (limit) |l| {
            if (bytes_read >= l) break;
        }

        const tag = wire.decodeTag(reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        // Count bytes for the tag
        bytes_read += wire.tagSize(tag.field_number);

        var matched = false;
        inline for (field_names, 0..) |field_name, idx| {
            const opts = comptime types.toFieldOptions(@field(fields_decl, field_name));
            if (tag.field_number == opts.number) {
                matched = true;
                const FieldType = @TypeOf(@field(result, field_name));
                const decoded_bytes = try decodeFieldValue(
                    FieldType,
                    opts,
                    &result,
                    field_name,
                    &repeated,
                    idx,
                    tag.wire_type,
                    reader,
                    allocator,
                );
                bytes_read += decoded_bytes;
            }
        }

        if (!matched) {
            // Skip unknown field (forward compatibility) and track bytes
            const skipped = try wire.skipField(reader, tag.wire_type);
            bytes_read += skipped;
        }
    }

    // Finalize repeated fields: convert ArrayLists to owned slices
    inline for (field_names, 0..) |field_name, idx| {
        const FieldType = @TypeOf(@field(result, field_name));
        if (comptime isSlice(FieldType) and std.meta.Elem(FieldType) != u8) {
            const list_ptr = &repeated[idx];
            if (@TypeOf(list_ptr.*) != void) {
                @field(result, field_name) = try list_ptr.toOwnedSlice(allocator);
            }
        }
    }

    return result;
}

fn decodeFieldValue(
    comptime FieldType: type,
    comptime opts: types.FieldOptions,
    result: anytype,
    comptime field_name: []const u8,
    repeated: anytype,
    comptime field_idx: usize,
    wire_type: wire.WireType,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) !usize {
    var bytes: usize = 0;

    // Optional fields
    if (comptime isOptional(FieldType)) {
        const Inner = @typeInfo(FieldType).optional.child;
        var inner_result: Inner = undefined;
        bytes = try decodeSingleValue(Inner, opts, &inner_result, wire_type, reader, allocator);
        @field(result, field_name) = inner_result;
        return bytes;
    }

    // Repeated fields (slices of non-u8)
    if (comptime isSlice(FieldType)) {
        const Child = std.meta.Elem(FieldType);
        if (Child == u8) {
            // bytes / string
            bytes = try decodeSingleValue(FieldType, opts, &@field(result, field_name), wire_type, reader, allocator);
            return bytes;
        }

        // Append to the ArrayList for this field
        const list_ptr = &repeated[field_idx];
        if (wire_type == .length_delimited and opts.encoding == .pack) {
            // Packed repeated
            const payload_len = try wire.decodeVarint(reader);
            bytes += wire.varintSize(payload_len);
            var remaining: usize = @intCast(payload_len);
            while (remaining > 0) {
                var elem: Child = undefined;
                const elem_bytes = try decodePackedElement(Child, opts, &elem, reader);
                remaining -= elem_bytes;
                bytes += elem_bytes;
                try list_ptr.append(allocator, elem);
            }
        } else {
            // Non-packed: one element per tag
            var elem: Child = undefined;
            const elem_bytes = try decodeSingleValue(Child, opts, &elem, wire_type, reader, allocator);
            bytes += elem_bytes;
            try list_ptr.append(allocator, elem);
        }
        return bytes;
    }

    // Scalar or sub-message
    bytes = try decodeSingleValue(FieldType, opts, &@field(result, field_name), wire_type, reader, allocator);
    return bytes;
}

fn decodeSingleValue(
    comptime T: type,
    comptime opts: types.FieldOptions,
    out: *T,
    wire_type: wire.WireType,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) !usize {
    var bytes: usize = 0;

    switch (@typeInfo(T)) {
        .bool => {
            if (wire_type != .varint) return error.WireTypeMismatch;
            const v = try wire.decodeVarint(reader);
            bytes += wire.varintSize(v);
            out.* = v != 0;
        },

        .int => |info| {
            switch (opts.encoding) {
                .fixed, .sfixed => {
                    if (info.bits <= 32) {
                        if (wire_type != .fixed32) return error.WireTypeMismatch;
                        const buf = try reader.takeArray(4);
                        bytes += 4;
                        out.* = @intCast(@as(i32, @bitCast(buf.*)));
                    } else {
                        if (wire_type != .fixed64) return error.WireTypeMismatch;
                        const buf = try reader.takeArray(8);
                        bytes += 8;
                        out.* = @intCast(@as(i64, @bitCast(buf.*)));
                    }
                },
                .sint => {
                    if (wire_type != .varint) return error.WireTypeMismatch;
                    const raw = try wire.decodeVarint(reader);
                    bytes += wire.varintSize(raw);
                    const decoded = wire.zigzagDecode(raw);
                    out.* = @intCast(decoded);
                },
                else => {
                    if (wire_type != .varint) return error.WireTypeMismatch;
                    const raw = try wire.decodeVarint(reader);
                    bytes += wire.varintSize(raw);
                    if (info.signedness == .signed) {
                        out.* = @intCast(@as(i64, @bitCast(raw)));
                    } else {
                        out.* = @intCast(raw);
                    }
                },
            }
        },

        .float => |info| {
            if (info.bits == 32) {
                if (wire_type != .fixed32) return error.WireTypeMismatch;
                const buf = try reader.takeArray(4);
                bytes += 4;
                out.* = @bitCast(buf.*);
            } else {
                if (wire_type != .fixed64) return error.WireTypeMismatch;
                const buf = try reader.takeArray(8);
                bytes += 8;
                out.* = @bitCast(buf.*);
            }
        },

        .@"enum" => {
            if (wire_type != .varint) return error.WireTypeMismatch;
            const raw = try wire.decodeVarint(reader);
            bytes += wire.varintSize(raw);
            out.* = @enumFromInt(@as(std.meta.Tag(T), @intCast(raw)));
        },

        .pointer => |ptr_info| {
            // []const u8 (bytes/string)
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                if (wire_type != .length_delimited) return error.WireTypeMismatch;
                const len = try wire.decodeVarint(reader);
                bytes += wire.varintSize(len);
                const buf = try allocator.alloc(u8, @intCast(len));
                reader.readSliceAll(buf) catch {
                    allocator.free(buf);
                    return error.UnexpectedEof;
                };
                bytes += @intCast(len);
                out.* = buf;
            } else {
                @compileError("Unsupported pointer type: " ++ @typeName(T));
            }
        },

        .@"struct" => {
            if (wire_type != .length_delimited) return error.WireTypeMismatch;
            const sub_fields = comptime message.fieldsFor(T);
            const len = try wire.decodeVarint(reader);
            bytes += wire.varintSize(len);
            out.* = try decodeMessage(T, sub_fields, reader, @intCast(len), allocator);
            bytes += @intCast(len);
        },

        else => @compileError("Unsupported field type: " ++ @typeName(T)),
    }

    return bytes;
}

fn decodePackedElement(comptime T: type, comptime opts: types.FieldOptions, out: *T, reader: *std.Io.Reader) !usize {
    var bytes: usize = 0;
    switch (@typeInfo(T)) {
        .int => |info| {
            switch (opts.encoding) {
                .pack, .default => {
                    const raw = try wire.decodeVarint(reader);
                    bytes += wire.varintSize(raw);
                    if (info.signedness == .signed) {
                        out.* = @intCast(@as(i64, @bitCast(raw)));
                    } else {
                        out.* = @intCast(raw);
                    }
                },
                .sint => {
                    const raw = try wire.decodeVarint(reader);
                    bytes += wire.varintSize(raw);
                    out.* = @intCast(wire.zigzagDecode(raw));
                },
                .fixed, .sfixed => {
                    if (info.bits <= 32) {
                        const buf = try reader.takeArray(4);
                        bytes += 4;
                        out.* = @intCast(@as(i32, @bitCast(buf.*)));
                    } else {
                        const buf = try reader.takeArray(8);
                        bytes += 8;
                        out.* = @intCast(@as(i64, @bitCast(buf.*)));
                    }
                },
            }
        },
        .float => |info| {
            if (info.bits == 32) {
                const buf = try reader.takeArray(4);
                bytes += 4;
                out.* = @bitCast(buf.*);
            } else {
                const buf = try reader.takeArray(8);
                bytes += 8;
                out.* = @bitCast(buf.*);
            }
        },
        .bool => {
            const raw = try wire.decodeVarint(reader);
            bytes += wire.varintSize(raw);
            out.* = raw != 0;
        },
        .@"enum" => {
            const raw = try wire.decodeVarint(reader);
            bytes += wire.varintSize(raw);
            out.* = @enumFromInt(@as(std.meta.Tag(T), @intCast(raw)));
        },
        else => @compileError("Packed decode not supported for " ++ @typeName(T)),
    }
    return bytes;
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn isSlice(comptime T: type) bool {
    return @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice;
}

/// Generate compile-time default values for all struct fields.
fn defaults(comptime T: type) T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.fields) |field| {
        if (field.defaultValue()) |dv| {
            @field(result, field.name) = dv;
        } else {
            // Zero-init
            @field(result, field.name) = std.mem.zeroes(field.type);
        }
    }
    return result;
}

/// Create a tuple of ArrayLists (or void) for each field — ArrayLists for
/// repeated fields, void for everything else.
fn initRepeatedLists(comptime T: type, comptime fields_decl: anytype) InitRepeatedTuple(T, fields_decl) {
    const field_names = std.meta.fieldNames(@TypeOf(fields_decl));
    var result: InitRepeatedTuple(T, fields_decl) = undefined;

    inline for (field_names, 0..) |field_name, idx| {
        const FieldType = StructFieldType(T, field_name);
        if (comptime isSlice(FieldType) and std.meta.Elem(FieldType) != u8) {
            const Child = std.meta.Elem(FieldType);
            result[idx] = std.ArrayListUnmanaged(Child).empty;
        } else {
            result[idx] = {};
        }
    }

    return result;
}

fn StructFieldType(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.type;
    }
    unreachable;
}

fn InitRepeatedTuple(comptime T: type, comptime fields_decl: anytype) type {
    const field_names = std.meta.fieldNames(@TypeOf(fields_decl));
    var field_types: [field_names.len]type = undefined;

    inline for (field_names, 0..) |field_name, idx| {
        const FieldType = StructFieldType(T, field_name);
        if (comptime isSlice(FieldType) and std.meta.Elem(FieldType) != u8) {
            const Child = std.meta.Elem(FieldType);
            field_types[idx] = std.ArrayListUnmanaged(Child);
        } else {
            field_types[idx] = void;
        }
    }

    return std.meta.Tuple(&field_types);
}

const testing = std.testing;
const encode_mod = @import("encode.zig");

fn roundtrip(comptime T: type, msg: T) !T {
    var buf: [512]u8 = undefined;
    const n = try encode_mod.encodeToSlice(msg, &buf);
    return decodeFromSlice(T, buf[0..n], testing.allocator);
}

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

test "roundtrip: u32" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: u32 = 0,
    };
    const decoded = try roundtrip(Msg, .{ .x = 12345 });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(12345, decoded.x);
}

test "roundtrip: u64" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: u64 = 0,
    };
    const decoded = try roundtrip(Msg, .{ .x = 0xDEADBEEFCAFE });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(0xDEADBEEFCAFE, decoded.x);
}

test "roundtrip: i32 default encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: i32 = 0,
    };
    const decoded = try roundtrip(Msg, .{ .x = -42 });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(-42, decoded.x);
}

test "roundtrip: i32 sint encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .encoding = .sint } };
        x: i32 = 0,
    };
    const decoded = try roundtrip(Msg, .{ .x = -1000 });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(-1000, decoded.x);
}

test "roundtrip: i64 sint encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .encoding = .sint } };
        x: i64 = 0,
    };
    const decoded = try roundtrip(Msg, .{ .x = -999999 });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(-999999, decoded.x);
}

test "roundtrip: u32 fixed encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .encoding = .fixed } };
        x: u32 = 0,
    };
    const decoded = try roundtrip(Msg, .{ .x = 42 });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(42, decoded.x);
}

test "roundtrip: i32 sfixed encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .encoding = .sfixed } };
        x: i32 = 0,
    };
    const decoded = try roundtrip(Msg, .{ .x = -42 });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(-42, decoded.x);
}

test "roundtrip: i64 sfixed encoding" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1, .encoding = .sfixed } };
        x: i64 = 0,
    };
    const decoded = try roundtrip(Msg, .{ .x = -123456789 });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(-123456789, decoded.x);
}

test "roundtrip: bool" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: bool = false,
    };
    const t = try roundtrip(Msg, .{ .x = true });
    defer deinit(t, testing.allocator);
    try testing.expect(t.x);

    const f = try roundtrip(Msg, .{ .x = false });
    defer deinit(f, testing.allocator);
    try testing.expect(!f.x);
}

test "roundtrip: f32" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: f32 = 0.0,
    };
    const decoded = try roundtrip(Msg, .{ .x = 3.14 });
    defer deinit(decoded, testing.allocator);
    try testing.expectApproxEqAbs(3.14, decoded.x, 0.001);
}

test "roundtrip: f64" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: f64 = 0.0,
    };
    const decoded = try roundtrip(Msg, .{ .x = 3.141592653589793 });
    defer deinit(decoded, testing.allocator);
    try testing.expectApproxEqAbs(3.141592653589793, decoded.x, 1e-15);
}

test "roundtrip: []const u8" {
    const decoded = try roundtrip(SimpleMsg, .{ .name = "hello world" });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqualStrings("hello world", decoded.name);
}

test "roundtrip: empty string" {
    const decoded = try roundtrip(SimpleMsg, .{ .name = "" });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqualStrings("", decoded.name);
}

test "roundtrip: enum" {
    const Color = enum(u8) { red = 0, green = 1, blue = 2 };
    const Msg = struct {
        pub const _fields = .{ .color = .{ .number = 1 } };
        color: Color = .red,
    };
    const decoded = try roundtrip(Msg, .{ .color = .blue });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(.blue, decoded.color);
}

test "roundtrip: optional present" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: ?u32 = null,
    };
    const decoded = try roundtrip(Msg, .{ .x = 42 });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(42, decoded.x.?);
}

test "roundtrip: optional null" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: ?u32 = null,
    };
    const decoded = try roundtrip(Msg, .{ .x = null });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(null, decoded.x);
}

test "roundtrip: optional string" {
    const Msg = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: ?[]const u8 = null,
    };
    const present = try roundtrip(Msg, .{ .x = "hi" });
    defer deinit(present, testing.allocator);
    try testing.expectEqualStrings("hi", present.x.?);

    const absent = try roundtrip(Msg, .{ .x = null });
    defer deinit(absent, testing.allocator);
    try testing.expectEqual(null, absent.x);
}

test "roundtrip: repeated non-packed" {
    const Msg = struct {
        pub const _fields = .{ .vals = .{ .number = 1 } };
        vals: []const u32 = &.{},
    };
    const decoded = try roundtrip(Msg, .{ .vals = &.{ 10, 20, 30 } });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(3, decoded.vals.len);
    try testing.expectEqual(10, decoded.vals[0]);
    try testing.expectEqual(20, decoded.vals[1]);
    try testing.expectEqual(30, decoded.vals[2]);
}

test "roundtrip: repeated packed" {
    const Msg = struct {
        pub const _fields = .{ .vals = .{ .number = 1, .encoding = .pack } };
        vals: []const u32 = &.{},
    };
    const decoded = try roundtrip(Msg, .{ .vals = &.{ 100, 200, 300 } });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(3, decoded.vals.len);
    try testing.expectEqual(100, decoded.vals[0]);
    try testing.expectEqual(200, decoded.vals[1]);
    try testing.expectEqual(300, decoded.vals[2]);
}

test "roundtrip: empty repeated" {
    const Msg = struct {
        pub const _fields = .{ .vals = .{ .number = 1, .encoding = .pack } };
        vals: []const u32 = &.{},
    };
    const decoded = try roundtrip(Msg, .{ .vals = &.{} });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(0, decoded.vals.len);
}

test "roundtrip: nested sub-message" {
    const Inner = struct {
        pub const _fields = .{ .val = .{ .number = 1 } };
        val: u32 = 0,
    };
    const Outer = struct {
        pub const _fields = .{ .name = .{ .number = 1 }, .inner = .{ .number = 2 } };
        name: []const u8 = "",
        inner: Inner = .{},
    };
    const decoded = try roundtrip(Outer, .{ .name = "test", .inner = .{ .val = 99 } });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqualStrings("test", decoded.name);
    try testing.expectEqual(99, decoded.inner.val);
}

test "roundtrip: optional sub-message" {
    const Inner = struct {
        pub const _fields = .{ .val = .{ .number = 1 } };
        val: u32 = 0,
    };
    const Outer = struct {
        pub const _fields = .{ .inner = .{ .number = 1 } };
        inner: ?Inner = null,
    };
    const present = try roundtrip(Outer, .{ .inner = .{ .val = 77 } });
    defer deinit(present, testing.allocator);
    try testing.expectEqual(77, present.inner.?.val);

    const absent = try roundtrip(Outer, .{ .inner = null });
    defer deinit(absent, testing.allocator);
    try testing.expectEqual(null, absent.inner);
}

test "roundtrip: multiple fields" {
    const decoded = try roundtrip(SimpleMsg, .{ .id = 42, .name = "Alice", .active = true });
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(42, decoded.id);
    try testing.expectEqualStrings("Alice", decoded.name);
    try testing.expect(decoded.active);
}

test "roundtrip: all defaults" {
    const decoded = try roundtrip(SimpleMsg, .{});
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(0, decoded.id);
    try testing.expectEqualStrings("", decoded.name);
    try testing.expect(!decoded.active);
}

test "decode skips unknown fields" {
    // Encode a message with fields 1 and 2, then decode as a type that only knows field 1
    const Full = struct {
        pub const _fields = .{ .a = .{ .number = 1 }, .b = .{ .number = 2 } };
        a: u32 = 0,
        b: u32 = 0,
    };
    const Partial = struct {
        pub const _fields = .{ .a = .{ .number = 1 } };
        a: u32 = 0,
    };
    var buf: [64]u8 = undefined;
    const n = try encode_mod.encodeToSlice(Full{ .a = 10, .b = 20 }, &buf);
    const decoded = try decodeFromSlice(Partial, buf[0..n], testing.allocator);
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(10, decoded.a);
}

test "deinit frees string memory" {
    const decoded = try roundtrip(SimpleMsg, .{ .name = "allocated" });
    // This should not leak — testing.allocator would catch it
    deinit(decoded, testing.allocator);
}

test "deinit frees repeated field memory" {
    const Msg = struct {
        pub const _fields = .{ .vals = .{ .number = 1, .encoding = .pack } };
        vals: []const u32 = &.{},
    };
    const decoded = try roundtrip(Msg, .{ .vals = &.{ 1, 2, 3, 4, 5 } });
    deinit(decoded, testing.allocator);
}

test "deinit frees nested sub-message strings" {
    const Inner = struct {
        pub const _fields = .{ .s = .{ .number = 1 } };
        s: []const u8 = "",
    };
    const Outer = struct {
        pub const _fields = .{ .inner = .{ .number = 1 } };
        inner: Inner = .{},
    };
    const decoded = try roundtrip(Outer, .{ .inner = .{ .s = "nested string" } });
    deinit(decoded, testing.allocator);
}

test "roundtrip: complex message" {
    const PhoneType = enum(u8) { mobile = 0, home = 1, work = 2 };
    const Phone = struct {
        pub const _fields = .{
            .number = .{ .number = 1 },
            .phone_type = .{ .number = 2 },
        };
        number: []const u8 = "",
        phone_type: PhoneType = .mobile,
    };
    const Person = struct {
        pub const _fields = .{
            .id = .{ .number = 1 },
            .name = .{ .number = 2 },
            .email = .{ .number = 3 },
            .age = .{ .number = 4 },
            .active = .{ .number = 5 },
            .scores = .{ .number = 6, .encoding = .pack },
            .phone = .{ .number = 7 },
            .nickname = .{ .number = 8 },
        };
        id: u32 = 0,
        name: []const u8 = "",
        email: []const u8 = "",
        age: u32 = 0,
        active: bool = false,
        scores: []const u32 = &.{},
        phone: ?Phone = null,
        nickname: ?[]const u8 = null,
    };

    const original = Person{
        .id = 42,
        .name = "Alice",
        .email = "alice@example.com",
        .age = 30,
        .active = true,
        .scores = &.{ 100, 95, 87 },
        .phone = .{ .number = "555-1234", .phone_type = .work },
        .nickname = "ally",
    };

    const decoded = try roundtrip(Person, original);
    defer deinit(decoded, testing.allocator);

    try testing.expectEqual(42, decoded.id);
    try testing.expectEqualStrings("Alice", decoded.name);
    try testing.expectEqualStrings("alice@example.com", decoded.email);
    try testing.expectEqual(30, decoded.age);
    try testing.expect(decoded.active);
    try testing.expectEqual(3, decoded.scores.len);
    try testing.expectEqual(100, decoded.scores[0]);
    try testing.expectEqual(95, decoded.scores[1]);
    try testing.expectEqual(87, decoded.scores[2]);
    try testing.expectEqualStrings("555-1234", decoded.phone.?.number);
    try testing.expectEqual(.work, decoded.phone.?.phone_type);
    try testing.expectEqualStrings("ally", decoded.nickname.?);
}

test "decodeFromFile roundtrip" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    const io = threaded.io();

    const original = SimpleMsg{ .id = 77, .name = "from file", .active = true };

    // Write via encodeToFile
    try encode_mod.encodeToFile(original, "/tmp/zoto_decode_test.pb", io, .{});

    // Read back via decodeFromFile
    const decoded = try decodeFromFile(SimpleMsg, "/tmp/zoto_decode_test.pb", io, testing.allocator, .{});
    defer deinit(decoded, testing.allocator);

    try testing.expectEqual(77, decoded.id);
    try testing.expectEqualStrings("from file", decoded.name);
    try testing.expect(decoded.active);
}

test "decodeFromFile with custom buffer" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    const io = threaded.io();

    const original = SimpleMsg{ .id = 88, .name = "custom decode buf", .active = false };
    try encode_mod.encodeToFile(original, "/tmp/zoto_decode_custbuf.pb", io, .{});

    var custom_buf: [256]u8 = undefined;
    const decoded = try decodeFromFile(SimpleMsg, "/tmp/zoto_decode_custbuf.pb", io, testing.allocator, .{ .buffer = &custom_buf });
    defer deinit(decoded, testing.allocator);

    try testing.expectEqual(88, decoded.id);
    try testing.expectEqualStrings("custom decode buf", decoded.name);
    try testing.expect(!decoded.active);
}
