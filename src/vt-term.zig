const std = @import("std");
const os = std.os;
const fmt = std.fmt;
const mem = std.mem;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const assert = std.debug.assert;

// From http://www.3waylabs.com/nw/WWW/products/wizcon/vt220.html
const BELL  = []u8{7};     // Bell
const BS    = []u8{8};     // Moves cursor back one column
const HT    = []u8{9};     // Moves the cursor to next tab stop
const LF    = []u8{10};    // Moves the cursor down one row
const CR    = []u8{13};    // Move the cursor to column one
const CAN   = []u8{24};    // Cancels an escape sequence
const ESC   = []u8{27};    // Starts an escape sequence

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

pub fn eraseCursorToEndOfLine(fd: *os.File) !void {
    try fd.write(ESC++"[0K");
}

pub fn eraseStartOfLineToCursor(fd: *os.File) !void {
    try fd.write(ESC++"[1K");
}

pub fn eraseEntireLine(fd: *os.File) !void {
    try fd.write(ESC++"[2K");
}

pub fn eraseCursorToEndOfDisplay(fd: *os.File) !void {
    try fd.write(ESC++"[0J");
}

pub fn eraseStartOfDisplayToCursor(fd: *os.File) !void {
    try fd.write(ESC++"[1J");
}

pub fn eraseEntireDisplay(fd: *os.File) !void {
    try fd.write(ESC++"[2J");
}

pub fn cursorHome(fd: *os.File) !void {
    try fd.write(ESC++"[H");
}

pub fn cursorForward(fd: *os.File, num_chars: usize) !void {
    var formatting_buf: [max_usize_str_len + 3]u8 = undefined;
    const esc_seq = try fmt.bufPrint(formatting_buf[0..], ESC++"[{}C", num_chars);
    try fd.write(esc_seq);
}

pub fn cursorBackward(fd: *os.File, num_chars: usize) !void {
    var formatting_buf: [max_usize_str_len + 3]u8 = undefined;
    const esc_seq = try fmt.bufPrint(formatting_buf[0..], ESC++"[{}D", num_chars);
    try fd.write(esc_seq);
}

pub fn cursorUp(fd: *os.File, num_chars: usize) !void {
    var formatting_buf: [max_usize_str_len + 3]u8 = undefined;
    const esc_seq = try fmt.bufPrint(formatting_buf[0..], ESC++"[{}A", num_chars);
    try fd.write(esc_seq);
}

pub fn cursorDown(fd: *os.File, num_chars: usize) !void {
    var formatting_buf: [max_usize_str_len + 3]u8 = undefined;
    const esc_seq = try fmt.bufPrint(formatting_buf[0..], ESC++"[{}B", num_chars);
    try fd.write(esc_seq);
}

pub fn getCursorPos(in: *os.File, out: *os.File) !CursorPos {
    var buf: [(max_usize_str_len * 2) + 4]u8 = undefined;
    const alloc = FixedBufferAllocator.init(buf);

    //https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
    try out.write(ESC++"[6n");

    // response delimited by 'R'
    const in_stream = in.InStream();
    const response = in_stream.readUntilDelimiterAlloc(alloc, 'R', buf.len);

    return try scanRowColumnPositionResponse(response);
}

pub fn getCursorColumn(in: *os.File, out: *os.File) !usize {
    const cursor_pos = try getCursorPos(in, out);
    return cursor_pos.col_pos;
}

pub fn getCursorRow(in: *os.File, out: *os.File) !usize {
    const cursor_pos = try getCursorPos(in, out);
    return cursor_pos.row_pos;
}

pub fn getTerminalSize() TerminalDimensions {
    return ttyWinSize(1) catch TerminalDimensions {
                                                    .width = 80,
                                                    .height = 24,
                                                  };
}

fn ttyWinSize(fd: i32) !os.winsize {
    var wsz: os.winsize = undefined;
    if (syscall3(SYS_ioctl, @bitCast(usize, isize(fd)), TIOCGWINSZ, @ptrToInt(&wsz)) == 0 and
        wsz.ws_col != 0) {
        return wsz;
    } else {
        return VTError.UnableToDetermineTerminalDimensions;
    }
}

fn scanRowColumnPositionResponse(response: []const u8) !CursorPos {
    // expected response: 'ESC' '[' rows ';' columns 'R'
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

test "scan row/column position response" {
    // SUCCESS CASES
    const ret1 = scanRowColumnPositionResponse((ESC++"[20;30")[0..]) catch unreachable;
    assert(ret1.row_pos == 20 and ret1.col_pos == 30);

    const ret2 = scanRowColumnPositionResponse((ESC++"[18446744073709551615;18446744073709551615")[0..]) catch unreachable;
    assert(ret2.row_pos == 18446744073709551615 and ret2.col_pos == 18446744073709551615);

    // FAILURE CASES
    const catch_val = CursorPos { .row_pos = 127,
                                  .col_pos = 255,
                                };
    // parseUnsigned failure, num too large
    const err1 = scanRowColumnPositionResponse((ESC++"[18446744073709551615;18446744073709551616")[0..]) catch catch_val;
    assert(err1.row_pos == catch_val.row_pos and err1.col_pos == catch_val.col_pos);
    const err2 = scanRowColumnPositionResponse((ESC++"[18446744073709551616;18446744073709551615")[0..]) catch catch_val;
    assert(err2.row_pos == catch_val.row_pos and err2.col_pos == catch_val.col_pos);

    // malformed response
    // missing semicolon
    const err3 = scanRowColumnPositionResponse((ESC++"[20:30")[0..]) catch catch_val;
    assert(err3.row_pos == catch_val.row_pos and err3.col_pos == catch_val.col_pos);
    // missing [
    const err4 = scanRowColumnPositionResponse((ESC++"{20;30")[0..]) catch catch_val;
    assert(err4.row_pos == catch_val.row_pos and err4.col_pos == catch_val.col_pos);
    // extra character at start
    const err5 = scanRowColumnPositionResponse((BELL++ESC++"[20;30")[0..]) catch catch_val;
    assert(err5.row_pos == catch_val.row_pos and err5.col_pos == catch_val.col_pos);
}

