const std = @import("std");
const types = @import("types.zig");
const encode_mod = @import("encode.zig");
const decode_mod = @import("decode.zig");

/// Create a protobuf message namespace from a plain struct definition.
/// Fields are auto-numbered 1, 2, 3... in declaration order.
pub fn Message(comptime StructDef: type) type {
    return MessageWith(StructDef, .{});
}

/// Create a protobuf message namespace with per-field overrides.
pub fn MessageWith(comptime StructDef: type, comptime overrides: anytype) type {
    const generated = comptime generateFieldsDecl(StructDef, overrides);
    comptime types.validateFields(StructDef, generated);

    return struct {
        pub const _fields = generated;
        pub const Def = StructDef;

        pub fn encode(msg: StructDef, writer: *std.Io.Writer) !void {
            try encode_mod.encodeFields(StructDef, _fields, msg, writer);
        }

        pub fn encodeToSlice(msg: StructDef, buf: []u8) !usize {
            var writer = std.Io.Writer.fixed(buf);
            try encode_mod.encodeFields(StructDef, _fields, msg, &writer);
            return writer.end;
        }

        pub fn encodedSize(msg: StructDef) usize {
            return encode_mod.encodedFieldsSize(StructDef, _fields, msg);
        }

        pub fn decodeFromSlice(data: []const u8, allocator: std.mem.Allocator) !StructDef {
            var reader = std.Io.Reader.fixed(data);
            return decode_mod.decodeMessage(StructDef, _fields, &reader, @as(usize, data.len), allocator);
        }

        pub fn encodeToFile(msg: StructDef, filename: []const u8, io: std.Io) !void {
            const cwd = std.Io.Dir.cwd();
            const file = try cwd.createFile(io, filename, .{});
            defer file.close(io);
            var write_buf: [4096]u8 = undefined;
            var fw = file.writer(io, &write_buf);
            try encode_mod.encodeFields(StructDef, _fields, msg, &fw.interface);
            try fw.interface.flush();
        }

        pub fn decodeFromFile(filename: []const u8, io: std.Io, allocator: std.mem.Allocator) !StructDef {
            const cwd = std.Io.Dir.cwd();
            const file = try cwd.openFile(io, filename, .{ .mode = .read_only });
            defer file.close(io);
            var read_buf: [4096]u8 = undefined;
            var fr = file.reader(io, &read_buf);
            const data = try fr.interface.allocRemaining(allocator, .unlimited);
            defer allocator.free(data);
            var reader = std.Io.Reader.fixed(data);
            return decode_mod.decodeMessage(StructDef, _fields, &reader, @as(usize, data.len), allocator);
        }

        pub fn deinit(msg: StructDef, allocator: std.mem.Allocator) void {
            decode_mod.deinitWithFields(StructDef, _fields, msg, allocator);
        }
    };
}

/// Build a _fields declaration from a struct definition and optional overrides.
///
/// Pass 1: Collect explicitly-assigned numbers from overrides.
/// Pass 2: Auto-assign remaining fields (1, 2, 3...), skipping claimed numbers.
fn generateFieldsDecl(comptime StructDef: type, comptime overrides: anytype) GeneratedFieldsType(StructDef) {
    const struct_info = @typeInfo(StructDef).@"struct";
    const Override = @TypeOf(overrides);

    // Pass 1: collect explicitly claimed numbers
    var claimed: [struct_info.fields.len]?u32 = .{null} ** struct_info.fields.len;
    for (struct_info.fields, 0..) |sf, i| {
        if (@hasField(Override, sf.name)) {
            const field_override = @field(overrides, sf.name);
            if (@hasField(@TypeOf(field_override), "number")) {
                claimed[i] = field_override.number;
            }
        }
    }

    // Pass 2: auto-assign, skipping claimed numbers
    var next_number: u32 = 1;
    var result: GeneratedFieldsType(StructDef) = undefined;

    inline for (struct_info.fields, 0..) |sf, i| {
        var opts: types.FieldOptions = undefined;

        if (claimed[i]) |num| {
            opts.number = num;
        } else {
            // Find next unclaimed number
            while (isClaimed(claimed, next_number)) {
                next_number += 1;
            }
            opts.number = next_number;
            next_number += 1;
        }

        // Apply encoding/omit_default overrides
        opts.encoding = .default;
        opts.omit_default = true;
        if (@hasField(Override, sf.name)) {
            const field_override = @field(overrides, sf.name);
            if (@hasField(@TypeOf(field_override), "encoding")) {
                opts.encoding = field_override.encoding;
            }
            if (@hasField(@TypeOf(field_override), "omit_default")) {
                opts.omit_default = field_override.omit_default;
            }
        }

        @field(result, sf.name) = opts;
    }

    return result;
}

/// Resolve the fields declaration for any struct type.
/// If T has `pub const _fields`, returns that. Otherwise auto-generates
/// fields numbered 1, 2, 3... in declaration order.
pub fn fieldsFor(comptime T: type) GeneratedFieldsType(T) {
    if (types.isMessage(T)) {
        // T has _fields — convert to our generated type so the return type is uniform
        const fields_decl = T._fields;
        var result: GeneratedFieldsType(T) = undefined;
        inline for (std.meta.fieldNames(T)) |name| {
            @field(result, name) = types.toFieldOptions(@field(fields_decl, name));
        }
        return result;
    }
    return generateFieldsDecl(T, .{});
}

fn isClaimed(claimed: anytype, number: u32) bool {
    for (claimed) |c| {
        if (c) |num| {
            if (num == number) return true;
        }
    }
    return false;
}

/// Build the type for the generated fields declaration.
/// A struct with one FieldOptions entry per field in StructDef, using the
/// same field names.
fn GeneratedFieldsType(comptime StructDef: type) type {
    const struct_info = @typeInfo(StructDef).@"struct";
    var field_types: [struct_info.fields.len]type = undefined;
    var attrs: [struct_info.fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (0..struct_info.fields.len) |i| {
        field_types[i] = types.FieldOptions;
        attrs[i] = .{};
    }
    return @Struct(.auto, null, std.meta.fieldNames(StructDef), &field_types, &attrs);
}

test "Message: auto-numbers fields sequentially" {
    const S = struct { a: u32 = 0, b: []const u8 = "", c: bool = false };
    const M = Message(S);
    try std.testing.expectEqual(1, M._fields.a.number);
    try std.testing.expectEqual(2, M._fields.b.number);
    try std.testing.expectEqual(3, M._fields.c.number);
}

test "Message: default encoding and omit_default" {
    const S = struct { x: u32 = 0 };
    const M = Message(S);
    try std.testing.expectEqual(.default, M._fields.x.encoding);
    try std.testing.expectEqual(true, M._fields.x.omit_default);
}

test "MessageWith: explicit number override" {
    const S = struct { a: u32 = 0, b: u32 = 0, c: u32 = 0 };
    const M = MessageWith(S, .{
        .b = .{ .number = 10 },
    });
    try std.testing.expectEqual(1, M._fields.a.number);
    try std.testing.expectEqual(10, M._fields.b.number);
    try std.testing.expectEqual(2, M._fields.c.number);
}

test "MessageWith: explicit number avoids collision" {
    const S = struct { a: u32 = 0, b: u32 = 0, c: u32 = 0 };
    // b claims number 1, so a should get 2 and c should get 3
    const M = MessageWith(S, .{
        .b = .{ .number = 1 },
    });
    try std.testing.expectEqual(2, M._fields.a.number);
    try std.testing.expectEqual(1, M._fields.b.number);
    try std.testing.expectEqual(3, M._fields.c.number);
}

test "MessageWith: encoding override" {
    const S = struct { score: i32 = 0, tags: []const u32 = &.{} };
    const M = MessageWith(S, .{
        .score = .{ .encoding = .sint },
        .tags = .{ .encoding = .pack },
    });
    try std.testing.expectEqual(.sint, M._fields.score.encoding);
    try std.testing.expectEqual(.pack, M._fields.tags.encoding);
}

test "MessageWith: omit_default override" {
    const S = struct { x: u32 = 0 };
    const M = MessageWith(S, .{
        .x = .{ .omit_default = false },
    });
    try std.testing.expectEqual(false, M._fields.x.omit_default);
}

test "MessageWith: multiple explicit numbers" {
    const S = struct { a: u32 = 0, b: u32 = 0, c: u32 = 0, d: u32 = 0 };
    const M = MessageWith(S, .{
        .a = .{ .number = 5 },
        .c = .{ .number = 10 },
    });
    try std.testing.expectEqual(5, M._fields.a.number);
    try std.testing.expectEqual(1, M._fields.b.number);
    try std.testing.expectEqual(10, M._fields.c.number);
    try std.testing.expectEqual(2, M._fields.d.number);
}

test "fieldsFor: plain struct auto-generates" {
    const S = struct { x: u32 = 0, y: bool = false };
    const fields = comptime fieldsFor(S);
    try std.testing.expectEqual(1, fields.x.number);
    try std.testing.expectEqual(2, fields.y.number);
}

test "fieldsFor: struct with _fields uses declared values" {
    const S = struct {
        pub const _fields = .{
            .x = .{ .number = 10 },
            .y = .{ .number = 20, .encoding = .sint },
        };
        x: u32 = 0,
        y: i32 = 0,
    };
    const fields = comptime fieldsFor(S);
    try std.testing.expectEqual(10, fields.x.number);
    try std.testing.expectEqual(20, fields.y.number);
    try std.testing.expectEqual(.sint, fields.y.encoding);
}

test "Message: encode/decode roundtrip" {
    const S = struct { id: u32 = 0, name: []const u8 = "" };
    const M = Message(S);

    const original: S = .{ .id = 42, .name = "test" };
    var buf: [64]u8 = undefined;
    const n = try M.encodeToSlice(original, &buf);
    try std.testing.expect(n > 0);

    const decoded = try M.decodeFromSlice(buf[0..n], std.testing.allocator);
    defer M.deinit(decoded, std.testing.allocator);

    try std.testing.expectEqual(42, decoded.id);
    try std.testing.expectEqualStrings("test", decoded.name);
}

test "Message: encodedSize matches actual encoded bytes" {
    const S = struct { a: u32 = 0, b: []const u8 = "" };
    const M = Message(S);

    const msg: S = .{ .a = 999, .b = "hello world" };
    const size = M.encodedSize(msg);
    var buf: [64]u8 = undefined;
    const n = try M.encodeToSlice(msg, &buf);
    try std.testing.expectEqual(size, n);
}

test "Message: nested struct roundtrip" {
    const Inner = struct { value: u32 = 0 };
    const Outer = struct { name: []const u8 = "", inner: Inner = .{} };
    const M = Message(Outer);

    const original: Outer = .{ .name = "hello", .inner = .{ .value = 99 } };
    var buf: [64]u8 = undefined;
    const n = try M.encodeToSlice(original, &buf);

    const decoded = try M.decodeFromSlice(buf[0..n], std.testing.allocator);
    defer M.deinit(decoded, std.testing.allocator);

    try std.testing.expectEqualStrings("hello", decoded.name);
    try std.testing.expectEqual(99, decoded.inner.value);
}

test "Message: deeply nested struct roundtrip" {
    const Level2 = struct { val: u32 = 0 };
    const Level1 = struct { name: []const u8 = "", child: Level2 = .{} };
    const Root = struct { tag: []const u8 = "", nested: Level1 = .{} };
    const M = Message(Root);

    const original: Root = .{ .tag = "root", .nested = .{ .name = "mid", .child = .{ .val = 42 } } };
    var buf: [128]u8 = undefined;
    const n = try M.encodeToSlice(original, &buf);

    const decoded = try M.decodeFromSlice(buf[0..n], std.testing.allocator);
    defer M.deinit(decoded, std.testing.allocator);

    try std.testing.expectEqualStrings("root", decoded.tag);
    try std.testing.expectEqualStrings("mid", decoded.nested.name);
    try std.testing.expectEqual(42, decoded.nested.child.val);
}

test "Message: encodeToFile/decodeFromFile roundtrip" {
    const S = struct { id: u32 = 0, name: []const u8 = "" };
    const M = Message(S);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();

    const original: S = .{ .id = 123, .name = "file roundtrip" };
    try M.encodeToFile(original, "/tmp/zoto_msg_test.pb", io);

    const decoded = try M.decodeFromFile("/tmp/zoto_msg_test.pb", io, std.testing.allocator);
    defer M.deinit(decoded, std.testing.allocator);

    try std.testing.expectEqual(123, decoded.id);
    try std.testing.expectEqualStrings("file roundtrip", decoded.name);
}

test "Message: file roundtrip with nested struct" {
    const Inner = struct { val: u32 = 0 };
    const Outer = struct { label: []const u8 = "", child: Inner = .{} };
    const M = Message(Outer);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();

    const original: Outer = .{ .label = "parent", .child = .{ .val = 55 } };
    try M.encodeToFile(original, "/tmp/zoto_msg_nested_test.pb", io);

    const decoded = try M.decodeFromFile("/tmp/zoto_msg_nested_test.pb", io, std.testing.allocator);
    defer M.deinit(decoded, std.testing.allocator);

    try std.testing.expectEqualStrings("parent", decoded.label);
    try std.testing.expectEqual(55, decoded.child.val);
}
