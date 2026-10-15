const std = @import("std");
const regent = @import("regent");
const coll = regent.collections;
const argIter = @import("iterator.zig");
const Allocator = std.mem.Allocator;
const AtDepthArrayTokenizer = argIter.AtDepthArrayTokenizer;
const AtDepthStructTokenizer = argIter.AtDepthStructTokenizer;
const FieldBitSet = @import("validate.zig").FieldBitSet;
const TstArgCursor = argIter.TstArgCursor;

pub const range = @import("extra/range.zig");
pub const byteUnit = @import("extra/byteUnit.zig");

pub fn ensureTypeTag(comptime T: type, comptime tag: @EnumLiteral()) void {
    comptime if (@typeInfo(T) != tag) @compileError(std.fmt.comptimePrint(
        "Type given to parse method is not {s}, it is {s}",
        .{
            @tagName(tag),
            @typeName(T),
        },
    ));
}

pub fn ensureType(
    comptime T: type,
    comptime OtherT: type,
) void {
    comptime if (T != OtherT) @compileError(std.fmt.comptimePrint(
        "Expected type {s} found {s}",
        .{ @typeName(T), @typeName(OtherT) },
    ));
}

// Tag is passed around but never used by this codec
pub const PrimitiveCodec = struct {
    pub const Error = error{
        ParseArrayEndOfIterator,
        ParseArrayBufferValueSizeMismatch,
        ParseOptEndOfIterator,
        ParseStringEndOfIterator,
        ParseStringBufferValueSizeMismatch,
        ParseEnumEndOfIterator,
        ParseFloatEndOfIterator,
        ParseIntEndOfIterator,
        ParseCharEndOfIterator,
        CharIsBiggerThan1Byte,
        ParseBoolEndOfIterator,
        ParseStructEndOfIterator,
        InvalidEnum,
        InvalidBoolLiteral,
        UnknownStructField,
        MissingStructField,
        DuplicateStructField,
        NestedValueNotConsumed,
    } ||
        AtDepthArrayTokenizer.Error ||
        AtDepthStructTokenizer.Error ||
        std.fmt.ParseIntError ||
        std.fmt.ParseFloatError ||
        std.mem.Allocator.Error;

    pub const CursorT = coll.Cursor([]const u8);

    pub fn parseByType(
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) (Error || std.meta.Child(@TypeOf(codec)).Error)!T {
        const unsupportedMessage: []const u8 = comptime std.fmt.comptimePrint(
            "Codec: {s} - type {s} not supported by codec",
            .{ @typeName(@This()), @typeName(T) },
        );

        if (comptime @TypeOf(codec) != *PrimitiveCodec and @TypeOf(codec) != *const PrimitiveCodec) {
            if (comptime std.meta.Child(@TypeOf(codec)).supports(T, tag)) {
                return try codec.parseByType(T, tag, allocator, cursor);
            }
        }

        return try switch (@typeInfo(T)) {
            .bool => @This().parseBool(cursor),
            .int => rv: {
                if (T == u8) break :rv @This().parseChar(cursor);
                break :rv @This().parseInt(T, cursor);
            },
            .float => @This().parseFloat(T, cursor),
            .@"enum" => @This().parseEnum(T, cursor),
            .pointer => |ptr| rv: {
                if (comptime ptr.size == .one) @compileError(unsupportedMessage);
                if (comptime ptr.child == u8) {
                    break :rv if (ptr.sentinel()) |_| @This().parseStringZ(
                        T,
                        allocator,
                        cursor,
                    ) else @This().parseString(T, cursor);
                } else break :rv @This().parseArray(codec, T, tag, allocator, cursor);
            },
            .array => |arr| if (comptime arr.child == u8)
                @This().parseStringBuffered(
                    T,
                    allocator,
                    cursor,
                )
            else
                @This().parseArrayBuffered(
                    codec,
                    T,
                    tag,
                    allocator,
                    cursor,
                ),
            .optional => @This().parseOpt(codec, T, tag, allocator, cursor),
            .@"struct" => |st| if (comptime st.is_tuple)
                @This().parseTuple(codec, T, tag, allocator, cursor)
            else
                @This().parseStruct(codec, T, tag, allocator, cursor),
            else => @compileError(unsupportedMessage),
        };
    }

    pub fn parseArrayBuffered(
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) (Error || std.meta.Child(@TypeOf(codec)).Error)!T {
        comptime ensureTypeTag(T, .array);
        const PtrT = comptime @typeInfo(T).array;
        const ArrayT = comptime PtrT.child;

        const slice = cursor.next() orelse return Error.ParseArrayEndOfIterator;
        var arrTokenizer = AtDepthArrayTokenizer.init(slice);
        var i: usize = 0;
        var target: T = undefined;
        var nested = coll.UnitCursor([]const u8).asNoneCursor();
        while (try arrTokenizer.next()) |token| {
            if (i >= target.len) return Error.ParseArrayBufferValueSizeMismatch;
            nested.stackItem(token);
            target[i] = try parseByType(codec, ArrayT, tag, allocator, &nested);
            if (nested.peek() != null) return Error.NestedValueNotConsumed;
            i += 1;
        }
        if (i != target.len) return Error.ParseArrayBufferValueSizeMismatch;
        return target;
    }

    pub fn parseArray(
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) (Error || std.meta.Child(@TypeOf(codec)).Error)!T {
        comptime ensureTypeTag(T, .pointer);
        const PtrT = comptime @typeInfo(T).pointer;
        const ArrayT = comptime PtrT.child;

        const allc = allocator.*;

        var array = try std.ArrayListUnmanaged(ArrayT).initCapacity(allc, 8);
        defer array.deinit(allc);

        const slice = cursor.next() orelse return Error.ParseArrayEndOfIterator;
        var arrTokenizer = AtDepthArrayTokenizer.init(slice);
        var nested = coll.UnitCursor([]const u8).asNoneCursor();
        while (try arrTokenizer.next()) |token| {
            nested.stackItem(token);
            try array.append(allc, try parseByType(codec, ArrayT, tag, allocator, &nested));
            if (nested.peek() != null) return Error.NestedValueNotConsumed;
        }

        // ArrayList erases sentinel
        if (PtrT.sentinel()) |sentinel| {
            return array.toOwnedSliceSentinel(allc, sentinel);
        } else {
            return array.toOwnedSlice(allc);
        }
    }

    pub fn parseStruct(
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) (Error || std.meta.Child(@TypeOf(codec)).Error)!T {
        comptime ensureTypeTag(T, .@"struct");
        const fields = comptime @typeInfo(T).@"struct".fields;
        const FieldTag = std.meta.FieldEnum(T);

        const slice = cursor.next() orelse return Error.ParseStructEndOfIterator;
        var structTokenizer = AtDepthStructTokenizer.init(slice);
        var target: T = undefined;
        var parsed: FieldBitSet(T) = .{};
        var nested = coll.UnitCursor([]const u8).asNoneCursor();

        while (try structTokenizer.next()) |field| {
            // map doesnt help much here tbh
            inline for (fields) |f| {
                if (std.mem.eql(u8, f.name, field.key)) {
                    const fieldTag = @field(FieldTag, f.name);
                    if (parsed.isFieldSet(fieldTag)) return Error.DuplicateStructField;
                    nested.stackItem(field.value);
                    @field(target, f.name) = try parseByType(
                        codec,
                        f.type,
                        tag,
                        allocator,
                        &nested,
                    );
                    if (nested.peek() != null) return Error.NestedValueNotConsumed;
                    parsed.fieldSet(fieldTag);
                    break;
                }
            } else return Error.UnknownStructField;
        }

        inline for (fields) |f| {
            if (!parsed.isFieldSet(@field(FieldTag, f.name))) @field(
                target,
                f.name,
            ) = f.defaultValue() orelse return Error.MissingStructField;
        }

        return target;
    }

    pub fn parseTuple(
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) (Error || std.meta.Child(@TypeOf(codec)).Error)!T {
        comptime ensureTypeTag(T, .@"struct");
        const TInfo = @typeInfo(T).@"struct";
        if (!TInfo.is_tuple)
            comptime if (@typeInfo(T) != tag) @compileError(std.fmt.comptimePrint(
                "Type {s} on tag {s} given to parse method is not a tuple, it is a regular struct",
                .{
                    @typeName(T),
                    @tagName(tag),
                },
            ));

        var target: T = undefined;
        inline for (TInfo.fields) |f| {
            @field(target, f.name) = try parseByType(
                codec,
                f.type,
                tag,
                allocator,
                cursor,
            );
        }

        return target;
    }

    pub fn isNull(cursor: *CursorT) bool {
        const s = cursor.peek() orelse return false;
        return std.mem.eql(u8, "null", s);
    }

    pub fn parseOpt(
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) (Error || std.meta.Child(@TypeOf(codec)).Error)!T {
        comptime ensureTypeTag(T, .optional);
        const Tt = comptime @typeInfo(T).optional.child;

        const slice = cursor.peek() orelse return Error.ParseOptEndOfIterator;
        errdefer cursor.stackItem(slice);
        if (isNull(cursor)) {
            cursor.consume();
            return null;
        } else {
            return try parseByType(codec, Tt, tag, allocator, cursor);
        }
    }

    pub fn parseStringBuffered(
        comptime T: type,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) Error!T {
        _ = allocator;
        comptime ensureTypeTag(T, .array);
        const Tt = comptime std.meta.Child(T);
        comptime ensureType(Tt, u8);

        const s = cursor.next() orelse return Error.ParseStringEndOfIterator;
        if (s.len != @typeInfo(T).array.len) return Error.ParseStringBufferValueSizeMismatch;
        return @as(*const T, @ptrCast(@alignCast(s.ptr))).*;
    }

    pub fn parseStringZ(
        comptime T: type,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) Error!T {
        comptime ensureTypeTag(T, .pointer);
        const PtrType = comptime @typeInfo(T).pointer;
        const Tt = comptime std.meta.Child(T);
        comptime ensureType(Tt, u8);
        const sentinel = comptime PtrType.sentinel().?;

        const s = cursor.next() orelse return Error.ParseStringEndOfIterator;
        const newPtr = try allocator.allocSentinel(Tt, s.len, sentinel);
        @memcpy(newPtr, s);
        return newPtr;
    }

    pub fn parseString(
        comptime T: type,
        cursor: *CursorT,
    ) Error!T {
        comptime ensureTypeTag(T, .pointer);
        const PtrType = comptime @typeInfo(T).pointer;
        const Tt = comptime std.meta.Child(T);
        comptime ensureType(Tt, u8);
        comptime if (PtrType.sentinel() != null) @compileError(
            std.fmt.comptimePrint("Sentinel string field sent to string slice parser"),
        );

        return cursor.next() orelse return Error.ParseStringEndOfIterator;
    }

    pub fn parseEnum(
        comptime T: type,
        cursor: *CursorT,
    ) Error!T {
        comptime ensureTypeTag(T, .@"enum");
        const value = cursor.next() orelse return Error.ParseEnumEndOfIterator;
        return std.meta.stringToEnum(T, value) orelse Error.InvalidEnum;
    }

    pub fn parseFloat(comptime T: type, cursor: *CursorT) Error!T {
        comptime ensureTypeTag(T, .float);
        const value = cursor.next() orelse return Error.ParseFloatEndOfIterator;
        return try std.fmt.parseFloat(T, value);
    }

    pub fn parseInt(comptime T: type, cursor: *CursorT) Error!T {
        comptime ensureTypeTag(T, .int);
        const value = cursor.next() orelse return Error.ParseIntEndOfIterator;
        return try std.fmt.parseInt(T, value, 10);
    }

    pub fn parseChar(cursor: *CursorT) Error!u8 {
        const value = cursor.next() orelse return Error.ParseCharEndOfIterator;
        if (value.len > 1) return Error.CharIsBiggerThan1Byte;
        return value[0];
    }

    pub fn parseBool(cursor: *CursorT) Error!bool {
        const value = cursor.next() orelse return Error.ParseBoolEndOfIterator;
        return result: switch (value.len) {
            4 => {
                break :result if (std.mem.eql(u8, "true", value)) true else Error.InvalidBoolLiteral;
            },
            5 => {
                break :result if (std.mem.eql(u8, "false", value)) false else Error.InvalidBoolLiteral;
            },
            else => Error.InvalidBoolLiteral,
        };
    }
};

const t = std.testing;

test "default codec parseBool" {
    const allocator = &t.allocator;
    var tstCursor = try TstArgCursor.init(allocator,
        \\true
        \\false
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    try t.expectEqual(true, try PrimitiveCodec.parseBool(&cursor));
    try t.expectEqual(false, try PrimitiveCodec.parseBool(&cursor));
    try t.expectError(
        PrimitiveCodec.Error.ParseBoolEndOfIterator,
        PrimitiveCodec.parseBool(&cursor),
    );
}

// Tag is only used to ensure ?bool and bool are parsed as flags
pub fn ArgCodec(Spec: type) type {
    return struct {
        pub const Error = PrimitiveCodec.Error;
        pub const CursorT = PrimitiveCodec.CursorT;
        pub const SpecFieldEnum = std.meta.FieldEnum(Spec);

        pub fn supports(
            comptime T: type,
            comptime tag: SpecFieldEnum,
        ) bool {
            // ?bool and bool parse as flag, any other bool-ending type
            // ends up parsed by requiring a bool param
            const FieldType = comptime @FieldType(Spec, @tagName(tag));
            return comptime switch (@typeInfo(T)) {
                .bool, .optional => FieldType == ?bool or FieldType == bool,
                else => false,
            };
        }

        // Test method
        fn parseByTag(
            self: *@This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!@FieldType(Spec, @tagName(tag)) {
            return try self.parseByType(
                @FieldType(Spec, @tagName(tag)),
                tag,
                allocator,
                cursor,
            );
        }

        // This method can be used in a mixin style to handle flags
        // for custom codecs
        pub fn parseByType(
            codec: anytype,
            comptime T: type,
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) (Error || std.meta.Child(@TypeOf(codec)).Error)!T {
            if (comptime !supports(T, tag)) {
                return try PrimitiveCodec.parseByType(codec, T, tag, allocator, cursor);
            }

            return try switch (@typeInfo(T)) {
                .bool => @This().parseFlag(cursor),
                .optional => |opt| switch (@typeInfo(opt.child)) {
                    .bool => @This().parseOpt(codec, tag, allocator, cursor),
                    else => unreachable,
                },
                else => unreachable,
            };
        }

        pub fn parseOpt(
            codec: anytype,
            comptime tag: std.meta.FieldEnum(Spec),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) (Error || std.meta.Child(@TypeOf(codec)).Error)!@FieldType(Spec, @tagName(tag)) {
            const tagT = comptime @FieldType(Spec, @tagName(tag));
            comptime ensureTypeTag(tagT, .optional);

            if (comptime @typeInfo(tagT).optional.child == bool)
                if (PrimitiveCodec.isNull(cursor)) {
                    cursor.consume();
                    return null;
                } else return try @This().parseFlag(
                    cursor,
                )
            else
                return try PrimitiveCodec.parseOpt(
                    codec,
                    tagT,
                    tag,
                    allocator,
                    cursor,
                );
        }

        pub fn parseFlag(
            cursor: *CursorT,
        ) Error!bool {
            const value = cursor.peek() orelse return true;
            return switch (value.len) {
                4 => if (std.mem.eql(u8, "true", value)) consume: {
                    cursor.consume();
                    break :consume true;
                    // INFO: this looks dumb, but the purpose is not to consume the iterator
                    // only when it was explicitly said to be true
                } else true,
                5 => if (std.mem.eql(u8, "false", value)) consume: {
                    cursor.consume();
                    break :consume false;
                } else true,
                else => true,
            };
        }
    };
}

test "codec parseArray caller ownership" {
    const allocator = &t.allocator;
    var tstCursor = try TstArgCursor.init(allocator, "\"[false, true]\"");
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    const Spec = struct {
        b: []const bool,
    };
    var codec = ArgCodec(Spec){};
    const expectBA: []const bool = &.{ false, true };
    const boolArray = try codec.parseByTag(.b, allocator, &cursor);
    // Ownership belongs to caller
    defer allocator.free(boolArray);

    try t.expectEqualDeep(expectBA, boolArray);
}

test "codec parseArray" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\"[false, true]"
        \\"[1, -1]"
        \\"[1.1, -2.2]"
        \\"['a', 'b']"
        \\"['c', 'd']"
        \\"[[3]]"
        \\"[small, medium, large]"
        \\"[false, null]"
        \\"[[false, null]]"
        \\"[[false, null], null]"
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    const Spec = struct {
        b: []const bool,
        i: []const i32,
        f: []const f32,
        s: []const []const u8,
        sz: []const [:0]const u8,
        ad: []const []const i32,
        e: []const Size,
        b2: []const ?bool,
        b3: []const []const ?bool,
        b4: []const ?[]const ?bool,

        const Size = enum {
            small,
            medium,
            large,
        };
    };
    var codec = ArgCodec(Spec){};

    const expectBA: []const bool = &.{ false, true };
    try t.expectEqualDeep(expectBA, try codec.parseByTag(.b, allocator, &cursor));
    const expectIA: []const i32 = &.{ 1, -1 };
    try t.expectEqualDeep(expectIA, try codec.parseByTag(.i, allocator, &cursor));
    const expectFA: []const f32 = &.{ 1.1, -2.2 };
    try t.expectEqualDeep(expectFA, try codec.parseByTag(.f, allocator, &cursor));
    const expectSA: []const []const u8 = &.{ "a", "b" };
    try t.expectEqualDeep(expectSA, try codec.parseByTag(.s, allocator, &cursor));
    const expectSZ: []const [:0]const u8 = &.{ "c", "d" };
    try t.expectEqualDeep(expectSZ, try codec.parseByTag(.sz, allocator, &cursor));
    const expectAD: []const [:0]const i32 = &.{&.{3}};
    try t.expectEqualDeep(expectAD, try codec.parseByTag(.ad, allocator, &cursor));
    const expectED: []const Spec.Size = &.{ .small, .medium, .large };
    try t.expectEqualDeep(expectED, try codec.parseByTag(.e, allocator, &cursor));
    const expectB2: []const ?bool = &.{ false, null };
    try t.expectEqualDeep(expectB2, try codec.parseByTag(.b2, allocator, &cursor));
    const expectB3: []const []const ?bool = &.{&.{ false, null }};
    try t.expectEqualDeep(expectB3, try codec.parseByTag(.b3, allocator, &cursor));
    const expectB4: []const ?[]const ?bool = &.{ &.{ false, null }, null };
    try t.expectEqualDeep(expectB4, try codec.parseByTag(.b4, allocator, &cursor));
    try t.expectError(
        @TypeOf(codec).Error.ParseArrayEndOfIterator,
        codec.parseByTag(.b4, allocator, &cursor),
    );
}

test "codec parse 0 allocation string" {
    const allocator = &t.allocator;
    var tstCursor = try TstArgCursor.init(allocator,
        \\hello
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    var codec = ArgCodec(struct {
        s: [5:0]u8 = undefined,
    }){};
    try t.expectEqualStrings("hello", &(try codec.parseByType([5:0]u8, .s, allocator, &cursor)));
}

test "codec parse 0 allocation array" {
    const allocator = &t.allocator;
    var tstCursor = try TstArgCursor.init(allocator,
        \\"[1,2,3,4]"
        \\null
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    var codec = ArgCodec(struct {
        is1: [4]i32 = undefined,
        is2: ?[4]i32 = undefined,
    }){};

    try t.expectEqualDeep(@as([]const i32, &.{ 1, 2, 3, 4 }), &(try codec.parseByType([4]i32, .is1, allocator, &cursor)));
    try t.expectEqual(null, try codec.parseByType(?[4]i32, .is2, allocator, &cursor));
}

test "codec parseOpt" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\"[[null, true, null], [false], null]"
        \\"[]"
        \\"[[]]"
        \\null
        \\1
        \\null
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    const C = ArgCodec(struct {
        b5: ?[]const ?[]const ?bool,
        b6: ?[]const []bool,
        b7: ?[]const []bool,
        a1: ?f32,
        flag1: ?bool = false,
        flag2: ?bool = null,
    });
    var codec = C{};
    const expectB5: ?[]const ?[]const ?bool = &.{ &.{ null, true, null }, &.{false}, null };
    try t.expectEqualDeep(expectB5, try codec.parseByTag(.b5, allocator, &cursor));
    const expectB6: ?[]const []bool = &.{};
    try t.expectEqualDeep(expectB6, try codec.parseByTag(.b6, allocator, &cursor));
    const expectB7: ?[]const []bool = &.{&.{}};
    try t.expectEqualDeep(expectB7, try codec.parseByTag(.b7, allocator, &cursor));
    try t.expectEqual(null, try codec.parseByTag(.a1, allocator, &cursor));
    try t.expectEqual(1, (try codec.parseByTag(.a1, allocator, &cursor)).?);
    try t.expectEqual(null, try codec.parseByTag(.flag1, allocator, &cursor));
    try t.expect((try codec.parseByTag(.flag2, allocator, &cursor)).?);

    try t.expectError(
        C.Error.ParseOptEndOfIterator,
        codec.parseByTag(.a1, allocator, &cursor),
    );
}

test "codec parseString" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\hello
        \\world
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    var codec = ArgCodec(struct { s1: []const u8, s2: [:0]const u8 }){};
    try t.expectEqualDeep("hello", try codec.parseByTag(.s1, allocator, &cursor));
    try t.expectEqualDeep("world", try codec.parseByTag(.s2, allocator, &cursor));
    try t.expectError(
        @TypeOf(codec).Error.ParseStringEndOfIterator,
        codec.parseByTag(.s2, allocator, &cursor),
    );
}

test "codec parseString caller ownership" {
    const allocator = &t.allocator;
    var tstCursor = try TstArgCursor.init(allocator, "Hello");
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    const Spec = struct {
        // Only sentinels are copied
        s: [:0]const u8,
    };
    var codec = ArgCodec(Spec){};
    const s = try codec.parseByTag(.s, allocator, &cursor);
    // Ownership belongs to caller
    defer allocator.free(s);

    try t.expectEqualDeep("Hello", s);
}

test "codec parseString 0 copy for slice" {
    const allocator = &t.allocator;
    var tstCursor = try TstArgCursor.init(allocator, "Hello");
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    const Spec = struct {
        s: []const u8,
    };
    var codec = ArgCodec(Spec){};
    const s = try codec.parseByTag(.s, allocator, &cursor);

    // NOTE: no leak or free happens, this proves we are using the same
    // data as was allocated for arg cursor
    try t.expectEqualDeep("Hello", s);
}

test "codec parseEnum" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\small
        \\medium
        \\large
        \\invalid
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    const Spec = struct {
        size: Size,

        const Size = enum {
            small,
            medium,
            large,
        };
    };
    var codec = ArgCodec(Spec){};
    try t.expectEqual(Spec.Size.small, try codec.parseByTag(.size, allocator, &cursor));
    try t.expectEqual(Spec.Size.medium, try codec.parseByTag(.size, allocator, &cursor));
    try t.expectEqual(Spec.Size.large, try codec.parseByTag(.size, allocator, &cursor));
    try t.expectError(
        @TypeOf(codec).Error.InvalidEnum,
        codec.parseByTag(.size, allocator, &cursor),
    );
    try t.expectError(
        @TypeOf(codec).Error.ParseEnumEndOfIterator,
        codec.parseByTag(.size, allocator, &cursor),
    );
}

test "codec parseFloat" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\44
        \\-1.2
        \\32.2222
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    var codec = ArgCodec(struct { f1: f32, f2: f64 }){};
    try t.expectEqual(44.0, try codec.parseByTag(.f1, allocator, &cursor));
    try t.expectEqual(-1.2, try codec.parseByTag(.f2, allocator, &cursor));
    try t.expectEqual(32.2222, try codec.parseByTag(.f1, allocator, &cursor));
    try t.expectError(
        @TypeOf(codec).Error.ParseFloatEndOfIterator,
        codec.parseByTag(.f1, allocator, &cursor),
    );
}

test "codec parseInt" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\44
        \\-1
        \\25
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    var codec = ArgCodec(struct { n1: u6, n2: i2, n3: u88 }){};
    try t.expectEqual(44, try codec.parseByTag(.n1, allocator, &cursor));
    try t.expectEqual(-1, try codec.parseByTag(.n2, allocator, &cursor));
    try t.expectEqual(25, try codec.parseByTag(.n3, allocator, &cursor));
    try t.expectError(
        @TypeOf(codec).Error.ParseIntEndOfIterator,
        codec.parseByTag(.n3, allocator, &cursor),
    );
}

test "codec parseChar" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\c
        \\c2
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    var codec = ArgCodec(struct { c: u8 }){};
    try t.expectEqual('c', try codec.parseByTag(.c, allocator, &cursor));
    try t.expectError(
        @TypeOf(codec).Error.CharIsBiggerThan1Byte,
        codec.parseByTag(.c, allocator, &cursor),
    );
    try t.expectError(
        @TypeOf(codec).Error.ParseCharEndOfIterator,
        codec.parseByTag(.c, allocator, &cursor),
    );
}

test "codec parseFlag" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\true
        \\false
        \\"something else"
        \\1234
        \\12345
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    var codec = ArgCodec(struct { @"test": bool }){};
    try t.expect(try codec.parseByTag(.@"test", allocator, &cursor));
    try t.expectEqualDeep(null, cursor.curr);

    try t.expect(!try codec.parseByTag(.@"test", allocator, &cursor));
    try t.expectEqual(null, cursor.curr);

    try t.expect(try codec.parseByTag(.@"test", allocator, &cursor));
    try t.expectEqualStrings("something else", cursor.curr.?);

    // 4 letter guess
    _ = cursor.next();
    try t.expect(try codec.parseByTag(.@"test", allocator, &cursor));
    try t.expectEqualStrings("1234", cursor.curr.?);

    // 5 letter guess
    _ = cursor.next();
    try t.expect(try codec.parseByTag(.@"test", allocator, &cursor));
    try t.expectEqualStrings("12345", cursor.curr.?);

    // null check
    _ = cursor.next();
    try t.expect(try codec.parseByTag(.@"test", allocator, &cursor));
    try t.expectEqual(null, cursor.curr);
}

fn tstParseArg(comptime T: type, allocator: *const Allocator, arg: []const u8) !T {
    return tstParseArgs(T, allocator, &.{arg});
}

fn tstParseArgs(comptime T: type, allocator: *const Allocator, args: []const []const u8) !T {
    const cursor = v: {
        var debugCursor: coll.DebugCursor = .{
            .data = args,
        };
        var cursor = debugCursor.asCursor();
        break :v &cursor;
    };
    var codec: ArgCodec(struct { v: T }) = .{};
    return codec.parseByTag(
        .v,
        allocator,
        cursor,
    );
}

test "codec parseStruct" {
    const baseAllocator = t.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const Size = enum { small, large };
    const Point = struct { x: i32, y: i32 = 0 };
    const Config = struct {
        name: []const u8,
        nameZ: [:0]const u8 = "z",
        tag: [3]u8 = "abc".*,
        c: u8 = 'c',
        n: u16,
        f: f32 = 1.5,
        on: bool = false,
        size: Size = .small,
        maybe: ?i32 = 3,
        list: []const i32 = &.{},
        fixed: [2]i32 = .{ 0, 0 },
        point: Point = .{ .x = 0 },
        points: []const Point = &.{},
        optPoint: ?Point = null,
        nested: []const []const ?bool = &.{},
    };

    const full = try tstParseArg(Config, allocator,
        \\{"name": "zcasp", "nameZ": "zz", "tag": "xyz", "c": "q", "n": 42, "f": -2.25, "on": true, "size": "large", "maybe": null, "list": [1, -2, 3], "fixed": [7, 8], "point": {"x": 1, "y": 2}, "points": [{"x": 3}, {"x": 4, "y": 5}], "optPoint": {"x": 9, "y": 9}, "nested": [[true, null], []]}
    );
    try t.expectEqualStrings("zcasp", full.name);
    try t.expectEqualStrings("zz", full.nameZ);
    try t.expectEqualStrings("xyz", &full.tag);
    try t.expectEqual('q', full.c);
    try t.expectEqual(42, full.n);
    try t.expectEqual(-2.25, full.f);
    try t.expect(full.on);
    try t.expectEqual(Size.large, full.size);
    try t.expectEqual(null, full.maybe);
    try t.expectEqualDeep(@as([]const i32, &.{ 1, -2, 3 }), full.list);
    try t.expectEqual([2]i32{ 7, 8 }, full.fixed);
    try t.expectEqual(Point{ .x = 1, .y = 2 }, full.point);
    try t.expectEqualDeep(@as([]const Point, &.{ .{ .x = 3 }, .{ .x = 4, .y = 5 } }), full.points);
    try t.expectEqual(Point{ .x = 9, .y = 9 }, full.optPoint.?);
    const expectNested: []const []const ?bool = &.{ &.{ true, null }, &.{} };
    try t.expectEqualDeep(expectNested, full.nested);

    const minimal = try tstParseArg(Config, allocator, "{name: hi, n: 1}");
    try t.expectEqualStrings("hi", minimal.name);
    try t.expectEqualStrings("z", minimal.nameZ);
    try t.expectEqualStrings("abc", &minimal.tag);
    try t.expectEqual('c', minimal.c);
    try t.expectEqual(1, minimal.n);
    try t.expectEqual(1.5, minimal.f);
    try t.expect(!minimal.on);
    try t.expectEqual(Size.small, minimal.size);
    try t.expectEqual(3, minimal.maybe.?);
    try t.expectEqual(0, minimal.list.len);
    try t.expectEqual(Point{ .x = 0 }, minimal.point);
    try t.expectEqual(null, minimal.optPoint);

    const singleQuoted = try tstParseArg(Config, allocator, "{'name': 'a, b', 'n': '7', 'list': '[1]'}");
    try t.expectEqualStrings("a, b", singleQuoted.name);
    try t.expectEqual(7, singleQuoted.n);
    try t.expectEqualDeep(@as([]const i32, &.{1}), singleQuoted.list);

    const Empty = struct {};
    try t.expectEqual(Empty{}, try tstParseArg(Empty, allocator, "{}"));
    try t.expectEqual(null, try tstParseArg(?Point, allocator, "null"));
    try t.expectEqual(Point{ .x = -1 }, (try tstParseArg(?Point, allocator, "{x: -1}")).?);
    try t.expectEqualDeep(@as([]const Point, &.{ .{ .x = 1 }, .{ .x = 2, .y = 3 } }), try tstParseArg([]const Point, allocator, "[{\"x\": 1}, {\"x\": 2, \"y\": 3}]"));
    try t.expectEqual([2]Point{ .{ .x = 1 }, .{ .x = 2 } }, try tstParseArg([2]Point, allocator, "[{x: 1}, {x: 2}]"));
    try t.expectEqual('1', (try tstParseArg(struct { a: u8 }, allocator, "{\"a\": 1}")).a);

    const C = ArgCodec(struct {});
    try t.expectError(C.Error.UnknownStructField, tstParseArg(Point, allocator, "{x: 1, z: 1}"));
    try t.expectError(C.Error.MissingStructField, tstParseArg(Point, allocator, "{y: 1}"));
    try t.expectError(C.Error.MissingStructField, tstParseArg(Point, allocator, "{}"));
    try t.expectError(C.Error.DuplicateStructField, tstParseArg(Point, allocator, "{x: 1, x: 2}"));
    try t.expectError(C.Error.InvalidCharacter, tstParseArg(Point, allocator, "{x: one}"));
    try t.expectError(C.Error.InvalidCharacter, tstParseArg(Point, allocator, "{x: [1]}"));
    try t.expectError(C.Error.MissingKeyValueSeparator, tstParseArg(Point, allocator, "{x 1}"));
    try t.expectError(C.Error.MissingStructLayer, tstParseArg(Point, allocator, "x: 1"));
    try t.expectError(C.Error.UnknownStructField, tstParseArg(Config, allocator, "{name: a, n: 1, point: {x: 1, w: 2}}"));
    try t.expectEqualDeep(@as([]const Point, &.{.{ .x = 1 }}), try tstParseArg([]const Point, allocator, "{x: 1}"));
    try t.expectEqualDeep(@as([]const Point, &.{ .{ .x = 1 }, .{ .x = 2, .y = 3 } }), try tstParseArg([]const Point, allocator, "{x: 1}, {\"x\": 2, \"y\": 3},"));
    try t.expectEqual([2]Point{ .{ .x = 1 }, .{ .x = 2 } }, try tstParseArg([2]Point, allocator, "{x: 1},{x: 2}"));
    try t.expectError(C.Error.ParseArrayBufferValueSizeMismatch, tstParseArg([2]Point, allocator, "{x: 1}"));
    try t.expectEqual(null, try tstParseArg(?[]const Point, allocator, "null"));
    try t.expectEqualDeep(@as([]const Point, &.{.{ .x = 7 }}), (try tstParseArg(?[]const Point, allocator, "{x: 7}")).?);
    try t.expectError(C.Error.SyntaxError, tstParseArg([]const Point, allocator, "{x: 1}, 2"));
    try t.expectError(C.Error.ParseArrayBufferValueSizeMismatch, tstParseArg([1]Point, allocator, "[{x: 1}, {x: 2}]"));
    try t.expectError(C.Error.ParseArrayBufferValueSizeMismatch, tstParseArg([2]Point, allocator, "[{x: 1}]"));
    try t.expectError(C.Error.ParseArrayBufferValueSizeMismatch, tstParseArg([3]f32, allocator, "[1, 2]"));
    try t.expectError(C.Error.ParseArrayBufferValueSizeMismatch, tstParseArg([3]f32, allocator, "[]"));
    try t.expectError(C.Error.ParseArrayBufferValueSizeMismatch, tstParseArg(Config, allocator, "{name: a, n: 1, fixed: [1]}"));

    var empty: coll.DebugCursor = .{ .data = &.{} };
    var emptyCursor = empty.asCursor();
    var codec = ArgCodec(struct { v: Point }){};
    try t.expectError(C.Error.ParseStructEndOfIterator, codec.parseByTag(.v, allocator, &emptyCursor));
}

test "parse tuple" {
    const v = try tstParseArgs(
        struct { u8, []const u8, ?u32 },
        &t.allocator,
        &.{ "h", "ello", "5" },
    );

    try t.expectEqual('h', v.@"0");
    try t.expectEqualStrings("ello", v.@"1");
    try t.expectEqual(5, v.@"2");
}

test "codec nested values stay inside their piece" {
    const Pair = struct { u32, []const u8 };
    inline for (.{
        .{ struct { b: Pair, c: u32 }, "{b: 1, c: 2}" },
        .{ []const Pair, "[1, a]" },
        .{ [1]Pair, "[1]" },
    }) |in| try t.expectError(error.ParseStringEndOfIterator, tstParseArgs(in[0], &t.allocator, &.{ in[1], "--next-arg" }));

    const Lazy = struct {
        pub const Error = error{};
        pub fn supports(comptime T: type, comptime _: anytype) bool {
            return T == u32;
        }
        pub fn parseByType(_: *@This(), comptime T: type, comptime _: anytype, _: *const Allocator, _: *PrimitiveCodec.CursorT) Error!T {
            return 7;
        }
    };
    var lazy: Lazy = .{};
    var dcur: coll.DebugCursor = .{ .data = &.{"[1]"} };
    var cursor = dcur.asCursor();
    try t.expectError(error.NestedValueNotConsumed, PrimitiveCodec.parseByType(&lazy, []const u32, .null, &t.allocator, &cursor));
}

test {
    comptime {
        _ = range;
        _ = byteUnit;
    }
}
