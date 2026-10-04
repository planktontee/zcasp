const std = @import("std");
const argIter = @import("iterator.zig");

pub fn FieldBitSet(Spec: type) type {
    const SpecEnumFields = std.meta.FieldEnum(Spec);
    const size = std.meta.fields(Spec).len;
    const BitSet = std.bit_set.StaticBitSet(size);

    return struct {
        bitset: BitSet = BitSet.initEmpty(),

        pub fn fieldSet(self: *@This(), comptime tag: SpecEnumFields) void {
            const i = comptime std.meta.fieldIndex(Spec, @tagName(tag)) orelse @compileError(std.fmt.comptimePrint(
                "Invalid tag {s} for Spec {s}",
                .{ @tagName(tag), @typeName(Spec) },
            ));
            self.bitset.set(i);
        }

        pub fn isFieldSet(self: *const @This(), comptime tag: SpecEnumFields) bool {
            const i = comptime std.meta.fieldIndex(Spec, @tagName(tag)) orelse @compileError(std.fmt.comptimePrint(
                "Invalid tag {s} for Spec {s}",
                .{ @tagName(tag), @typeName(Spec) },
            ));
            return self.bitset.isSet(i);
        }

        fn makeMask(comptime tags: anytype) BitSet {
            var tmp = BitSet.initEmpty();
            for (tags) |tag| {
                const i = std.meta.fieldIndex(Spec, @tagName(tag)) orelse @compileError(std.fmt.comptimePrint(
                    "Invalid tag {s} for Spec {s}",
                    .{ @tagName(tag), @typeName(Spec) },
                ));
                tmp.set(i);
            }
            return tmp;
        }

        pub fn allOf(self: *const @This(), comptime tags: anytype) bool {
            return self.bitset.supersetOf(comptime makeMask(tags));
        }

        pub fn oneOf(self: *const @This(), comptime tags: anytype) bool {
            return self.bitset.intersectWith(comptime makeMask(tags)).count() == 1;
        }
    };
}

test "track bits for field" {
    const t = std.testing;
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

    try t.expectEqual(true, fbset.allOf(.{.a}));
    try t.expectEqual(false, fbset.allOf(.{.b}));
    try t.expectEqual(true, fbset.allOf(.{.c}));
    try t.expectEqual(false, fbset.allOf(.{ .a, .b }));
    try t.expectEqual(true, fbset.allOf(.{ .a, .c }));
    try t.expectEqual(false, fbset.allOf(.{ .b, .c }));
    try t.expectEqual(false, fbset.allOf(.{ .a, .b, .c }));

    try t.expectEqual(true, fbset.oneOf(.{.a}));
    try t.expectEqual(false, fbset.oneOf(.{.b}));
    try t.expectEqual(true, fbset.oneOf(.{.c}));
    try t.expectEqual(true, fbset.oneOf(.{ .a, .b }));
    try t.expectEqual(false, fbset.oneOf(.{ .a, .c }));
    try t.expectEqual(true, fbset.oneOf(.{ .b, .c }));
    try t.expectEqual(false, fbset.oneOf(.{ .a, .b, .c }));
}

pub fn GroupMatchConfig(Spec: type, comptime extra: anytype) type {
    const validateFn = switch (@typeInfo(@TypeOf(extra))) {
        .void => struct {
            pub fn validate(_: FieldBitSet(Spec)) void {
                return;
            }
        }.validate,
        .@"fn" => extra,
        else => @compileError("extra has to be void or an fn of type: fn (FieldBitSet(Spec)) anyerror!void, or void return"),
    };

    const fnInfo = @typeInfo(@TypeOf(validateFn)).@"fn";
    const R = @typeInfo(fnInfo.return_type.?);
    std.debug.assert(R == .void or (R == .error_union and R.error_union.payload == void));
    const FnE = if (R == .void)
        error{}
    else
        R.error_union.error_set;

    const params = fnInfo.params;
    std.debug.assert(params.len == 1);
    std.debug.assert(params[0].type.? == FieldBitSet(Spec));

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
};

pub fn GroupTrackerWithConfig(Spec: type, comptime config: anytype) type {
    const SpecEnumFields = std.meta.FieldEnum(Spec);

    return struct {
        pub const ValidationError = TrackerError || @TypeOf(config).Error;

        fbset: FieldBitSet(Spec) = .{},
        verb: bool = false,
        cursorDoneFlag: bool = false,

        pub fn parsed(self: *@This(), comptime tag: SpecEnumFields) void {
            self.fbset.fieldSet(tag);
        }

        pub fn parsedVerb(self: *@This()) void {
            self.verb = true;
        }

        pub fn cursorDone(self: *@This()) void {
            self.cursorDoneFlag = true;
        }

        pub fn checkVerb(self: *const @This()) TrackerError!void {
            if (comptime config.mandatoryVerb) {
                if (!self.verb) return error.MissingVerb;
            }
        }

        pub fn checkCursorDone(self: *const @This()) TrackerError!void {
            if (comptime config.ensureCursorDone) {
                if (!self.cursorDoneFlag) return error.CursorNotDone;
            }
        }

        pub fn validate(self: *const @This()) ValidationError!void {
            if (@typeInfo(@FieldType(@TypeOf(config), "validateFn")).@"fn".return_type.? == void)
                config.validateFn(self.fbset)
            else
                try config.validateFn(self.fbset);
            try self.checkVerb();
            try self.checkCursorDone();
        }
    };
}

test "check required fields" {
    const t = std.testing;
    const Spec = struct {
        pub const GroupMatch: GroupMatchConfig(@This(), {}) = .{
            .mandatoryVerb = true,
        };
    };

    var tracker = GroupTracker(Spec){};

    try t.expectError(error.MissingVerb, tracker.validate());
    try t.expectError(error.MissingVerb, tracker.checkVerb());
    tracker.parsedVerb();
    try t.expectEqual({}, try tracker.checkVerb());

    try t.expectError(error.CursorNotDone, tracker.validate());
    try t.expectError(error.CursorNotDone, tracker.checkCursorDone());
    tracker.cursorDone();
    try t.expectEqual({}, try tracker.validate());
    try t.expectEqual({}, try tracker.checkCursorDone());
}

fn hasError(comptime E: type, comptime name: []const u8) bool {
    const errors = @typeInfo(E).error_set orelse return false;
    for (errors) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

test "untyped group match derives validateFn error set" {
    const t = std.testing;
    const Spec = struct {
        a: ?u32 = null,
        b: ?u32 = null,

        fn validateArgs(set: FieldBitSet(@This())) !void {
            if (!set.oneOf(.{ .a, .b })) return error.NeedExactlyOneOfAB;
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
        std.debug.assert(!hasError(Tracker.ValidationError, "RequiredArgsMissing"));
    }

    var tracker = Tracker{};
    try t.expectError(error.NeedExactlyOneOfAB, tracker.validate());
    tracker.parsed(.a);
    try t.expectError(error.MissingVerb, tracker.validate());
    tracker.parsedVerb();
    try t.expectError(error.CursorNotDone, tracker.validate());
    tracker.cursorDone();
    try tracker.validate();
    tracker.parsed(.b);
    try t.expectError(error.NeedExactlyOneOfAB, tracker.validate());
}

test "untyped group match defaults and void validateFn" {
    const t = std.testing;
    const NoFn = struct {
        pub const GroupMatch: GroupMatchConfig(@This(), {}) = .{
            .ensureCursorDone = false,
        };
    };
    const NoFnTracker = GroupTracker(NoFn);
    comptime std.debug.assert(NoFnTracker.ValidationError == TrackerError);
    var noFn = NoFnTracker{};
    try noFn.validate();

    const VoidFn = struct {
        x: u8 = 0,
        fn check(_: FieldBitSet(@This())) void {}
        pub const GroupMatch: GroupMatchConfig(@This(), check) = .{};
    };
    const VoidTracker = GroupTracker(VoidFn);
    comptime std.debug.assert(VoidTracker.ValidationError == TrackerError);
    var voidFn = VoidTracker{};
    try t.expectError(error.CursorNotDone, voidFn.validate());
    voidFn.cursorDone();
    try voidFn.validate();
}

test "typed group match keeps validate.Error" {
    const Spec = struct {
        pub const GroupMatch: GroupMatchConfig(@This(), {}) = .{};
    };
    comptime {
        std.debug.assert(hasError(GroupTracker(Spec).ValidationError, "MissingVerb"));
    }
}
