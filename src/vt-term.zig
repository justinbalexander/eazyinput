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
};

const max_usize_str_len = "18446744073709551615".len;

pub const CursorPos = struct {
    row_pos: usize,
    col_pos: usize,
};

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

pub fn getCursorColumnPos(in: *os.File, out: *os.File) !usize {
    const cursor_pos = try getCursorPos(in, out);
    return cursor_pos.col_pos;
}

pub fn getCursorRowPos(in: *os.File, out: *os.File) !usize {
    const cursor_pos = try getCursorPos(in, out);
    return cursor_pos.row_pos;
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
    const ret1 = scanRowColumnPositionResponse((ESC++"[20;30")[0..]) catch unreachable;
    assert(ret1.row_pos == 20 and ret1.col_pos == 30);
}

