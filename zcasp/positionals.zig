const std = @import("std");
const regent = @import("regent");
const meta = regent.meta;
const argCodec = @import("codec.zig");
const coll = regent.collections;
const argIter = @import("iterator.zig");
const Allocator = std.mem.Allocator;
const PrimitiveCodec = argCodec.PrimitiveCodec;
const TstArgCursor = argIter.TstArgCursor;
const Array = regent.meta.Array;
const Optional = regent.meta.Optional;
const Pointer = regent.meta.Pointer;

pub const PositionalConfig = struct {
    TupleType: type = void,
    ReminderType: type = void,
    CodecType: type = PrimitiveCodec,
};

// NOTE: this is meant to be used with an arena, not owned by this object
// the only case this allocates in heap is for dynamic arrays or sentinel slices
pub fn PositionalOf(comptime Config: PositionalConfig) type {
    const badTupleTMessage = std.fmt.comptimePrint(
        "Invalid Positional tuple type: {s}, type must be either a tuple or void",
        .{@typeName(Config.TupleType)},
    );
    switch (@typeInfo(Config.TupleType)) {
        .void => {},
        .@"struct" => |sInfo| if (!sInfo.is_tuple)
            @compileError(badTupleTMessage),
        else => @compileError(badTupleTMessage),
    }

    const unsupportedMessage = comptime std.fmt.comptimePrint(
        "Unsupported Reminder type {s}, it has to be a collection",
        .{@typeName(Config.ReminderType)},
    );
    const ReminderTInfo: std.builtin.Type = reminder_check: switch (@typeInfo(Config.ReminderType)) {
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .array, .pointer => continue :reminder_check @typeInfo(opt.child),
            else => @compileError(unsupportedMessage),
        },
        .array => |arrT| .{ .array = arrT },
        .pointer => |pT| .{ .pointer = pT },
        .void => .void,
        else => @compileError(unsupportedMessage),
    };

    return struct {
        pub const TupleT = Config.TupleType;
        pub const ReminderT = Config.ReminderType;
        const CodecT = Config.CodecType;
        const InnerList = if (ReminderTInfo == .pointer) std.ArrayListUnmanaged(remindChildT()) else void;

        fn remindChildT() type {
            return rfd: switch (@typeInfo(ReminderT)) {
                .optional => |opt| continue :rfd @typeInfo(opt.child),
                .array => |arr| arr.child,
                .pointer => |ptr| ptr.child,
                else => @compileError(std.fmt.comptimePrint(
                    "Unsupported Reminder type {s}, it has to be a collection",
                    .{@typeName(ReminderT)},
                )),
            };
        }

        tuple: TupleT = regent.ergo.rotValue(TupleT != void, undefined),
        reminder: ReminderT = regent.ergo.rotValue(ReminderT != void, undefined),
        list: InnerList = regent.ergo.rotValue(InnerList != void, undefined),
        tupleCursor: usize = 0,
        reminderCursor: usize = 0,
        codec: CodecT = .{},

        pub const Positionals = struct {
            tuple: TupleT,
            reminder: ReminderT,
        };

        pub const CursorT = coll.Cursor([]const u8);
        pub const Error = error{
            ParseNextCalledOnTupleEnd,
            ReminderBufferShorterThanArgs,
            ParseNextCalledForEmptyPositional,
        } ||
            CodecT.Error ||
            CollectError;

        pub const CollectError = error{
            MissingPositionalField,
            ReminderBufferLongerThanArgs,
        } || std.mem.Allocator.Error;

        // TODO: test this
        pub fn hasNext(self: *const @This()) bool {
            if (comptime TupleT == void and ReminderT == void) return false;
            if (comptime TupleT != void and ReminderT == void) {
                return self.tupleCursor < self.tuple.len;
            } else {
                return true;
            }
        }

        pub fn parseNextType(
            self: *@This(),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!void {
            if (comptime TupleT == void and ReminderT == void) return Error.ParseNextCalledForEmptyPositional;
            if (comptime ReminderT == void) {
                if (self.tupleCursor >= self.tuple.len) return Error.ParseNextCalledOnTupleEnd;
            } else {
                if ((comptime TupleT == void) or self.tupleCursor >= self.tuple.len) {
                    if (ReminderTInfo == .array) {
                        try self.nextReminderBuffered(allocator, cursor);
                    } else {
                        try self.nextReminder(allocator, cursor);
                    }
                    return;
                }
            }
            const TupleEnum = meta.FieldEnum(TupleT);
            switch (@as(TupleEnum, @enumFromInt(self.tupleCursor))) {
                inline else => |idx| {
                    self.tuple[@intFromEnum(idx)] = try self.codec.parseByType(
                        @TypeOf(self.tuple[@intFromEnum(idx)]),
                        .null,
                        allocator,
                        cursor,
                    );
                    self.tupleCursor += 1;
                },
            }
        }

        fn nextReminderBuffered(self: *@This(), allocator: *const Allocator, cursor: *CursorT) Error!void {
            _ = cursor.peek() orelse return;

            if (self.reminderCursor >= self.reminder.len) return Error.ReminderBufferShorterThanArgs;

            self.reminder[self.reminderCursor] = try self.codec.parseByType(
                remindChildT(),
                .null,
                allocator,
                cursor,
            );
            self.reminderCursor += 1;
        }

        fn nextReminder(self: *@This(), allc: *const Allocator, cursor: *CursorT) Error!void {
            if (cursor.peek() == null) return;

            const allocator = allc.*;
            if (self.reminderCursor == 0) {
                if (comptime InnerList == void) {
                    @compileError("Unsupported call to nextReminder with non inner list");
                } else {
                    self.list = try std.ArrayListUnmanaged(remindChildT()).initCapacity(allocator, 8);
                }
            }

            const result = try self.codec.parseByType(
                remindChildT(),
                .null,
                allc,
                cursor,
            );

            try self.list.append(allocator, result);
            self.reminderCursor += 1;
        }

        pub fn collect(self: *@This(), allocator: *const Allocator) CollectError!Positionals {
            if ((comptime TupleT != void) and self.tupleCursor < self.tuple.len) return CollectError.MissingPositionalField;
            if ((comptime @typeInfo(ReminderT) == .array) and self.reminderCursor < self.reminder.len) return CollectError.ReminderBufferLongerThanArgs;
            const reminder: ReminderT = if (comptime InnerList == void) self.reminder else rv: {
                if (self.reminderCursor == 0) {
                    break :rv switch (@typeInfo(ReminderT)) {
                        .optional => null,
                        else => &.{},
                    };
                }
                break :rv if (comptime rfd: switch (@typeInfo(ReminderT)) {
                    .optional => |opt| continue :rfd @typeInfo(opt.child),
                    .array => |arrInfo| arrInfo.sentinel(),
                    .pointer => |pInfo| pInfo.sentinel(),
                    else => null,
                }) |sentinel|
                    try self.list.toOwnedSliceSentinel(allocator.*, sentinel)
                else
                    try self.list.toOwnedSlice(allocator.*);
            };
            return .{
                .tuple = self.tuple,
                .reminder = reminder,
            };
        }
    };
}

const t = std.testing;

test "empty reminder" {
    var pos: PositionalOf(.{
        .ReminderType = []const []const u8,
    }) = .{};

    const p = try pos.collect(&t.allocator);
    try t.expectEqualDeep(&.{}, p.reminder);

    var pos2: PositionalOf(.{ .ReminderType = ?[]const []const u8 }) = .{};

    const p2 = try pos2.collect(&t.allocator);
    try t.expectEqual(null, p2.reminder);
}

test "parse positionals tuple" {
    var pos: PositionalOf(.{
        .TupleType = struct { i32, bool, [3]u4 },
        .ReminderType = [2][]const u8,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{
            "-13",
            "false",
            "[1,2,3]",
            "hello",
            "world!",
        },
    };
    var c = cursor.asCursor();

    while (c.peek()) |_| try pos.parseNextType(&t.allocator, &c);
    const p = try pos.collect(&t.allocator);

    try t.expectEqual(-13, p.tuple[0]);
    try t.expectEqual(false, p.tuple[1]);
    try t.expectEqualDeep(@as([]const u4, &.{ 1, 2, 3 }), &p.tuple[2]);
    const expect: []const []const u8 = &.{ "hello", "world!" };
    try t.expectEqualDeep(expect, &p.reminder);
}

test "parse only buffered reminder" {
    const allocator = &t.allocator;

    var pos: PositionalOf(.{
        .ReminderType = [2][]const u8,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{
            "hello",
            "world!",
            "ha!",
        },
    };
    var c = cursor.asCursor();

    for (0..2) |_| try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);

    try t.expectEqual({}, p.tuple);
    const expect: []const []const u8 = &.{ "hello", "world!" };
    try t.expectEqualDeep(expect, &p.reminder);
    try t.expectError(@TypeOf(pos).Error.ReminderBufferShorterThanArgs, pos.parseNextType(allocator, &c));
}

test "parse short buffered reminder" {
    const allocator = &t.allocator;
    const Pos = PositionalOf(.{
        .ReminderType = [3][]const u8,
    });

    var pos: Pos = .{};
    var cursor = coll.DebugCursor{ .data = &.{ "a", "b" } };
    var c = cursor.asCursor();
    while (c.peek()) |_| try pos.parseNextType(allocator, &c);
    try t.expectError(Pos.CollectError.ReminderBufferLongerThanArgs, pos.collect(allocator));

    var empty: Pos = .{};
    try t.expectError(Pos.CollectError.ReminderBufferLongerThanArgs, empty.collect(allocator));

    var tupled: PositionalOf(.{
        .TupleType = struct { i32 },
        .ReminderType = [2]u8,
    }) = .{};
    var cursor2 = coll.DebugCursor{ .data = &.{ "1", "x" } };
    var c2 = cursor2.asCursor();
    while (c2.peek()) |_| try tupled.parseNextType(allocator, &c2);
    try t.expectError(@TypeOf(tupled).CollectError.ReminderBufferLongerThanArgs, tupled.collect(allocator));
}

test "parse dynamic reminder" {
    const allocator = &t.allocator;

    var pos: PositionalOf(.{ .ReminderType = ?[]const []const u8 }) = .{};
    var cursor = coll.DebugCursor{
        .data = &.{
            "hello",
            "world!",
            "ha!",
        },
    };
    var c = cursor.asCursor();

    while (c.peek()) |_| try pos.parseNextType(allocator, &c);

    const p = try pos.collect(&t.allocator);
    defer allocator.free(p.reminder.?);

    try t.expectEqual({}, p.tuple);
    const expect: []const []const u8 = &.{ "hello", "world!", "ha!" };
    try t.expectEqualDeep(expect, p.reminder.?);
}

test "parse sentinel reminder" {
    const allocator = &t.allocator;

    inline for (.{ [:0]const i32, ?[:0]const i32 }) |R| {
        var pos: PositionalOf(.{ .ReminderType = R }) = .{};
        var cursor = coll.DebugCursor{ .data = &.{ "1", "2" } };
        var c = cursor.asCursor();
        while (c.peek()) |_| try pos.parseNextType(allocator, &c);

        const p = try pos.collect(allocator);
        const reminder: [:0]const i32 = if (@typeInfo(R) == .optional) p.reminder.? else p.reminder;
        defer allocator.free(reminder);
        try t.expectEqualSlices(i32, &.{ 1, 2 }, reminder);
        try t.expectEqual(0, reminder[reminder.len]);
    }

    var empty: PositionalOf(.{ .ReminderType = [:0]const i32 }) = .{};
    const p = try empty.collect(allocator);
    try t.expectEqual(0, p.reminder.len);
    try t.expectEqual(0, p.reminder[p.reminder.len]);
}

test "parse tuple only" {
    const allocator = &t.allocator;

    var pos: PositionalOf(.{
        .TupleType = struct { i32, bool, [3]u4 },
        .ReminderType = void,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{
            "-13",
            "false",
            "[1,2,3]",
            "hello",
            "world!",
        },
    };
    var c = cursor.asCursor();

    for (0..3) |_| try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);

    try t.expectEqual(-13, p.tuple[0]);
    try t.expectEqual(false, p.tuple[1]);
    try t.expectEqualDeep(@as([]const u4, &.{ 1, 2, 3 }), &p.tuple[2]);
    try t.expectError(@TypeOf(pos).Error.ParseNextCalledOnTupleEnd, pos.parseNextType(allocator, &c));
    try t.expectEqual({}, p.reminder);
}

test "parse empty positional" {
    const allocator = &t.allocator;

    var cursor = coll.DebugCursor{
        .data = &.{},
    };
    var c = cursor.asCursor();

    var pos: PositionalOf(.{
        .TupleType = void,
        .ReminderType = void,
    }) = .{};
    try t.expectError(@TypeOf(pos).Error.ParseNextCalledForEmptyPositional, pos.parseNextType(allocator, &c));

    const p = try pos.collect(allocator);
    try t.expectEqual({}, p.reminder);
    try t.expectEqual({}, p.tuple);
}

test "custom codec doubles i32 tuple input" {
    const allocator = &t.allocator;

    const CustomCodec = struct {
        pub const Error = error{ InvalidType, ParseIntError } || std.fmt.ParseIntError;
        pub fn parseByType(
            self: *const @This(),
            comptime T: type,
            _: anytype,
            allc: *const std.mem.Allocator,
            cursor: *coll.Cursor([]const u8),
        ) Error!T {
            _ = self;
            _ = allc;
            if (T != i32) return Error.InvalidType;
            const s = cursor.next() orelse return Error.ParseIntError;
            const val: i32 = try std.fmt.parseInt(i32, s, 10);
            return val * 2;
        }
    };

    var pos: PositionalOf(.{
        .TupleType = struct { i32 },
        .ReminderType = void,
        .CodecType = CustomCodec,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{"4"},
    };
    var c = cursor.asCursor();

    try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);

    try t.expectEqual(@as(i32, 8), p.tuple[0]);
}
