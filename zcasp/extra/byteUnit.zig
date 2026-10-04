const std = @import("std");
const regent = @import("regent");

pub const ByteUnit = struct {
    count: usize,
    unit: usize,

    pub fn size(self: *const @This()) usize {
        return self.count * self.unit;
    }
};

const State = enum {
    firstDigit,
    digits,
    unitToken,
    unitEnd,
};

pub const Error = error{
    UnitSyntaxError,
} || std.fmt.ParseIntError;

pub fn parse(value: []const u8) Error!ByteUnit {
    var i: usize = 0;
    var end: usize = 0;
    var state: State = .firstDigit;
    var unit: usize = 1;

    return stateLoop: while (true) {
        switch (state) {
            .firstDigit,
            => {
                if (i >= value.len) return Error.UnitSyntaxError;
                std.debug.assert(i == 0);
                switch (value[i]) {
                    '0' => {
                        if (value.len > 1) return Error.UnitSyntaxError;
                        return .{
                            .count = 0,
                            .unit = unit,
                        };
                    },
                    '1'...'9' => {
                        state = .digits;
                        continue :stateLoop;
                    },
                    else => return Error.UnitSyntaxError,
                }
            },
            .digits,
            => {
                digitLoop: while (true) {
                    if (i >= value.len) {
                        return .{
                            .count = try std.fmt.parseInt(
                                usize,
                                value[0..],
                                10,
                            ),
                            .unit = unit,
                        };
                    }
                    switch (value[i]) {
                        '0'...'9' => {
                            i += 1;
                            continue :digitLoop;
                        },
                        else => {
                            end = i;
                            state = .unitToken;
                            continue :stateLoop;
                        },
                    }
                }
            },
            .unitToken,
            => {
                if (i >= value.len) return Error.UnitSyntaxError;
                switch (value[i]) {
                    'G', 'g' => {
                        unit = regent.units.ByteUnit.gb;
                        i += 1;
                        state = .unitEnd;
                        continue :stateLoop;
                    },
                    'M', 'm' => {
                        unit = regent.units.ByteUnit.mb;
                        i += 1;
                        state = .unitEnd;
                        continue :stateLoop;
                    },
                    'K', 'k' => {
                        unit = regent.units.ByteUnit.kb;
                        i += 1;
                        state = .unitEnd;
                        continue :stateLoop;
                    },
                    'B', 'b' => {
                        if (i != value.len - 1) return Error.UnitSyntaxError;
                        return .{
                            .count = try std.fmt.parseInt(
                                usize,
                                value[0..end],
                                10,
                            ),
                            .unit = unit,
                        };
                    },
                    else => return Error.UnitSyntaxError,
                }
            },
            .unitEnd,
            => {
                if (i < value.len - 1) return Error.UnitSyntaxError;
                if (i >= value.len) {
                    return .{
                        .count = try std.fmt.parseInt(
                            usize,
                            value[0..end],
                            10,
                        ),
                        .unit = unit,
                    };
                }
                switch (value[i]) {
                    'B',
                    'b',
                    => {
                        return .{
                            .count = try std.fmt.parseInt(
                                usize,
                                value[0..end],
                                10,
                            ),
                            .unit = unit,
                        };
                    },
                    else => return Error.UnitSyntaxError,
                }
            },
        }
    };
}

test "parse plain bytes" {
    const t = std.testing;
    try t.expectEqualDeep(ByteUnit{ .count = 0, .unit = 1 }, try parse("0"));
    try t.expectEqualDeep(ByteUnit{ .count = 7, .unit = 1 }, try parse("7"));
    try t.expectEqualDeep(ByteUnit{ .count = 512, .unit = 1 }, try parse("512"));
    try t.expectEqualDeep(ByteUnit{ .count = 512, .unit = 1 }, try parse("512b"));
    try t.expectEqualDeep(ByteUnit{ .count = 512, .unit = 1 }, try parse("512B"));
}

test "parse units" {
    const t = std.testing;
    const U = regent.units.ByteUnit;
    try t.expectEqualDeep(ByteUnit{ .count = 4, .unit = U.kb }, try parse("4k"));
    try t.expectEqualDeep(ByteUnit{ .count = 4, .unit = U.kb }, try parse("4K"));
    try t.expectEqualDeep(ByteUnit{ .count = 4, .unit = U.kb }, try parse("4kb"));
    try t.expectEqualDeep(ByteUnit{ .count = 4, .unit = U.kb }, try parse("4KB"));
    try t.expectEqualDeep(ByteUnit{ .count = 4, .unit = U.kb }, try parse("4kB"));
    try t.expectEqualDeep(ByteUnit{ .count = 16, .unit = U.mb }, try parse("16m"));
    try t.expectEqualDeep(ByteUnit{ .count = 16, .unit = U.mb }, try parse("16MB"));
    try t.expectEqualDeep(ByteUnit{ .count = 2, .unit = U.gb }, try parse("2g"));
    try t.expectEqualDeep(ByteUnit{ .count = 2, .unit = U.gb }, try parse("2Gb"));
    try t.expectEqualDeep(ByteUnit{ .count = 10, .unit = U.gb }, try parse("10G"));
}

test "byte unit size" {
    const t = std.testing;
    try t.expectEqual(0, (try parse("0")).size());
    try t.expectEqual(512, (try parse("512b")).size());
    try t.expectEqual(4096, (try parse("4k")).size());
    try t.expectEqual(3 << 20, (try parse("3mb")).size());
    try t.expectEqual(1 << 30, (try parse("1G")).size());
}

test "parse byte unit errors" {
    const t = std.testing;
    try t.expectError(Error.UnitSyntaxError, parse(""));
    try t.expectError(Error.UnitSyntaxError, parse("00"));
    try t.expectError(Error.UnitSyntaxError, parse("01"));
    try t.expectError(Error.UnitSyntaxError, parse("0k"));
    try t.expectError(Error.UnitSyntaxError, parse("-1"));
    try t.expectError(Error.UnitSyntaxError, parse("k"));
    try t.expectError(Error.UnitSyntaxError, parse("b"));
    try t.expectError(Error.UnitSyntaxError, parse(" 1"));
    try t.expectError(Error.UnitSyntaxError, parse("1 "));
    try t.expectError(Error.UnitSyntaxError, parse("1x"));
    try t.expectError(Error.UnitSyntaxError, parse("1t"));
    try t.expectError(Error.UnitSyntaxError, parse("12a3"));
    try t.expectError(Error.UnitSyntaxError, parse("1bb"));
    try t.expectError(Error.UnitSyntaxError, parse("1b2"));
    try t.expectError(Error.UnitSyntaxError, parse("1kx"));
    try t.expectError(Error.UnitSyntaxError, parse("1kbb"));
    try t.expectError(Error.UnitSyntaxError, parse("1kk"));
    try t.expectError(Error.UnitSyntaxError, parse("1k2"));
    try t.expectError(Error.Overflow, parse("99999999999999999999999"));
    try t.expectError(Error.Overflow, parse("99999999999999999999999k"));
}
