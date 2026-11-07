const std = @import("std");
const argIter = @import("iterator.zig");
const regent = @import("regent");
const CursorT = regent.collections.Cursor([]const u8);

pub fn FieldBitSet(Spec: type) type {
    const SpecEnumFields = std.meta.FieldEnum(Spec);
    const size = std.meta.fields(Spec).len;
    const BitSet = std.bit_set.StaticBitSet(size);

    return struct {
        bitset: BitSet = BitSet.initEmpty(),

        pub fn fieldSet(self: *@This(), comptime tag: SpecEnumFields) void {
            const i = comptime std.meta.fieldIndex(Spec, @tagName(tag)).?;
            self.bitset.set(i);
        }

        pub fn isFieldSet(self: *const @This(), comptime tag: SpecEnumFields) bool {
            const i = comptime std.meta.fieldIndex(Spec, @tagName(tag)).?;
            return self.bitset.isSet(i);
        }

        pub fn isFieldMissing(self: *const @This(), comptime tag: SpecEnumFields) bool {
            return !self.isFieldSet(tag);
        }

        fn makeMask(comptime tags: []const SpecEnumFields) BitSet {
            var tmp = BitSet.initEmpty();
            for (tags) |tag| {
                const i = std.meta.fieldIndex(Spec, @tagName(tag)).?;
                tmp.set(i);
            }
            return tmp;
        }

        pub fn allOf(self: *const @This(), comptime tags: []const SpecEnumFields) bool {
            return self.bitset.supersetOf(comptime makeMask(tags));
        }

        pub fn count(self: *const @This()) usize {
            return self.bitset.count();
        }

        pub fn countOf(self: *const @This(), comptime tags: []const SpecEnumFields) usize {
            return self.bitset.intersectWith(comptime makeMask(tags)).count();
        }

        pub fn oneOf(self: *const @This(), comptime tags: []const SpecEnumFields) bool {
            return self.countOf(tags) == 1;
        }

        pub fn anyOf(self: *const @This(), comptime tags: []const SpecEnumFields) bool {
            return self.countOf(tags) >= 1;
        }
    };
}

test "track bits for field" {
    const Spec = struct {
        a: i32,
        b: i32,
        c: i32,
    };
    var fbset = FieldBitSet(Spec){};
    fbset.fieldSet(.a);
    fbset.fieldSet(.c);
    try t.expectEqual(5, fbset.bitset.mask);

    try t.expect(fbset.isFieldSet(.a));
    try t.expect(!fbset.isFieldSet(.b));
    try t.expect(fbset.isFieldSet(.c));

    try t.expectEqual(true, fbset.allOf(&.{.a}));
    try t.expectEqual(false, fbset.allOf(&.{.b}));
    try t.expectEqual(true, fbset.allOf(&.{.c}));
    try t.expectEqual(false, fbset.allOf(&.{ .a, .b }));
    try t.expectEqual(true, fbset.allOf(&.{ .a, .c }));
    try t.expectEqual(false, fbset.allOf(&.{ .b, .c }));
    try t.expectEqual(false, fbset.allOf(&.{ .a, .b, .c }));

    try t.expectEqual(true, fbset.oneOf(&.{.a}));
    try t.expectEqual(false, fbset.oneOf(&.{.b}));
    try t.expectEqual(true, fbset.oneOf(&.{.c}));
    try t.expectEqual(true, fbset.oneOf(&.{ .a, .b }));
    try t.expectEqual(false, fbset.oneOf(&.{ .a, .c }));
    try t.expectEqual(true, fbset.oneOf(&.{ .b, .c }));
    try t.expectEqual(false, fbset.oneOf(&.{ .a, .b, .c }));

    try t.expect(!fbset.isFieldMissing(.a));
    try t.expect(fbset.isFieldMissing(.b));

    try t.expectEqual(2, fbset.count());
    try t.expectEqual(0, fbset.countOf(&.{}));
    try t.expectEqual(0, fbset.countOf(&.{.b}));
    try t.expectEqual(1, fbset.countOf(&.{ .a, .b }));
    try t.expectEqual(2, fbset.countOf(&.{ .a, .c }));
    try t.expectEqual(2, fbset.countOf(&.{ .a, .b, .c }));

    try t.expectEqual(false, fbset.anyOf(&.{}));
    try t.expectEqual(false, fbset.anyOf(&.{.b}));
    try t.expectEqual(true, fbset.anyOf(&.{ .a, .b }));
    try t.expectEqual(true, fbset.anyOf(&.{ .a, .c }));
    try t.expectEqual(true, fbset.anyOf(&.{ .a, .b, .c }));
}

pub fn GroupMatchConfig(Spec: type, comptime extra: anytype) type {
    const badFnMessage = std.fmt.comptimePrint(
        "GroupMatch validateFn for {s} has to be void or fn (FieldBitSet(Spec)) returning void or !void, found {s}",
        .{ @typeName(Spec), @typeName(@TypeOf(extra)) },
    );
    const validateFn = switch (@typeInfo(@TypeOf(extra))) {
        .void => struct {
            pub fn validate(_: FieldBitSet(Spec)) void {
                return;
            }
        }.validate,
        .@"fn" => extra,
        else => @compileError(badFnMessage),
    };

    const fnInfo = @typeInfo(@TypeOf(validateFn)).@"fn";
    const R = @typeInfo(fnInfo.return_type orelse @compileError(badFnMessage));
    if (R != .void and !(R == .error_union and R.error_union.payload == void))
        @compileError(badFnMessage);
    const FnE = if (R == .void)
        error{}
    else
        R.error_union.error_set;

    const params = fnInfo.params;
    if (params.len != 1 or
        params[0].type != FieldBitSet(Spec))
        @compileError(badFnMessage);

    return struct {
        mandatoryVerb: bool = false,
        ensureCursorDone: bool = true,
        validateFn: @TypeOf(validateFn) = validateFn,

        pub const Error = FnE;
    };
}

pub fn GroupTracker(Spec: type) type {
    std.debug.assert(@TypeOf(Spec.GroupMatch) == GroupMatchConfig(Spec, Spec.GroupMatch.validateFn));
    return GroupTrackerWithConfig(Spec, Spec.GroupMatch);
}

pub const TrackerError = error{
    MissingVerb,
    CursorNotDone,
    UnknownVerb,
    UnknownPositional,
};

pub fn GroupTrackerWithConfig(Spec: type, comptime config: anytype) type {
    const SpecEnumFields = std.meta.FieldEnum(Spec);

    return struct {
        pub const ValidationError = TrackerError || @TypeOf(config).Error;

        fbset: FieldBitSet(Spec) = .{},
        verbParsed: bool = false,

        pub fn parsed(self: *@This(), comptime tag: SpecEnumFields) void {
            self.fbset.fieldSet(tag);
        }

        pub fn parsedVerb(self: *@This()) void {
            self.verbParsed = true;
        }

        pub fn checkVerb(self: *const @This()) TrackerError!void {
            if (comptime config.mandatoryVerb) {
                if (!self.verbParsed) return error.MissingVerb;
            }
        }

        pub fn checkCursorDone(
            self: *const @This(),
            comptime hasVerbs: bool,
            comptime hasPositionals: bool,
            cursor: *CursorT,
            forcePositionals: bool,
        ) TrackerError!void {
            if (comptime !config.ensureCursorDone) return;
            const leftover = cursor.peek() orelse return;

            const mustBePositional = !hasVerbs or
                self.verbParsed or
                forcePositionals or
                std.mem.startsWith(u8, leftover, "-");
            if (mustBePositional) {
                try self.checkVerb();
                return error.UnknownPositional;
            }

            if (comptime config.mandatoryVerb or !hasPositionals) return error.UnknownVerb;
            return error.CursorNotDone;
        }

        pub fn validate(
            self: *const @This(),
            comptime hasVerbs: bool,
            comptime hasPositionals: bool,
            cursor: *CursorT,
            forcePositionals: bool,
        ) ValidationError!void {
            if (@typeInfo(@FieldType(@TypeOf(config), "validateFn")).@"fn".return_type.? == void)
                config.validateFn(self.fbset)
            else
                try config.validateFn(self.fbset);
            try self.checkCursorDone(
                hasVerbs,
                hasPositionals,
                cursor,
                forcePositionals,
            );
            try self.checkVerb();
        }
    };
}

const t = std.testing;

test "check required fields" {
    const Spec = struct {
        pub const GroupMatch: GroupMatchConfig(@This(), {}) = .{
            .mandatoryVerb = true,
        };
    };
    const done = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };
    const pending = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{"left"} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };

    const dash = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{"-"} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };

    var tracker = GroupTracker(Spec){};

    try t.expectError(error.MissingVerb, tracker.validate(true, false, done, false));
    try t.expectError(error.MissingVerb, tracker.checkVerb());
    try t.expectError(error.UnknownVerb, tracker.validate(true, false, pending, false));
    try t.expectError(error.UnknownVerb, tracker.validate(true, true, pending, false));
    try t.expectError(error.MissingVerb, tracker.validate(true, true, pending, true));
    try t.expectError(error.MissingVerb, tracker.validate(true, false, dash, false));
    tracker.parsedVerb();
    try t.expectEqual({}, try tracker.checkVerb());

    try t.expectError(error.UnknownPositional, tracker.validate(true, false, pending, false));
    try t.expectError(error.UnknownPositional, tracker.checkCursorDone(true, false, pending, false));
    try t.expectEqual({}, try tracker.validate(true, false, done, false));
    try t.expectEqual({}, try tracker.checkCursorDone(true, false, done, false));
}

fn hasError(comptime E: type, comptime name: []const u8) bool {
    const errors = @typeInfo(E).error_set orelse return false;
    for (errors) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

test "untyped group match derives validateFn error set" {
    const Spec = struct {
        a: ?u32 = null,
        b: ?u32 = null,

        fn validateArgs(set: FieldBitSet(@This())) !void {
            if (!set.oneOf(&.{ .a, .b })) return error.NeedExactlyOneOfAB;
        }

        pub const GroupMatch: GroupMatchConfig(@This(), validateArgs) = .{
            .mandatoryVerb = true,
        };
    };
    const Tracker = GroupTracker(Spec);

    comptime {
        std.debug.assert(hasError(Tracker.ValidationError, "NeedExactlyOneOfAB"));
        std.debug.assert(hasError(Tracker.ValidationError, "MissingVerb"));
        std.debug.assert(hasError(Tracker.ValidationError, "CursorNotDone"));
        std.debug.assert(hasError(Tracker.ValidationError, "UnknownVerb"));
        std.debug.assert(hasError(Tracker.ValidationError, "UnknownPositional"));
        std.debug.assert(!hasError(Tracker.ValidationError, "RequiredArgsMissing"));
    }

    const done = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };
    const pending = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{"left"} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };

    var tracker = Tracker{};
    try t.expectError(error.NeedExactlyOneOfAB, tracker.validate(true, false, done, false));
    tracker.parsed(.a);
    try t.expectError(error.MissingVerb, tracker.validate(true, false, done, false));
    tracker.parsedVerb();
    try t.expectError(error.UnknownPositional, tracker.validate(true, false, pending, false));
    try tracker.validate(true, false, done, false);
    tracker.parsed(.b);
    try t.expectError(error.NeedExactlyOneOfAB, tracker.validate(true, false, done, false));
}

test "untyped group match defaults and void validateFn" {
    const done = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };
    const pending = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{"left"} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };
    const dash = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{"-"} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };
    const negative = v: {
        var dcur: regent.collections.DebugCursor = .{ .data = &.{"-5"} };
        var cursor = dcur.asCursor();
        break :v &cursor;
    };

    const NoFn = struct {
        pub const GroupMatch: GroupMatchConfig(@This(), {}) = .{
            .ensureCursorDone = false,
        };
    };
    const NoFnTracker = GroupTracker(NoFn);
    comptime std.debug.assert(NoFnTracker.ValidationError == TrackerError);
    var noFn = NoFnTracker{};
    try noFn.validate(true, false, pending, false);

    const VoidFn = struct {
        x: u8 = 0,
        fn check(_: FieldBitSet(@This())) void {}
        pub const GroupMatch: GroupMatchConfig(@This(), check) = .{};
    };
    const VoidTracker = GroupTracker(VoidFn);
    comptime std.debug.assert(VoidTracker.ValidationError == TrackerError);
    var voidFn = VoidTracker{};
    try t.expectError(error.UnknownVerb, voidFn.validate(true, false, pending, false));
    try t.expectError(error.CursorNotDone, voidFn.validate(true, true, pending, false));
    try t.expectError(error.UnknownPositional, voidFn.validate(false, true, pending, false));
    try t.expectError(error.UnknownPositional, voidFn.validate(true, true, pending, true));
    try t.expectError(error.UnknownPositional, voidFn.validate(true, true, dash, false));
    try t.expectError(error.UnknownPositional, voidFn.validate(true, true, negative, false));
    try voidFn.validate(true, true, done, false);
}

test "typed group match keeps validate.Error" {
    const Spec = struct {
        pub const GroupMatch: GroupMatchConfig(@This(), {}) = .{};
    };
    comptime {
        std.debug.assert(hasError(GroupTracker(Spec).ValidationError, "MissingVerb"));
    }
}
