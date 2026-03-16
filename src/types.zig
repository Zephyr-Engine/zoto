/// Schema annotation types for zephyr-proto.
///
/// Users annotate their Zig structs to define protobuf schemas without
/// a separate .proto file or code generation step.
const std = @import("std");

pub const Encoding = enum {
    /// Default: inferred from Zig type.
    default,

    /// Signed integers using ZigZag encoding (sint32/sint64).
    /// Use when values are frequently negative.
    sint,

    /// Fixed-width signed (sfixed32/sfixed64). Always 4 or 8 bytes.
    /// Faster encode/decode, better when values are large/random.
    sfixed,

    /// Fixed-width unsigned (fixed32/fixed64).
    fixed,

    /// Packed repeated field. Encodes a slice as a single
    /// length-delimited field instead of one tag per element.
    /// Only valid for numeric repeated fields.
    pack,
};

/// Field descriptor, provided via `pub const _fields` on a struct.
pub const FieldOptions = struct {
    /// Protobuf field number (1-536870911). Must be unique per message.
    number: u32,

    /// Encoding strategy. Default infers from Zig type:
    ///   u32/u64       -> varint
    ///   i32/i64       -> varint (standard encoding, not zigzag)
    ///   f32           -> fixed32
    ///   f64           -> fixed64
    ///   bool          -> varint
    ///   []const u8    -> length_delimited (bytes/string)
    ///   []const T     -> repeated (one tag per element)
    ///   enum          -> varint
    ///   struct        -> length_delimited sub-message
    ///   ?T            -> optional (omitted when null)
    encoding: Encoding = .default,

    /// If true, field is omitted when it holds its default value.
    /// Enabled by default (standard protobuf3 behavior).
    omit_default: bool = true,
};

/// Convert an anonymous struct field descriptor into a FieldOptions.
/// Handles the case where users write `.{ .number = 1 }` without explicit type.
pub fn toFieldOptions(comptime anon: anytype) FieldOptions {
    var opts = FieldOptions{ .number = anon.number };
    if (@hasField(@TypeOf(anon), "encoding")) opts.encoding = anon.encoding;
    if (@hasField(@TypeOf(anon), "omit_default")) opts.omit_default = anon.omit_default;
    return opts;
}

/// Check if a type has _fields declarations (is a protobuf message).
pub fn isMessage(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "_fields");
}

/// Get the FieldOptions for a given struct field, or null if not annotated.
pub fn getFieldOptions(comptime T: type, comptime field_name: []const u8) ?FieldOptions {
    if (!@hasDecl(T, "_fields")) return null;
    const fields = T._fields;
    if (@hasField(@TypeOf(fields), field_name)) {
        return toFieldOptions(@field(fields, field_name));
    }
    return null;
}

/// Validate fields_decl against a struct type at comptime.
/// Accepts the fields declaration as a parameter so it can be used both
/// for types with `pub const _fields` and for generated fields from Message().
pub fn validateFields(comptime T: type, comptime fields_decl: anytype) void {
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("Protobuf message must be a struct, got " ++ @typeName(T)),
    };

    // Check every annotated field exists in the struct
    inline for (std.meta.fieldNames(@TypeOf(fields_decl))) |name| {
        var found = false;
        inline for (struct_info.fields) |sf| {
            if (std.mem.eql(u8, sf.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("_fields references non-existent field '" ++ name ++ "' on " ++ @typeName(T));
        }
    }

    // Check for duplicate field numbers
    const field_names = std.meta.fieldNames(@TypeOf(fields_decl));
    for (field_names, 0..) |name_a, i| {
        const num_a = @field(fields_decl, name_a).number;
        for (field_names[i + 1 ..]) |name_b| {
            const num_b = @field(fields_decl, name_b).number;
            if (num_a == num_b) {
                @compileError(std.fmt.comptimePrint(
                    "Duplicate field number {d} on '{s}' and '{s}' in {s}",
                    .{ num_a, name_a, name_b, @typeName(T) },
                ));
            }
        }
    }
}

/// Validate a message type at comptime. Called once per type during
/// encoder/decoder generation.
pub fn validateMessage(comptime T: type) void {
    if (!@hasDecl(T, "_fields")) {
        @compileError("Type '" ++ @typeName(T) ++ "' is missing pub const _fields declaration");
    }
    validateFields(T, T._fields);
}

test "toFieldOptions: number only" {
    const opts = toFieldOptions(.{ .number = 5 });
    try std.testing.expectEqual(5, opts.number);
    try std.testing.expectEqual(.default, opts.encoding);
    try std.testing.expectEqual(true, opts.omit_default);
}

test "toFieldOptions: with encoding" {
    const opts = toFieldOptions(.{ .number = 3, .encoding = .sint });
    try std.testing.expectEqual(3, opts.number);
    try std.testing.expectEqual(.sint, opts.encoding);
    try std.testing.expectEqual(true, opts.omit_default);
}

test "toFieldOptions: with omit_default false" {
    const opts = toFieldOptions(.{ .number = 1, .omit_default = false });
    try std.testing.expectEqual(1, opts.number);
    try std.testing.expectEqual(false, opts.omit_default);
}

test "toFieldOptions: all overrides" {
    const opts = toFieldOptions(.{ .number = 10, .encoding = .pack, .omit_default = false });
    try std.testing.expectEqual(10, opts.number);
    try std.testing.expectEqual(.pack, opts.encoding);
    try std.testing.expectEqual(false, opts.omit_default);
}

test "isMessage: struct with _fields" {
    const Msg = struct {
        pub const _fields = .{
            .x = .{ .number = 1 },
        };
        x: u32 = 0,
    };
    try std.testing.expect(isMessage(Msg));
}

test "isMessage: plain struct" {
    const Plain = struct { x: u32 = 0 };
    try std.testing.expect(!isMessage(Plain));
}

test "isMessage: non-struct" {
    try std.testing.expect(!isMessage(u32));
    try std.testing.expect(!isMessage(bool));
}

test "getFieldOptions: annotated field" {
    const Msg = struct {
        pub const _fields = .{
            .x = .{ .number = 1 },
            .y = .{ .number = 2, .encoding = .sint },
        };
        x: u32 = 0,
        y: i32 = 0,
    };
    const x_opts = getFieldOptions(Msg, "x");
    try std.testing.expect(x_opts != null);
    try std.testing.expectEqual(1, x_opts.?.number);

    const y_opts = getFieldOptions(Msg, "y");
    try std.testing.expect(y_opts != null);
    try std.testing.expectEqual(.sint, y_opts.?.encoding);
}

test "getFieldOptions: non-message type" {
    const Plain = struct { x: u32 = 0 };
    try std.testing.expectEqual(null, getFieldOptions(Plain, "x"));
}

test "validateFields: valid fields" {
    const S = struct { a: u32 = 0, b: []const u8 = "" };
    const fields = .{
        .a = FieldOptions{ .number = 1 },
        .b = FieldOptions{ .number = 2 },
    };
    // Should not compile-error
    comptime validateFields(S, fields);
}

test "validateMessage: valid message" {
    const Msg = struct {
        pub const _fields = .{
            .x = .{ .number = 1 },
        };
        x: u32 = 0,
    };
    comptime validateMessage(Msg);
}
