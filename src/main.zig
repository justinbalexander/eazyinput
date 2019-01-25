const std = @import("std");
const os = std.os;
const vt = @import("vt-term.zig");
const assertOrPanic = std.debug.assertOrPanic;

const EZError = error {
    NotImplemented,
};

const EditMode = enum {
    Normal,
    Insert,
    Visual,
};

const EditorState = struct {
    index: usize,                   // index within row slice
    cpos: vt.CursorPos,             // location of terminal cursor
    mode: EditMode,                 // current editor mode
    seq_timer: usize,               // timeout for multi-key sequences
    termd: vt.TerminalDimensions,   // last queried terminal dimensions

    fn init() !EditorState {
        var state = EditorState {
            .cpos = undefined,
            .termd = undefined,
            .index = 0,
            .mode = EditMode.Normal,
            .seq_timer = 0,
        };
        try state.updateCursorPos();
        state.updateTerminalSize();
        return state;
    }

    fn matchCursorPos(state: *EditorState) !void {
        try vt.setCursorPos(state.cpos);
    }

    fn updateCursorPos(state: *EditorState) !void {
        state.cpos = try vt.getCursorPos();
    }

    fn updateTerminalSize(state: *EditorState) void {
        state.termd = vt.getTerminalSize();
    }

};

const std_in = os.File.openHandle(os.posix.STDIN_FILENO);
const std_out = os.File.openHandle(os.posix.STDOUT_FILENO);
const std_err = os.File.openHandle(os.posix.STDERR_FILENO);

var direct_allocator = std.heap.DirectAllocator.init();
const allocator = &direct_allocator.allocator;
const default_max_line_len = os.page_size;  // dictated by DirectAllocator


//*****************************************************************************
// Description: Displays prompt, returns user input
// Parameters: ?[*]const u8 - Null terminated prompt string to display
// Return: ?[*]u8 - Null terminated user input
// Notes: Return string owned by callee, free with eazyInputStrFree
//*****************************************************************************
export fn eazyInputStr(input: ?[*]const u8) ?[*]u8 {
    const max_prompt = 255;
    const prompt = cstrNSlice(input, max_prompt);
    if (!os.isTty(0)) {
        _ = handleNotTty();
    } else if (vt.isUnsupportedTerm()) {
        _ = handleUnsupportedTerm();
    } else {
        const ret_slice_null_terminated = getEazyInput(prompt) catch |err| return null;
        assertOrPanic(ret_slice_null_terminated.len == default_max_line_len);
        return ret_slice_null_terminated.ptr;
    }
    return null;
}

//*****************************************************************************
// Description: Frees previously returned string
// Parameters: ?[*]const u8 - pointer to memory to free
// Return: void
//*****************************************************************************
export fn eazyInputStrFree(user_input: ?[*]const u8) void {
    if (user_input) |ptr| {
        allocator.free(ptr[0..default_max_line_len]);
    }
}

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
        return ret_slice_null_terminated[0..ret_slice_null_terminated.len - 1];
    }
    return error.eazyInputNoUserInput;
}

//*****************************************************************************
// Description: Frees memory previously returned by eazyInputSlice
// Parameters: []u8 - Prompt to display, slice
// Return: ![]u8 - User input or error if not successful
//*****************************************************************************
pub fn eazyInputSliceFree(user_input: []const u8) void {
    // free entire page
    allocator.free(user_input.ptr[0..default_max_line_len]);
}

fn handleNotTty() ![]u8 {
    return EZError.NotImplemented;
}

fn handleUnsupportedTerm() ![]u8 {
    return EZError.NotImplemented;
}

fn getEazyInput(prompt: []const u8) ![]u8 {
    var fbuf: [4096]u8 = undefined;
    var buf = try allocator.alloc(u8,default_max_line_len);
    errdefer allocator.free(buf);

    var orig_term = try vt.enableRawTerminalMode();
    defer vt.setTerminalMode(&orig_term) catch {}; // best effort

    try std_out.write(prompt);

    var state = try EditorState.init();

    return EZError.NotImplemented;
}

fn CTRL(c: u8) u8 {
    return c & u8(0x1F);
}

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

test "eazyinput.zig: cstrNSlice" {
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

test "eazyinput.zig: call all functions" {
//    eazyInputStrFree(eazyInputStr(c"prompt"));
    eazyInputSliceFree(try eazyInputSlice("prompt"[0..]));
}
