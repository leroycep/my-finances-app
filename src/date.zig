/// https://en.wikipedia.org/wiki/Julian_day
const std = @import("std");
const testing = std.testing;

pub fn unixTimestampToJulianDayNumber(unix_timestamp: i64) u64 {
    return @as(u64, @intCast(@divFloor(unix_timestamp + std.time.s_per_day / 2, std.time.s_per_day) + 2440587));
}

pub fn julianDayNumberToUnixTimestamp(julian_day_number: u64) i64 {
    const J = @as(i64, @intCast(julian_day_number));
    return (J - 2440587) * std.time.s_per_day - (std.time.s_per_day / 2);
}

pub const DayOfWeek = enum(u3) {
    sun = 0,
    mon = 1,
    tue = 2,
    wed = 3,
    thu = 4,
    fri = 5,
    sat = 6,
};

pub fn julianDayNumberToDayOfWeek(julian_day_number: u64) u3 {
    return @as(u3, @intCast((julian_day_number + 1) % 7));
}

pub const GregorianDate = packed struct {
    /// The year, using astronomical year numbering, meaning 1 BC == 0, 2 BC == -1.
    year: i16,

    /// Month of the year, in the range 1 (January) to 12 (December) inclusive
    month: u4,

    /// Day of the month
    day: u5,

    pub fn fmtISO(this: @This()) FmtISO {
        return FmtISO{ .date = this };
    }

    pub const FmtISO = struct {
        date: GregorianDate,

        pub fn format(
            this: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            if (this.date.year < 0) {
                try writer.print("{:0>4}", .{this.date.year});
            } else {
                try writer.print("{:0>4}", .{@as(u16, @intCast(this.date.year))});
            }
            try writer.print("-{:0>2}-{:0>2}", .{ this.date.month, this.date.day });
        }
    };
};

/// Valid for Gregorian dates after November 23, -4713
pub fn gregorianDateToJulianDayNumber(gregorian_date: GregorianDate) u64 {
    std.debug.assert(gregorian_date.year > -4713 or (gregorian_date.month >= 11 and gregorian_date.day > 23));
    const Y = @as(i65, @intCast(gregorian_date.year));
    const M = @as(i65, @intCast(gregorian_date.month));
    const D = @as(i65, @intCast(gregorian_date.day));

    const m = @divFloor(M - 14, 12);

    const term1 = @divFloor(1461 * (Y + 4800 + m), 4);
    const term2 = @divFloor(367 * (M - 2 - 12 * m), 12);
    const term3 = @divFloor(3 * @divFloor(Y + 4900 + m, 100), 4);

    // 32077 is the constant, wikipedia gave 32075
    return @as(u64, @intCast(term1 + term2 - term3 + D - 32077));
}

pub fn julianDayNumberToGregorianDate(julian_day_number: u64) GregorianDate {
    const J = @as(i64, @intCast(julian_day_number));

    // Parameters from https://en.wikipedia.org/wiki/Julian_day#Julian_or_Gregorian_calendar_from_Julian_day_number
    const y = 4716;
    const j = 1401;
    const m = 2;
    const n = 12;
    const r = 4;
    const p = 1461;
    const v = 3;
    const u = 5;
    const s = 153;
    const w = 2;
    const B = 274277;
    const C = -38;

    const f = J + j + @divFloor(@divFloor(4 * J + B, 146097) * 3, 4) + C;

    const e = r * f + v;
    const g = @divFloor(@mod(e, p), r);
    const h = u * g + w;

    const D = @divFloor(@mod(h, s), u) + 1;
    const M = @mod(@divFloor(h, s) + m, n) + 1;
    const Y = @divFloor(e, p) - y + @divFloor(n + m - M, n);

    return .{
        .year = @as(i16, @intCast(Y)),
        .month = @as(u4, @intCast(M)),
        .day = @as(u5, @intCast(D)),
    };
}

test "from julian day number to gregorian date" {
    try testing.expectEqual(GregorianDate{ .year = -4713, .month = 11, .day = 24 }, julianDayNumberToGregorianDate(0));
    try testing.expectEqual(GregorianDate{ .year = 2000, .month = 1, .day = 1 }, julianDayNumberToGregorianDate(2_451_545));
    try testing.expectEqual(GregorianDate{ .year = 2022, .month = 7, .day = 31 }, julianDayNumberToGregorianDate(2_459_792));
}

test "from gregorian date to julian day number" {
    try testing.expectEqual(@as(u64, 0), gregorianDateToJulianDayNumber(.{ .year = -4713, .month = 11, .day = 24 }));
    try testing.expectEqual(@as(u64, 2_451_545), gregorianDateToJulianDayNumber(.{ .year = 2000, .month = 1, .day = 1 }));
    try testing.expectEqual(@as(u64, 2_459_792), gregorianDateToJulianDayNumber(.{ .year = 2022, .month = 7, .day = 31 }));
}

test "from unix timestamp to julian day number" {
    try testing.expectEqual(@as(u64, 0), unixTimestampToJulianDayNumber(-210866760000));
    try testing.expectEqual(@as(u64, 2_451_545), unixTimestampToJulianDayNumber(946728000));
    try testing.expectEqual(@as(u64, 2_459_792), unixTimestampToJulianDayNumber(1659268800));
}

test "from julian day number to unix timestamp" {
    try testing.expectEqual(@as(i64, -210866760000), julianDayNumberToUnixTimestamp(0));
    try testing.expectEqual(@as(i64, 946728000), julianDayNumberToUnixTimestamp(2_451_545));
    try testing.expectEqual(@as(i64, 1659268800), julianDayNumberToUnixTimestamp(2_459_792));
}

test "from julian day number to day of the week" {
    try testing.expectEqual(@as(u3, 1), julianDayNumberToDayOfWeek(0));
    try testing.expectEqual(@as(u3, 6), julianDayNumberToDayOfWeek(2_451_545));
    try testing.expectEqual(@as(u3, 0), julianDayNumberToDayOfWeek(2_459_792));
}
