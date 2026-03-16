# zoto (Zephyr Proto)

Comptime protobuf encoding/decoding for Zig. Define your schema as plain Zig structs — no `.proto` files, no code generation.

Designed for the [Zephyr Game Engine](https://github.com/Zephyr-Engine/zephyr) but fully standalone — usable in any Zig project that needs binary serialization.

## Features

- **No codegen** — define schemas as plain Zig structs, wire format is derived at comptime.
- **Auto-numbered fields** — `Message()` assigns protobuf field numbers 1, 2, 3... in declaration order.
- **Recursive nested structs** — nested structs are handled automatically, no per-type annotations needed.
- **Field overrides** — `MessageWith()` lets you override field numbers, encoding, and default-omission behavior.
- **Packed repeated fields** — `.pack` encoding for numeric slices.
- **File I/O** — `encodeToFile` / `decodeFromFile` with buffered I/O via `std.Io`.
- **Zero dependencies** — built entirely on `std`.

## Requirements

- Zig 0.16+

## Installing

Add zoto as a dependency in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/Zephyr-Engine/zoto.git
```

Then in your `build.zig`:

```zig
const zoto_dep = b.dependency("zoto", .{
    .target = target,
    .optimize = optimize,
});
const zoto_mod = zoto_dep.module("zoto");
exe.root_module.addImport("zoto", zoto_mod);
```

## Running the example

```sh
cd examples/person
zig build run
```

## Running tests

```sh
zig build test --summary all
```

## Usage

### Defining a message

Wrap a plain Zig struct with `zoto.Message()`. Fields are auto-numbered 1, 2, 3... in declaration order:

```zig
const zoto = @import("zoto");

const PersonDef = struct {
    name: []const u8 = "",
    age: u32 = 0,
    active: bool = false,
};

const Person = zoto.Message(PersonDef);
```

### Nested structs

Nested structs work automatically — no annotations needed at any level:

```zig
const PhoneNumber = struct {
    number: []const u8 = "",
    phone_type: PhoneType = .mobile,
};

const PersonDef = struct {
    name: []const u8 = "",
    phone: ?PhoneNumber = null,
};

const Person = zoto.Message(PersonDef);
```

### Field overrides

Use `zoto.MessageWith()` to override field numbers, encoding, or default-omission:

```zig
const Person = zoto.MessageWith(PersonDef, .{
    .scores = .{ .encoding = .pack },
    .id = .{ .number = 10 },
    .score = .{ .encoding = .sint },
    .always_send = .{ .omit_default = false },
});
```

### Manual field declarations

You can also declare `_fields` directly on a struct for full control:

```zig
const Msg = struct {
    pub const _fields = .{
        .x = .{ .number = 1 },
        .y = .{ .number = 2, .encoding = .sint },
    };
    x: u32 = 0,
    y: i32 = 0,
};
```

### Encoding

```zig
const msg: PersonDef = .{ .name = "Alice", .age = 30 };

// To a slice
var buf: [256]u8 = undefined;
const n = try Person.encodeToSlice(msg, &buf);

// To a file
try Person.encodeToFile(msg, "person.pb", io, .{});

// To a writer
try Person.encode(msg, writer);

// Check encoded size without encoding
const size = Person.encodedSize(msg);
```

### Decoding

```zig
// From a slice
const decoded = try Person.decodeFromSlice(buf[0..n], allocator);
defer Person.deinit(decoded, allocator);

// From a file
const decoded = try Person.decodeFromFile("person.pb", io, allocator, .{});
defer Person.deinit(decoded, allocator);
```

## Supported types

| Zig Type | Wire Format | Notes |
|---|---|---|
| `u8`..`u64` | varint | Override with `.fixed` for fixed-width |
| `i8`..`i64` | varint | Override with `.sint` (zigzag) or `.sfixed` |
| `f32` | fixed32 | |
| `f64` | fixed64 | |
| `bool` | varint | |
| `[]const u8` | length-delimited | Bytes/string |
| `[]const T` | repeated | Override with `.pack` for packed encoding |
| `?T` | optional | Omitted when null |
| `enum(uN)` | varint | |
| `struct` | length-delimited | Sub-message, recursive |

## Encoding options

| Encoding | Description |
|---|---|
| `.default` | Inferred from Zig type |
| `.sint` | ZigZag encoding for signed integers (efficient for negative values) |
| `.fixed` | Fixed-width unsigned (always 4 or 8 bytes) |
| `.sfixed` | Fixed-width signed (always 4 or 8 bytes) |
| `.pack` | Packed repeated field (single length-delimited block) |

## File I/O options

File-based encode/decode accept a `FileOptions` struct:

```zig
// Default: uses a 4096-byte stack buffer for I/O
try Person.encodeToFile(msg, "person.pb", io, .{});

// Custom I/O buffer
var buf: [8192]u8 = undefined;
try Person.encodeToFile(msg, "person.pb", io, .{ .buffer = &buf });
```

The buffer is for I/O buffering (reducing syscalls), not a message size limit. Messages larger than the buffer are handled correctly — the buffered writer/reader flushes and refills as needed.
