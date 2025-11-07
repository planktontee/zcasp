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

// TODO: add tests
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
                if (i != value.len - 1) return Error.UnitSyntaxError;
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
