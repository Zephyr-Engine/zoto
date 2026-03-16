const std = @import("std");

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    // 3, 4 are deprecated group types
    fixed32 = 5,
};

// ============================================================================
// Varint encoding (LEB128)
// ============================================================================

pub inline fn encodeVarint(writer: *std.Io.Writer, value: u64) !void {
    var v = value;
    while (v > 0x7F) {
        try writer.writeByte(@as(u8, @truncate(v & 0x7F)) | 0x80);
        v >>= 7;
    }
    try writer.writeByte(@as(u8, @truncate(v)));
}

pub inline fn decodeVarint(reader: *std.Io.Reader) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = (try reader.takeArray(1))[0];
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
        shift +|= 7;
        if (shift > 63) return error.MalformedVarint;
    }
}

/// Encode a signed integer using ZigZag encoding (protobuf sint32/sint64).
/// Maps negative values to odd positive values, keeping small absolute values small.
pub inline fn zigzagEncode(value: i64) u64 {
    const v: u64 = @bitCast(value);
    return (v << 1) ^ @as(u64, @bitCast(value >> 63));
}

pub inline fn zigzagDecode(value: u64) i64 {
    return @as(i64, @bitCast((value >> 1) ^ (-%(value & 1))));
}

// ============================================================================
// Tag encoding
// ============================================================================

pub const Tag = struct {
    field_number: u32,
    wire_type: WireType,
};

pub inline fn encodeTag(writer: *std.Io.Writer, field_number: u32, wire_type: WireType) !void {
    const tag_value = (@as(u64, field_number) << 3) | @intFromEnum(wire_type);
    try encodeVarint(writer, tag_value);
}

pub inline fn decodeTag(reader: *std.Io.Reader) !Tag {
    const tag_value = decodeVarint(reader) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return error.MalformedTag,
    };
    const wire_raw: u3 = @truncate(tag_value & 0x7);
    // Validate wire type (3 and 4 are deprecated)
    const wire_type: WireType = switch (wire_raw) {
        0 => .varint,
        1 => .fixed64,
        2 => .length_delimited,
        5 => .fixed32,
        else => return error.UnknownWireType,
    };
    return .{
        .field_number = @intCast(tag_value >> 3),
        .wire_type = wire_type,
    };
}

// ============================================================================
// Varint byte size calculation (for pre-computing lengths)
// ============================================================================

pub inline fn varintSize(value: u64) usize {
    if (value == 0) return 1;
    // Number of bits needed, divided by 7, rounded up
    const bits = 64 - @clz(value);
    return (bits + 6) / 7;
}

pub inline fn tagSize(field_number: u32) usize {
    return varintSize(@as(u64, field_number) << 3);
}

// ============================================================================
// Skip unknown fields (forward compatibility)
// ============================================================================

pub fn skipField(reader: *std.Io.Reader, wire_type: WireType) !usize {
    var bytes_skipped: usize = 0;
    switch (wire_type) {
        .varint => {
            const v = try decodeVarint(reader);
            bytes_skipped += varintSize(v);
        },
        .fixed64 => {
            try reader.discardAll(8);
            bytes_skipped += 8;
        },
        .fixed32 => {
            try reader.discardAll(4);
            bytes_skipped += 4;
        },
        .length_delimited => {
            const len = try decodeVarint(reader);
            bytes_skipped += varintSize(len);
            if (len > std.math.maxInt(usize)) return error.MessageTooLarge;
            try reader.discardAll(@intCast(len));
            bytes_skipped += @intCast(len);
        },
    }
    return bytes_skipped;
}

// ============================================================================
// Raw field writers (no comptime magic, just wire format)
// ============================================================================

pub inline fn writeVarintField(writer: *std.Io.Writer, field_number: u32, value: u64) !void {
    try encodeTag(writer, field_number, .varint);
    try encodeVarint(writer, value);
}

pub inline fn writeFixed32Field(writer: *std.Io.Writer, field_number: u32, bytes: [4]u8) !void {
    try encodeTag(writer, field_number, .fixed32);
    try writer.writeAll(&bytes);
}

pub inline fn writeFixed64Field(writer: *std.Io.Writer, field_number: u32, bytes: [8]u8) !void {
    try encodeTag(writer, field_number, .fixed64);
    try writer.writeAll(&bytes);
}

pub inline fn writeBytesField(writer: *std.Io.Writer, field_number: u32, data: []const u8) !void {
    try encodeTag(writer, field_number, .length_delimited);
    try encodeVarint(writer, data.len);
    try writer.writeAll(data);
}

fn testWriter(buf: []u8) std.Io.Writer {
    return std.Io.Writer.fixed(buf);
}

fn testReader(data: []const u8) std.Io.Reader {
    return std.Io.Reader.fixed(data);
}

test "varint encode/decode roundtrip" {
    const values = [_]u64{ 0, 1, 127, 128, 255, 256, 16383, 16384, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF };
    for (values) |v| {
        var buf: [10]u8 = undefined;
        var w = testWriter(&buf);
        try encodeVarint(&w, v);
        const written = w.end;

        var r = testReader(buf[0..written]);
        const decoded = try decodeVarint(&r);
        try std.testing.expectEqual(v, decoded);
    }
}

test "varint zero encodes to single byte" {
    var buf: [10]u8 = undefined;
    var w = testWriter(&buf);
    try encodeVarint(&w, 0);
    try std.testing.expectEqual(1, w.end);
    try std.testing.expectEqual(0, buf[0]);
}

test "varint 300 encodes to two bytes" {
    var buf: [10]u8 = undefined;
    var w = testWriter(&buf);
    try encodeVarint(&w, 300);
    try std.testing.expectEqual(2, w.end);
    // 300 = 0b100101100 -> 0xAC 0x02
    try std.testing.expectEqual(0xAC, buf[0]);
    try std.testing.expectEqual(0x02, buf[1]);
}

test "varintSize" {
    try std.testing.expectEqual(1, varintSize(0));
    try std.testing.expectEqual(1, varintSize(1));
    try std.testing.expectEqual(1, varintSize(127));
    try std.testing.expectEqual(2, varintSize(128));
    try std.testing.expectEqual(2, varintSize(16383));
    try std.testing.expectEqual(3, varintSize(16384));
    try std.testing.expectEqual(5, varintSize(0xFFFFFFFF));
    try std.testing.expectEqual(10, varintSize(0xFFFFFFFFFFFFFFFF));
}

test "zigzag encode/decode roundtrip" {
    const values = [_]i64{ 0, -1, 1, -2, 2, 2147483647, -2147483648, std.math.maxInt(i64), std.math.minInt(i64) };
    for (values) |v| {
        const encoded = zigzagEncode(v);
        const decoded = zigzagDecode(encoded);
        try std.testing.expectEqual(v, decoded);
    }
}

test "zigzag known encodings" {
    // protobuf spec: 0->0, -1->1, 1->2, -2->3, 2->4
    try std.testing.expectEqual(0, zigzagEncode(0));
    try std.testing.expectEqual(1, zigzagEncode(-1));
    try std.testing.expectEqual(2, zigzagEncode(1));
    try std.testing.expectEqual(3, zigzagEncode(-2));
    try std.testing.expectEqual(4, zigzagEncode(2));
}

test "tag encode/decode roundtrip" {
    const cases = [_]struct { num: u32, wt: WireType }{
        .{ .num = 1, .wt = .varint },
        .{ .num = 2, .wt = .length_delimited },
        .{ .num = 15, .wt = .fixed32 },
        .{ .num = 16, .wt = .fixed64 },
        .{ .num = 1000, .wt = .varint },
        .{ .num = 536870911, .wt = .varint },
    };
    for (cases) |c| {
        var buf: [10]u8 = undefined;
        var w = testWriter(&buf);
        try encodeTag(&w, c.num, c.wt);
        var r = testReader(buf[0..w.end]);
        const tag = try decodeTag(&r);
        try std.testing.expectEqual(c.num, tag.field_number);
        try std.testing.expectEqual(c.wt, tag.wire_type);
    }
}

test "tagSize" {
    try std.testing.expectEqual(1, tagSize(1)); // (1 << 3) = 8, fits in 1 varint byte
    try std.testing.expectEqual(1, tagSize(15)); // (15 << 3) = 120, fits in 1 byte
    try std.testing.expectEqual(2, tagSize(16)); // (16 << 3) = 128, needs 2 bytes
}

test "skipField varint" {
    var buf: [10]u8 = undefined;
    var w = testWriter(&buf);
    try encodeVarint(&w, 300);
    var r = testReader(buf[0..w.end]);
    const skipped = try skipField(&r, .varint);
    try std.testing.expectEqual(w.end, skipped);
}

test "skipField fixed32" {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    var r = testReader(&buf);
    const skipped = try skipField(&r, .fixed32);
    try std.testing.expectEqual(4, skipped);
}

test "skipField fixed64" {
    var buf: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var r = testReader(&buf);
    const skipped = try skipField(&r, .fixed64);
    try std.testing.expectEqual(8, skipped);
}

test "skipField length_delimited" {
    var buf: [20]u8 = undefined;
    var w = testWriter(&buf);
    try encodeVarint(&w, 5); // length prefix
    try w.writeAll("hello");
    var r = testReader(buf[0..w.end]);
    const skipped = try skipField(&r, .length_delimited);
    try std.testing.expectEqual(w.end, skipped);
}

test "writeVarintField" {
    var buf: [20]u8 = undefined;
    var w = testWriter(&buf);
    try writeVarintField(&w, 1, 150);
    var r = testReader(buf[0..w.end]);
    const tag = try decodeTag(&r);
    try std.testing.expectEqual(1, tag.field_number);
    try std.testing.expectEqual(.varint, tag.wire_type);
    const val = try decodeVarint(&r);
    try std.testing.expectEqual(150, val);
}

test "writeFixed32Field" {
    var buf: [20]u8 = undefined;
    var w = testWriter(&buf);
    const bytes: [4]u8 = @bitCast(@as(u32, 42));
    try writeFixed32Field(&w, 3, bytes);
    var r = testReader(buf[0..w.end]);
    const tag = try decodeTag(&r);
    try std.testing.expectEqual(3, tag.field_number);
    try std.testing.expectEqual(.fixed32, tag.wire_type);
    const raw = try r.takeArray(4);
    try std.testing.expectEqual(42, @as(u32, @bitCast(raw.*)));
}

test "writeFixed64Field" {
    var buf: [20]u8 = undefined;
    var w = testWriter(&buf);
    const bytes: [8]u8 = @bitCast(@as(u64, 123456789));
    try writeFixed64Field(&w, 2, bytes);
    var r = testReader(buf[0..w.end]);
    const tag = try decodeTag(&r);
    try std.testing.expectEqual(2, tag.field_number);
    try std.testing.expectEqual(.fixed64, tag.wire_type);
    const raw = try r.takeArray(8);
    try std.testing.expectEqual(123456789, @as(u64, @bitCast(raw.*)));
}

test "writeBytesField" {
    var buf: [30]u8 = undefined;
    var w = testWriter(&buf);
    try writeBytesField(&w, 5, "hello");
    var r = testReader(buf[0..w.end]);
    const tag = try decodeTag(&r);
    try std.testing.expectEqual(5, tag.field_number);
    try std.testing.expectEqual(.length_delimited, tag.wire_type);
    const len = try decodeVarint(&r);
    try std.testing.expectEqual(5, len);
}
