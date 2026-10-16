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
    // Be careful when defining optional type positionals
    // parsing is done best effort and if a given arg cant be parsed
    // the positional gets null and the arg is forwarded to the next parser
    // and this is true for all parse errors except for OutOfMemory
    // If for some reason the cursor is never consumed but everything is optional
    // you won't see why the individual parsers failed, you will see (maybe if enabled)
    // a CursorNotDone at the parent parser, because the fields were made optional so it's
    // technically not an error. It's hard to debug so be careful with optional tuple positionals.
    //
    // Example:
    //   for: struct { ?u32, i32 }
    //   args: -1
    //   result:
    //     // Overflow
    //     [0] = null
    //     [1] = -1
    //
    // Example 2:
    //   for: struct { ?u16, u32 }
    //   args: 65536
    //   result:
    //     // Overflow
    //     [0] = null
    //     [1] = 65536
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
    const RemChildTInfo: std.builtin.Type = reminder_check: switch (@typeInfo(Config.ReminderType)) {
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
        const TupleEnum = meta.FieldEnum(TupleT);
        pub const ReminderT = Config.ReminderType;
        const CodecT = Config.CodecType;
        const InnerList = if (RemChildTInfo == .pointer) std.ArrayListUnmanaged(remindChildT()) else void;

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
        reminder: ReminderT = regent.ergo.rotValue(
            ReminderT != void,
            if (@typeInfo(ReminderT) == .optional) null else undefined,
        ),
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
            ReminderOverflow,
            ParseNextCalledForEmptyPositional,
        } ||
            CodecT.Error ||
            CollectError;

        pub const CollectError = error{
            MissingPositionalField,
            ReminderArrayNotFilled,
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
            allocator: Allocator,
            cursor: *CursorT,
        ) Error!void {
            if (comptime TupleT == void and ReminderT == void)
                return Error.ParseNextCalledForEmptyPositional;

            if (comptime ReminderT == void) {
                if (self.tupleCursor >= self.tuple.len)
                    return Error.ParseNextCalledOnTupleEnd;
            } else {
                if ((comptime TupleT == void) or self.tupleCursor >= self.tuple.len) {
                    if (RemChildTInfo == .array)
                        try self.nextReminderBuffered(allocator, cursor)
                    else
                        try self.nextReminder(allocator, cursor);

                    return;
                }
            }

            switch (@as(TupleEnum, @enumFromInt(self.tupleCursor))) {
                inline else => |tupleTTag| {
                    const p = &self.tuple[@intFromEnum(tupleTTag)];
                    const TupleFieldT = @TypeOf(p.*);
                    p.* = self.codec.parseByType(
                        TupleFieldT,
                        .null,
                        allocator,
                        cursor,
                    ) catch |e| v: {
                        if (e == error.OutOfMemory)
                            return e;

                        if (@typeInfo(TupleFieldT) != .optional)
                            return e;
                        break :v null;
                    };
                    self.tupleCursor += 1;
                },
            }
        }

        fn stampMissingFields(self: *@This()) bool {
            if (self.tupleCursor == self.tuple.len)
                return true;

            const fields = @typeInfo(TupleT).@"struct".fields;
            inline for (0.., fields) |i, field| {
                if (i >= self.tupleCursor) {
                    if (@typeInfo(field.type) != .optional)
                        return false;

                    self.tuple[i] = null;
                }
            }

            self.tupleCursor = self.tuple.len;
            return true;
        }

        fn nextReminderBuffered(self: *@This(), allocator: Allocator, cursor: *CursorT) Error!void {
            _ = cursor.peek() orelse return;
            if (self.reminderCursor >= RemChildTInfo.array.len)
                return Error.ReminderOverflow;

            const value = try self.codec.parseByType(
                remindChildT(),
                .null,
                allocator,
                cursor,
            );

            const RTInfo = @typeInfo(ReminderT);
            (if (RTInfo != .optional)
                &self.reminder
            else v: {
                if (self.reminder) |*rem|
                    break :v rem
                else {
                    if (regent.ergo.isDebug)
                        self.reminder = undefined
                    else
                        @as([*]u8, @ptrCast(&self.reminder))[@sizeOf(RTInfo.optional.child)] = 0x01;

                    break :v &self.reminder.?;
                }
            })[self.reminderCursor] = value;
            self.reminderCursor += 1;
        }

        fn nextReminder(self: *@This(), allc: Allocator, cursor: *CursorT) Error!void {
            if (cursor.peek() == null) return;

            const allocator = allc;
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

        pub fn collect(self: *@This(), allocator: Allocator) CollectError!Positionals {
            if ((comptime TupleT != void) and !self.stampMissingFields())
                return CollectError.MissingPositionalField;

            if ((comptime RemChildTInfo == .array) and self.reminderCursor < RemChildTInfo.array.len)
                if (@typeInfo(ReminderT) != .optional or self.reminder != null)
                    return CollectError.ReminderArrayNotFilled;

            const reminder: ReminderT = if (comptime InnerList == void)
                self.reminder
            else v: {
                if (self.reminderCursor == 0) {
                    break :v switch (@typeInfo(ReminderT)) {
                        .optional => null,
                        else => &.{},
                    };
                }
                break :v if (comptime sent_loop: switch (@typeInfo(ReminderT)) {
                    .optional => |opt| continue :sent_loop @typeInfo(opt.child),
                    .array => |arrInfo| arrInfo.sentinel(),
                    .pointer => |pInfo| pInfo.sentinel(),
                    else => null,
                }) |sentinel|
                    try self.list.toOwnedSliceSentinel(allocator, sentinel)
                else
                    try self.list.toOwnedSlice(allocator);
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

    const p = try pos.collect(t.allocator);
    try t.expectEqualDeep(&.{}, p.reminder);

    var pos2: PositionalOf(.{ .ReminderType = ?[]const []const u8 }) = .{};

    const p2 = try pos2.collect(t.allocator);
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

    while (c.peek()) |_| try pos.parseNextType(t.allocator, &c);
    const p = try pos.collect(t.allocator);

    try t.expectEqual(-13, p.tuple[0]);
    try t.expectEqual(false, p.tuple[1]);
    try t.expectEqualDeep(@as([]const u4, &.{ 1, 2, 3 }), &p.tuple[2]);
    const expect: []const []const u8 = &.{ "hello", "world!" };
    try t.expectEqualDeep(expect, &p.reminder);
}

test "parse only buffered reminder" {
    const allocator = t.allocator;

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
    try t.expectError(@TypeOf(pos).Error.ReminderOverflow, pos.parseNextType(allocator, &c));
}

test "parse short buffered reminder" {
    const allocator = t.allocator;
    const Pos = PositionalOf(.{
        .ReminderType = [3][]const u8,
    });

    var pos: Pos = .{};
    var cursor = coll.DebugCursor{ .data = &.{ "a", "b" } };
    var c = cursor.asCursor();
    while (c.peek()) |_| try pos.parseNextType(allocator, &c);
    try t.expectError(Pos.CollectError.ReminderArrayNotFilled, pos.collect(allocator));

    var empty: Pos = .{};
    try t.expectError(Pos.CollectError.ReminderArrayNotFilled, empty.collect(allocator));

    var tupled: PositionalOf(.{
        .TupleType = struct { i32 },
        .ReminderType = [2]u8,
    }) = .{};
    var cursor2 = coll.DebugCursor{ .data = &.{ "1", "x" } };
    var c2 = cursor2.asCursor();
    while (c2.peek()) |_| try tupled.parseNextType(allocator, &c2);
    try t.expectError(@TypeOf(tupled).CollectError.ReminderArrayNotFilled, tupled.collect(allocator));
}

test "parse dynamic reminder" {
    const allocator = t.allocator;

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

    const p = try pos.collect(t.allocator);
    defer allocator.free(p.reminder.?);

    try t.expectEqual({}, p.tuple);
    const expect: []const []const u8 = &.{ "hello", "world!", "ha!" };
    try t.expectEqualDeep(expect, p.reminder.?);
}

test "parse sentinel reminder" {
    const allocator = t.allocator;

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
    const allocator = t.allocator;

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

test "parse tuple with null" {
    const allocator = t.allocator;

    var pos: PositionalOf(.{
        .TupleType = struct { i32, ?i32, ?bool },
        .ReminderType = ?[]const []const u8,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{ "-1", "hello" },
    };
    var c = cursor.asCursor();

    while (c.peek()) |_| try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);
    defer allocator.free(p.reminder.?);

    try t.expectEqual(-1, p.tuple[0]);
    try t.expectEqual(null, p.tuple[1]);
    try t.expectEqual(null, p.tuple[2]);
    try t.expectEqualDeep(@as([]const []const u8, &.{"hello"}), p.reminder.?);
}

test "parse tuple stamps missing trailing optionals" {
    const allocator = t.allocator;

    var pos: PositionalOf(.{ .TupleType = struct { i32, ?i32, ?bool } }) = .{};
    var cursor = coll.DebugCursor{ .data = &.{"1"} };
    var c = cursor.asCursor();
    while (c.peek()) |_| try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);
    try t.expectEqual(1, p.tuple[0]);
    try t.expectEqual(null, p.tuple[1]);
    try t.expectEqual(null, p.tuple[2]);

    var required: PositionalOf(.{ .TupleType = struct { i32, ?i32, u32 } }) = .{};
    cursor = .{ .data = &.{"1"} };
    c = cursor.asCursor();
    while (c.peek()) |_| try required.parseNextType(allocator, &c);
    try t.expectError(
        @TypeOf(required).CollectError.MissingPositionalField,
        required.collect(allocator),
    );
}

test "parse reminder stamp missing array" {
    const allocator = t.allocator;

    var pos: PositionalOf(.{ .ReminderType = ?[1][]const u8 }) = .{};
    var cursor = coll.DebugCursor{ .data = &.{} };
    var c = cursor.asCursor();
    try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);
    try t.expectEqual(null, p.reminder);

    var one: PositionalOf(.{ .ReminderType = ?[1][]const u8 }) = .{};
    cursor = .{ .data = &.{"a"} };
    c = cursor.asCursor();
    while (c.peek()) |_| try one.parseNextType(allocator, &c);
    const p1 = try one.collect(allocator);
    try t.expectEqualDeep([1][]const u8{"a"}, p1.reminder.?);

    var short: PositionalOf(.{ .ReminderType = ?[2][]const u8 }) = .{};
    cursor = .{ .data = &.{"a"} };
    c = cursor.asCursor();
    while (c.peek()) |_| try short.parseNextType(allocator, &c);
    try t.expectError(
        @TypeOf(short).CollectError.ReminderArrayNotFilled,
        short.collect(allocator),
    );
}

test "parse empty positional" {
    const allocator = t.allocator;

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
    const allocator = t.allocator;

    const CustomCodec = struct {
        pub const Error = error{ InvalidType, ParseIntError } || std.fmt.ParseIntError;
        pub fn parseByType(
            self: *const @This(),
            comptime T: type,
            _: anytype,
            allc: std.mem.Allocator,
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
