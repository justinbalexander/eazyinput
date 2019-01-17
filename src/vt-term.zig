const std = @import("std");
const os = std.os;
const linux = os.linux;
const io = std.io;
const fmt = std.fmt;
const mem = std.mem;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const assert = std.debug.assert;
const termios = @import("termios.zig");

// From http://www.3waylabs.com/nw/WWW/products/wizcon/vt220.html
const BELL  = []u8{7};     // Bell
const BS    = []u8{8};     // Moves cursor back one column
const HT    = []u8{9};     // Moves the cursor to next tab stop
const LF    = []u8{10};    // Moves the cursor down one row
const CR    = []u8{13};    // Move the cursor to column one
const CAN   = []u8{24};    // Cancels an escape sequence
const ESC   = []u8{27};    // Starts an escape sequence

const std_in = os.File {.handle = os.posix.STDIN_FILENO};
const std_out = os.File {.handle = os.posix.STDOUT_FILENO};
const std_err = os.File {.handle = os.posix.STDERR_FILENO};

const VTError = error {
    UnexpectedResponse,
    UnableToDetermineTerminalDimensions,
};

const max_usize_str_len = "18446744073709551615".len;
const unsupported_term = [][]const u8{
        "dumb",
        "cons25",
        "emacs",
};

pub const CursorPos = struct {
    row_pos: usize,
    col_pos: usize,
};

pub const TerminalDimensions = struct {
    width: usize,
    height: usize,
};

pub fn isUnsupportedTerm() bool {
    const TERM = os.getEnvPosix("TERM") orelse return true;
    for (unsupported_term) |comp| {
        if (mem.compare(u8, TERM, comp) == mem.Compare.Equal) return true;
    }
    return false;
}

pub fn eraseCursorToEndOfLine() !void {
    try std_out.write(ESC++"[0K");
}

pub fn eraseStartOfLineToCursor() !void {
    try std_out.write(ESC++"[1K");
}

pub fn eraseEntireLine() !void {
    try std_out.write(ESC++"[2K");
}

pub fn eraseCursorToEndOfDisplay() !void {
    try std_out.write(ESC++"[0J");
}

pub fn eraseStartOfDisplayToCursor() !void {
    try std_out.write(ESC++"[1J");
}

pub fn eraseEntireDisplay() !void {
    try std_out.write(ESC++"[2J");
}

pub fn cursorHome() !void {
    try std_out.write(ESC++"[H");
}

pub fn clearScreen() !void {
    try cursorHome();
    try eraseEntireDisplay();
}

pub fn cursorForward(num_chars: usize) !void {
    var formatting_buf: [max_usize_str_len + 3]u8 = undefined;
    const esc_seq = try fmt.bufPrint(formatting_buf[0..], ESC++"[{}C", num_chars);
    try std_out.write(esc_seq);
}

pub fn cursorBackward(num_chars: usize) !void {
    var formatting_buf: [max_usize_str_len + 3]u8 = undefined;
    const esc_seq = try fmt.bufPrint(formatting_buf[0..], ESC++"[{}D", num_chars);
    try std_out.write(esc_seq);
}

pub fn cursorUp(num_chars: usize) !void {
    var formatting_buf: [max_usize_str_len + 3]u8 = undefined;
    const esc_seq = try fmt.bufPrint(formatting_buf[0..], ESC++"[{}A", num_chars);
    try std_out.write(esc_seq);
}

pub fn cursorDown(num_chars: usize) !void {
    var formatting_buf: [max_usize_str_len + 3]u8 = undefined;
    const esc_seq = try fmt.bufPrint(formatting_buf[0..], ESC++"[{}B", num_chars);
    try std_out.write(esc_seq);
}

pub fn getCursorPos() !CursorPos {
    var buf_arr: [(max_usize_str_len * 2) + 4]u8 = undefined;
    var buf = buf_arr[0..];

    //https://vt100.net/docs/vt100-ug/chapter3.html#DSR
    try std_out.write(ESC++"[6n");

    var esc_index: usize = 0;
    var char_R_index: usize = 0;
    for (buf) |c,i| {
        if ((try std_out.read(buf[i..i+1])) == 1) {
            switch (buf[i]) {
                ESC[0] => {
                    esc_index = i;
                    },
                'R' => {
                    char_R_index = i;
                    break;
                    },
                else => {},
            }
        } else {
            break;
        }
    }

    if (char_R_index > 0) {
        return try scanCursorPositionReport(buf[esc_index..char_R_index]);
    } else {
        return error.CursorPosResponseNotFound;
    }
}

pub fn getCursorColumn() !usize {
    const cursor_pos = try getCursorPos();
    return cursor_pos.col_pos;
}

pub fn getCursorRow() !usize {
    const cursor_pos = try getCursorPos();
    return cursor_pos.row_pos;
}

pub fn getTerminalSize() TerminalDimensions {
    if (ttyWinSize()) |win_size| {
        return TerminalDimensions{
                .width = win_size.ws_col,
                .height = win_size.ws_row,
               };
    } else |err| {
        return TerminalDimensions {
                .width = 80,
                .height = 24,
               };
    }
}

pub fn enableRawTerminalMode() !termios.Termios {
    if (!std_in.isTty()) return error.IsNotTty;

    var orig: termios.Termios = undefined;
    try termios.tcgetattr(std_in.handle, &orig);
    var raw = orig;
    termios.cfmakeraw(&raw);
    try termios.tcsetattr(std_in.handle,termios.TCSAFLUSH,&raw);
    return orig;
}

pub fn setTerminalMode(tio: *const termios.Termios) !void {
    try termios.tcsetattr(std_in.handle, termios.TCSAFLUSH, tio);
}

pub fn beep() !void {
    try std_err.write(BELL);
}

fn ttyWinSize() !linux.winsize {
    var wsz: linux.winsize = undefined;
    if (os.linux.syscall3(linux.SYS_ioctl, std_out.handle, linux.TIOCGWINSZ, @ptrToInt(&wsz)) == 0 and
        wsz.ws_col != 0) {
        return wsz;
    } else {
        return VTError.UnableToDetermineTerminalDimensions;
    }
}

fn scanCursorPositionReport(response: []const u8) !CursorPos {
    //https://vt100.net/docs/vt100-ug/chapter3.html#CPR
    if (mem.compare(u8, response[0..2], ESC++"[") != mem.Compare.Equal) {
        return VTError.UnexpectedResponse;
    }

    const delimiter_index = mem.indexOf(u8, response, ";") orelse return VTError.UnexpectedResponse;
    const row_pos = try fmt.parseUnsigned(usize, response[2..delimiter_index], 10);
    const col_pos = try fmt.parseUnsigned(usize, response[delimiter_index+1..], 10);

    return CursorPos {
        .row_pos = row_pos,
        .col_pos = col_pos,
    };
}

fn setTerminalModeNoError(tio: *const termios.Termios) void {
    setTerminalMode(tio) catch return;
}

test "scan row/column position response" {
    // SUCCESS CASES
    const ret1 = scanCursorPositionReport((ESC++"[20;30")[0..]) catch unreachable;
    assert(ret1.row_pos == 20 and ret1.col_pos == 30);

    const ret2 = scanCursorPositionReport((ESC++"[18446744073709551615;18446744073709551615")[0..]) catch unreachable;
    assert(ret2.row_pos == 18446744073709551615 and ret2.col_pos == 18446744073709551615);

    // FAILURE CASES
    const catch_val = CursorPos { .row_pos = 127,
                                  .col_pos = 255,
                                };
    // parseUnsigned failure, num too large
    const err1 = scanCursorPositionReport((ESC++"[18446744073709551615;18446744073709551616")[0..]) catch catch_val;
    assert(err1.row_pos == catch_val.row_pos and err1.col_pos == catch_val.col_pos);
    const err2 = scanCursorPositionReport((ESC++"[18446744073709551616;18446744073709551615")[0..]) catch catch_val;
    assert(err2.row_pos == catch_val.row_pos and err2.col_pos == catch_val.col_pos);

    // malformed response
    // missing semicolon
    const err3 = scanCursorPositionReport((ESC++"[20:30")[0..]) catch catch_val;
    assert(err3.row_pos == catch_val.row_pos and err3.col_pos == catch_val.col_pos);
    // missing [
    const err4 = scanCursorPositionReport((ESC++"{20;30")[0..]) catch catch_val;
    assert(err4.row_pos == catch_val.row_pos and err4.col_pos == catch_val.col_pos);
    // extra character at start
    const err5 = scanCursorPositionReport((BELL++ESC++"[20;30")[0..]) catch catch_val;
    assert(err5.row_pos == catch_val.row_pos and err5.col_pos == catch_val.col_pos);
}

test "use functions" {
    assert(!isUnsupportedTerm());
    try beep();
    try eraseCursorToEndOfLine();
    try eraseStartOfLineToCursor();
    try eraseEntireLine();
    try eraseCursorToEndOfDisplay();
    try eraseStartOfDisplayToCursor();
    try eraseEntireDisplay();
    try clearScreen();
    try cursorForward(10);
    try cursorBackward(10);
    try cursorUp(2);
    try cursorHome();
    try cursorDown(2);
    var non_raw = try enableRawTerminalMode();
    defer setTerminalModeNoError(&non_raw);
    _ = try getCursorPos();
    _ = try getCursorColumn();
    _ = try getCursorRow();
    _ = getTerminalSize();
}
