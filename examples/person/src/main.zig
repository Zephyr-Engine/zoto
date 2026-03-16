const std = @import("std");
const zoto = @import("zoto");

const PhoneType = enum(u8) {
    mobile = 0,
    home = 1,
    work = 2,
};

const PhoneNumber = struct {
    number: []const u8 = "",
    phone_type: PhoneType = .mobile,
};

const PersonDef = struct {
    id: u32 = 0,
    name: []const u8 = "",
    email: []const u8 = "",
    age: u32 = 0,
    active: bool = false,
    scores: []const u32 = &.{},
    phone: ?PhoneNumber = null,
    nickname: ?[]const u8 = null,
};

const Person = zoto.MessageWith(PersonDef, .{
    .scores = .{ .encoding = .pack },
});

const filename = "person.pb";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const person: PersonDef = .{
        .id = 42,
        .name = "Alice",
        .email = "alice@example.com",
        .age = 30,
        .active = true,
        .scores = &.{ 100, 95, 87 },
        .phone = .{ .number = "555-1234", .phone_type = .work },
        .nickname = "ally",
    };

    // Encode directly to file
    try Person.encodeToFile(person, filename, io);
    try stdout.print("Wrote {d} bytes to {s}\n", .{ Person.encodedSize(person), filename });
    try stdout.flush();

    // Decode directly from file
    const decoded = try Person.decodeFromFile(filename, io, init.gpa);
    defer Person.deinit(decoded, init.gpa);

    try stdout.print("Read back from {s}\n\n", .{filename});
    try stdout.print("Person:\n", .{});
    try stdout.print("  id:       {d}\n", .{decoded.id});
    try stdout.print("  name:     {s}\n", .{decoded.name});
    try stdout.print("  email:    {s}\n", .{decoded.email});
    try stdout.print("  age:      {d}\n", .{decoded.age});
    try stdout.print("  active:   {}\n", .{decoded.active});
    try stdout.print("  scores:  ", .{});
    for (decoded.scores) |s| {
        try stdout.print(" {d}", .{s});
    }
    try stdout.print("\n", .{});
    if (decoded.phone) |phone| {
        try stdout.print("  phone:    {s} ({s})\n", .{ phone.number, @tagName(phone.phone_type) });
    }
    if (decoded.nickname) |nick| {
        try stdout.print("  nickname: {s}\n", .{nick});
    }
    try stdout.flush();
}
