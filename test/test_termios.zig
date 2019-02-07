const std = @import("std");
const termios = @import("../src/termios.zig");

test "termios.zig: basic call of functions" {
    const std_in = try std.io.getStdIn();
    const std_out = try std.io.getStdOut();

    var termios_raw: termios.Termios = undefined;
    var termios_1: termios.Termios = undefined;
    var termios_2: termios.Termios = undefined;

    try termios.tcgetattr((try std.io.getStdOut()).handle, &termios_1);
    try termios.tcgetattr((try std.io.getStdOut()).handle, &termios_2);

    try termios.tcgetattr((try std.io.getStdOut()).handle, &termios_raw);
    termios.cfmakeraw(&termios_raw);
    std.debug.assert(!std.meta.eql(termios_raw, termios_1));

    try termios.cfsetospeed(&termios_1,termios.cfgetospeed(&termios_2));
    std.debug.assert(std.meta.eql(termios_1, termios_2));

    try termios.cfsetispeed(&termios_1, termios.cfgetispeed(&termios_2));
    std.debug.assert(std.meta.eql(termios_1, termios_2));

    // set to raw mode, check values were correctly applied
    try termios.tcsetattr(std_in.handle, termios.TCSAFLUSH, &termios_raw);
    try termios.tcgetattr(std_out.handle, &termios_1);
    std.debug.assert(std.meta.eql(termios_1, termios_raw));
    // restore to canonical mode, check values were correctly applied
    try termios.tcsetattr(std_in.handle, termios.TCSAFLUSH, &termios_2);
    try termios.tcgetattr(std_out.handle, &termios_1);
    std.debug.assert(std.meta.eql(termios_1, termios_2));

    // TODO: better tests for these
    try termios.tcdrain(std_in.handle);
    try termios.tcflow(std_in.handle, termios.TCOON);
    try termios.tcflush(std_in.handle, termios.TCIOFLUSH);
    try termios.tcsendbreak(std_in.handle, 0);
    _ = try termios.tcgetsid(std_in.handle);
}
