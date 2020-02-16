const std = @import("std");
const os = std.os;
const vt = @import("vt-term.zig");
const assertOrPanic = std.debug.assertOrPanic;

const EZError = error{
    NotImplemented,
    NoUserInput,
};

const EditMode = enum {
    Normal,
    Insert,
    Visual,
};

const EditorState = struct {
    index: usize, // index within row slice
    cpos: vt.CursorPos, // location of terminal cursor
    i_cpos: vt.CursorPos, // initial location of terminal cursor (after prompt)
    max_cpos: vt.CursorPos, // Farthest cursor position
    mode: EditMode, // current editor mode
    seq_timer: usize, // timeout for multi-key sequences
    termd: vt.TerminalDimensions, // last queried terminal dimensions
    done: bool, // editor is ready to return to user
    in_buf: []u8, // buffer used to store input
    in_len: usize, // current user input size

    const Self = @This();

    fn init(prompt: []const u8, buf: []u8) !Self {
        var state = EditorState{
            .cpos = undefined,
            .i_cpos = undefined,
            .max_cpos = undefined,
            .termd = undefined,
            .index = 0,
            .mode = EditMode.Normal,
            .seq_timer = 0,
            .done = false,
            .in_buf = buf,
            .in_len = 0,
        };
        try std_out.write(prompt);
        try state.updateCursorPos();
        state.i_cpos = state.cpos;
        state.max_cpos = state.cpos;
        state.updateTerminalSize();
        return state;
    }

    fn setCursorPos(state: *Self, pos: vt.CursorPos) !void {
        try vt.setCursorPos(pos);
    }

    fn getCursorPos(state: *Self) !vt.CursorPos {
        return try vt.getCursorPos();
    }

    fn updateCursorPos(state: *Self) !void {
        state.cpos = try vt.getCursorPos();
    }

    fn updateTerminalSize(state: *Self) void {
        state.termd = vt.getTerminalSize();
    }

    fn setEditMode(state: *Self, mode: EditMode) void {
        state.mode = mode;
    }

    fn getEditorDone(state: *Self) bool {
        return state.done;
    }

    fn getCurrentUserInput(state: *Self) []u8 {
        return state.in_buf[0..state.in_len];
    }

    fn moveCursorUp(state: *Self) void {}
    fn moveCursorDown(state: *Self) void {}

    fn moveCursorRight(state: *Self) !void {
        if (state.index < state.in_len) {
            vt.cursorForward(1) catch return;
            state.index += 1;
            try state.updateCursorPos();
        }
    }

    fn moveCursorLeft(state: *Self) !void {
        if (state.index > 0) {
            vt.cursorBackward(1) catch return;
            state.index -= 1;
            try state.updateCursorPos();
        }
    }

    fn copyRight(state: *Self, num: usize) void {
        //TODO: check that cursor won't go past screen
        if (state.in_len < state.in_buf.len - num) {
            std.mem.copy(u8, state.in_buf[state.index + num .. state.in_len + num], state.in_buf[state.index..state.in_len]);
        }
    }

    fn refreshScreen(state: *Self) !void {
        try state.setCursorPos(state.i_cpos);
        try vt.eraseCursorToEndOfDisplay();
        try std_out.write(state.in_buf[0..state.in_len]);
        state.max_cpos = try state.getCursorPos();
        try state.setCursorPos(state.cpos);
    }

    fn insertCharacter(state: *Self, key: u8) void {
        state.copyRight(1);
        state.in_buf[state.index] = key;
        state.in_len += 1;
        state.index += 1;
        if (state.cpos.col < state.termd.width - 1) {
            state.cpos.col += 1;
        } else {
            state.cpos.col = 0;
            if (state.cpos.row < state.termd.height - 1) {
                state.cpos.row += 1;
                // else at bottom of screen already
            }
        }
    }

    fn registerKey(state: *Self, key: u8) !void {
        const kmem = [1]u8{key};
        const kslice = kmem[0..];

        state.updateTerminalSize();
        switch (state.mode) {
            EditMode.Insert => switch (key) {
                CTRL('c') => {
                    state.done = true;
                },
                CTRL('d') => {
                    state.setEditMode(EditMode.Normal);
                },
                else => {
                    state.insertCharacter(key);
                },
            },
            EditMode.Normal => switch (key) {
                'l' => {
                    try state.moveCursorRight();
                },
                'k' => {
                    state.moveCursorUp();
                },
                'j' => {
                    state.moveCursorDown();
                },
                'h' => {
                    try state.moveCursorLeft();
                },
                'i' => {
                    state.setEditMode(EditMode.Insert);
                },
                CTRL('c') => {
                    state.done = true;
                },
                else => {},
            },
            EditMode.Visual => switch (key) {
                CTRL('c') => {
                    state.done = true;
                },
                else => {
                    unreachable;
                },
            },
        }
        try state.refreshScreen();
        return;
    }
};

const std_in = std.io.getStdIn();
const std_out = std.io.getStdOut();
const std_err = std.io.getStdErr();

const default_max_line_len = 4096;

var runtime_allocator: ?*std.mem.Allocator = null;

//*****************************************************************************
// Description: Displays prompt, returns user input
// Parameters: []u8 - Prompt to display, slice
// Return: ![]u8 - User input or error if not successful
//*****************************************************************************
pub fn eazyInputSlice(prompt: []const u8) ![]u8 {
    if (!os.isTty(0)) {
        _ = handleNotTty();
    } else if (vt.isUnsupportedTerm()) {
        _ = handleUnsupportedTerm();
    } else {
        const ret_slice_null_terminated = try getEazyInput(prompt);
        // TODO: how much memory does the length portion of the slice take up?
        return ret_slice_null_terminated[0 .. ret_slice_null_terminated.len - 1];
    }
    return error.eazyInputNoUserInput;
}

//*****************************************************************************
// Description: Frees memory previously returned by eazyInputSliceAlloc
// Parameters: []u8 - slice of memory to free
// Return: !void - error if unsuccessful or allocator not initialized
//*****************************************************************************
pub fn eazyInputSliceFree(user_input: []const u8) !void {
    if (runtime_allocator) |allocator| {
        allocator.free(user_input[0..]);
        return;
    } else {
        return error.ez_allocator_uninitialized;
    }
}

//*****************************************************************************
// Description: Allocates memory for the user input
// Parameters: []u8 - Prompt to display, slice
// Return: ![]u8 - User input or error if not successful
//*****************************************************************************
fn eazyInputSliceAlloc(comptime T: type, n: usize) ![]T {
    if (runtime_allocator == null) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        runtime_allocator = &arena.allocator;
    }


    if (runtime_allocator) |allocator| {
        var buf = try allocator.alloc(T, n);
        std.mem.set(u8, buf, 0);
        return buf;
    } else {
        unreachable;
    }
}

fn handleNotTty() ![]u8 {
    return EZError.NotImplemented;
}

fn handleUnsupportedTerm() ![]u8 {
    return EZError.NotImplemented;
}

fn getEazyInput(prompt: []const u8) ![]u8 {
    var fbuf: [default_max_line_len]u8 = undefined;

    var orig_term = try vt.enableRawTerminalMode();
    defer vt.setTerminalMode(&orig_term) catch {}; // best effort

    var state = try EditorState.init(prompt, fbuf[0..]);

    while (!state.getEditorDone()) {
        if (getKeypress()) |key| {
            try state.registerKey(key);
        } else |err| return err;
    }

    var ret_input = state.getCurrentUserInput();
    if (ret_input.len > 0) {
        var buf = try eazyInputSliceAlloc(u8, ret_input.len);
        errdefer eazyInputSliceFree(buf) catch {};
        std.mem.copy(u8, ret_input, buf);
        return buf;
    }
    return EZError.NoUserInput;
}

fn getKeypress() !u8 {
    var c = [_]u8{0};
    var count = try std_in.read(c[0..1]);
    if (count == 1) return c[0] else return error.noKeypress;
}

inline fn CTRL(c: u8) u8 {
    return c & @as(u8, 0x1F);
}

fn strnslice(c_str: ?[*]const u8, n: usize) []const u8 {
    // TODO: how to return const slice only if input was const?
    // check for null pointer input, convert to zero length slice
    var slice: []const u8 = undefined;
    if (c_str) |p| {
        for (p[0..n]) |c, i| {
            if (c == 0) {
                slice = p[0..i];
                break;
            }
        } else {
            slice = p[0..n];
        }
    } else {
        slice = ([_]u8{0})[0..0];
    }
    return slice;
}

test "eazyinput.zig: strnslice" {
    const cstr_null: ?[*]const u8 = null;
    const cstr_0: ?[*]const u8 = "";
    const cstr_1: ?[*]const u8 = "123456";

    // string is null pointer
    std.debug.assert(std.mem.eql(u8, strnslice(cstr_null, 10), ""[0..0]));
    // null terminator is first byte
    std.debug.assert(std.mem.eql(u8, strnslice(cstr_0, 10), ""[0..0]));
    // null terminator is at "n" index
    std.debug.assert(std.mem.eql(u8, strnslice(cstr_1, 6), "123456"[0..6]));
    // null terminator is beyond "n" index
    std.debug.assert(std.mem.eql(u8, strnslice(cstr_1, 5), "123456"[0..5]));
    // null terminator is before "n" index
    std.debug.assert(std.mem.eql(u8, strnslice(cstr_1, 7), "123456"[0..6]));
}

test "eazyinput.zig: allocations and frees" {
    var buf = try eazyInputSliceAlloc(u8, default_max_line_len);
    try eazyInputSliceFree(buf);
}

test "eazyinput.zig: top level call" {
    var ret = try getEazyInput("prompt"[0..]);
    defer eazyInputSliceFree(ret) catch {};
}
