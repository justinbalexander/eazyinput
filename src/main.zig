const std = @import("std");
const assertOrPanic = std.debug.assertOrPanic;

fn cstrNSlice(c_str: ?[*]const u8, n: usize) []const u8 {
    // TODO: how to return const slice only if input was const?
    // check for null pointer input, convert to zero length slice
    var slice: []const u8 = undefined;
    if (c_str) |p| {
        for (p[0..n]) |c,i| {
            if (c == 0) {
                slice = p[0..i];
                break;
            }
        } else {
            slice = p[0..n];
        }
    } else {
        slice = ([]u8{0})[0..0];
    }
    return slice;
}

test "eazyinput.zig: cStrNSlice" {
    const cstr_null: ?[*]const u8 = null;
    const cstr_0: ?[*]const u8 = c"";
    const cstr_1: ?[*]const u8 = c"123456";

    // string is null pointer
    std.debug.assert(std.mem.compare(u8,cstrNSlice(cstr_null,10),""[0..0]) == std.mem.Compare.Equal);
    // null terminator is first byte
    std.debug.assert(std.mem.compare(u8,cstrNSlice(cstr_0,10),""[0..0]) == std.mem.Compare.Equal);
    // null terminator is at "n" index
    std.debug.assert(std.mem.compare(u8, cstrNSlice(cstr_1, 6),"123456"[0..6]) == std.mem.Compare.Equal);
    // null terminator is beyond "n" index
    std.debug.assert(std.mem.compare(u8, cstrNSlice(cstr_1, 5),"123456"[0..5]) == std.mem.Compare.Equal);
    // null terminator is before "n" index
    std.debug.assert(std.mem.compare(u8, cstrNSlice(cstr_1, 7),"123456"[0..6]) == std.mem.Compare.Equal);
}
