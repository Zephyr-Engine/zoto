const encode_mod = @import("encode.zig");
const decode_mod = @import("decode.zig");

pub const wire = @import("wire.zig");

pub const encode = encode_mod.encode;
pub const encodeToSlice = encode_mod.encodeToSlice;
pub const encodeToFile = encode_mod.encodeToFile;
pub const encodedSize = encode_mod.encodedSize;

pub const decode = decode_mod.decode;
pub const decodeFromSlice = decode_mod.decodeFromSlice;
pub const decodeFromFile = decode_mod.decodeFromFile;
pub const deinit = decode_mod.deinit;

pub const FieldOptions = @import("types.zig").FieldOptions;
pub const Encoding = @import("types.zig").Encoding;
pub const isMessage = @import("types.zig").isMessage;
pub const validateMessage = @import("types.zig").validateMessage;
pub const toFieldOptions = @import("types.zig").toFieldOptions;

pub const Message = @import("message.zig").Message;
pub const MessageWith = @import("message.zig").MessageWith;

comptime {
    _ = @import("wire.zig");
    _ = @import("types.zig");
    _ = @import("encode.zig");
    _ = @import("decode.zig");
    _ = @import("message.zig");
}

// ============================================================================
// Integration tests — exercise the full public API
// ============================================================================

const std = @import("std");
const testing = std.testing;

test "public API: old-style _fields encode/decode roundtrip" {
    const Msg = struct {
        pub const _fields = .{
            .x = .{ .number = 1 },
            .y = .{ .number = 2 },
        };
        x: u32 = 0,
        y: []const u8 = "",
    };

    const original = Msg{ .x = 7, .y = "seven" };
    var buf: [64]u8 = undefined;
    const n = try encodeToSlice(original, &buf);
    try testing.expectEqual(encodedSize(original), n);

    const decoded = try decodeFromSlice(Msg, buf[0..n], testing.allocator);
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(7, decoded.x);
    try testing.expectEqualStrings("seven", decoded.y);
}

test "public API: Message() encode/decode roundtrip" {
    const Def = struct { a: u32 = 0, b: []const u8 = "" };
    const M = Message(Def);

    const original: Def = .{ .a = 100, .b = "message api" };
    var buf: [64]u8 = undefined;
    const n = try M.encodeToSlice(original, &buf);

    const decoded = try M.decodeFromSlice(buf[0..n], testing.allocator);
    defer M.deinit(decoded, testing.allocator);
    try testing.expectEqual(100, decoded.a);
    try testing.expectEqualStrings("message api", decoded.b);
}

test "public API: MessageWith() overrides" {
    const Def = struct { id: u32 = 0, score: i32 = 0, tags: []const u32 = &.{} };
    const M = MessageWith(Def, .{
        .score = .{ .encoding = .sint },
        .tags = .{ .encoding = .pack },
        .id = .{ .number = 10 },
    });

    try testing.expectEqual(10, M._fields.id.number);
    try testing.expectEqual(.sint, M._fields.score.encoding);
    try testing.expectEqual(.pack, M._fields.tags.encoding);

    const original: Def = .{ .id = 5, .score = -50, .tags = &.{ 1, 2, 3 } };
    var buf: [64]u8 = undefined;
    const n = try M.encodeToSlice(original, &buf);

    const decoded = try M.decodeFromSlice(buf[0..n], testing.allocator);
    defer M.deinit(decoded, testing.allocator);
    try testing.expectEqual(5, decoded.id);
    try testing.expectEqual(-50, decoded.score);
    try testing.expectEqual(3, decoded.tags.len);
    try testing.expectEqual(1, decoded.tags[0]);
    try testing.expectEqual(2, decoded.tags[1]);
    try testing.expectEqual(3, decoded.tags[2]);
}

test "public API: nested plain struct with Message()" {
    const Inner = struct { val: u32 = 0, label: []const u8 = "" };
    const Outer = struct { name: []const u8 = "", child: Inner = .{} };
    const M = Message(Outer);

    const original: Outer = .{ .name = "parent", .child = .{ .val = 42, .label = "nested" } };
    var buf: [128]u8 = undefined;
    const n = try M.encodeToSlice(original, &buf);

    const decoded = try M.decodeFromSlice(buf[0..n], testing.allocator);
    defer M.deinit(decoded, testing.allocator);
    try testing.expectEqualStrings("parent", decoded.name);
    try testing.expectEqual(42, decoded.child.val);
    try testing.expectEqualStrings("nested", decoded.child.label);
}

test "public API: isMessage" {
    const WithFields = struct {
        pub const _fields = .{ .x = .{ .number = 1 } };
        x: u32 = 0,
    };
    const Plain = struct { x: u32 = 0 };
    try testing.expect(isMessage(WithFields));
    try testing.expect(!isMessage(Plain));
}

test "public API: wire module accessible" {
    // Verify wire sub-module is accessible through the public API
    try testing.expectEqual(0, wire.zigzagEncode(0));
    try testing.expectEqual(1, wire.varintSize(0));
}

test "public API: encodeToFile/decodeFromFile with _fields" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    const io = threaded.io();

    const Msg = struct {
        pub const _fields = .{
            .x = .{ .number = 1 },
            .y = .{ .number = 2 },
        };
        x: u32 = 0,
        y: []const u8 = "",
    };

    const original = Msg{ .x = 42, .y = "file api" };
    try encodeToFile(original, "/tmp/zoto_root_test.pb", io);

    const decoded = try decodeFromFile(Msg, "/tmp/zoto_root_test.pb", io, testing.allocator);
    defer deinit(decoded, testing.allocator);
    try testing.expectEqual(42, decoded.x);
    try testing.expectEqualStrings("file api", decoded.y);
}

test "public API: Message file roundtrip" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    const io = threaded.io();

    const Def = struct { id: u32 = 0, name: []const u8 = "" };
    const M = Message(Def);

    const original: Def = .{ .id = 99, .name = "message file" };
    try M.encodeToFile(original, "/tmp/zoto_root_msg_test.pb", io);

    const decoded = try M.decodeFromFile("/tmp/zoto_root_msg_test.pb", io, testing.allocator);
    defer M.deinit(decoded, testing.allocator);
    try testing.expectEqual(99, decoded.id);
    try testing.expectEqualStrings("message file", decoded.name);
}
