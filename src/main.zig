const std = @import("std");
const os = std.os;
const vt = @import("vt-term.zig");
const assertOrPanic = std.debug.assertOrPanic;

const EZError = error{NotImplemented};

const EditMode = enum {
    Normal,
    Insert,
    Visual,
};

const EditorState = struct {
    index: usize, // index within row slice
    cpos: vt.CursorPos, // location of terminal cursor
    mode: EditMode, // current editor mode
    seq_timer: usize, // timeout for multi-key sequences
    termd: vt.TerminalDimensions, // last queried terminal dimensions
    done: bool, // editor is ready to return to user

    const Self = @This();

    fn init(prompt: []const u8) !Self {
        var state = EditorState{
            .cpos = undefined,
            .termd = undefined,
            .index = 0,
            .mode = EditMode.Normal,
            .seq_timer = 0,
            .done = false,
        };
        try std_out.write(prompt);
        try state.updateCursorPos();
        state.updateTerminalSize();
        return state;
    }

    fn matchCursorPos(state: *Self) !void {
        try vt.setCursorPos(state.cpos);
    }

    fn updateCursorPos(state: *Self) !void {
        state.cpos = try vt.getCursorPos();
    }

    fn updateTerminalSize(state: *Self) void {
        state.termd = vt.getTerminalSize();
    }

    fn getEditorDone(state: *Self) bool {
        return state.done;
    }

    fn registerKey(state: *Self, key: u8) void {
        return;
    }
};

const std_in = os.File.openHandle(os.posix.STDIN_FILENO);
const std_out = os.File.openHandle(os.posix.STDOUT_FILENO);
const std_err = os.File.openHandle(os.posix.STDERR_FILENO);

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
    if (runtime_allocator) |allocator| {
        var buf = try allocator.alloc(T, n);
        std.mem.set(u8, buf, 0);
        return buf;
    } else {
        const allocator = struct {
            var direct_allocator = std.heap.DirectAllocator.init();
            var arena_allocator = std.heap.ArenaAllocator.init(&direct_allocator.allocator);
        };
        runtime_allocator = &(allocator.arena_allocator.allocator);
        var buf = try runtime_allocator.?.alloc(T, n);
        std.mem.set(u8, buf, 0);
        return buf;
    }
}

fn handleNotTty() ![]u8 {
    return EZError.NotImplemented;
}

fn handleUnsupportedTerm() ![]u8 {
    return EZError.NotImplemented;
}

fn getEazyInput(prompt: []const u8) ![]u8 {
    var fbuf: [4096]u8 = undefined;
    var buf = try eazyInputSliceAlloc(u8, default_max_line_len);
    errdefer eazyInputSliceFree(buf) catch {};

    var orig_term = try vt.enableRawTerminalMode();
    defer vt.setTerminalMode(&orig_term) catch {}; // best effort

    var state = try EditorState.init(prompt);

    while (!state.getEditorDone()) {
        if (getKeypress()) |key| {
            state.registerKey(key);
        } else |err| return err;
    }

    return buf;
}

fn getKeypress() !u8 {
    var c = []u8{0};
    var count = try std_in.read(c[0..1]);
    if (count == 1) return c[0] else return error.noKeypress;
}

fn CTRL(c: u8) u8 {
    return c & u8(0x1F);
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
        slice = ([]u8{0})[0..0];
    }
    return slice;
}

test "eazyinput.zig: strnslice" {
    const cstr_null: ?[*]const u8 = null;
    const cstr_0: ?[*]const u8 = c"";
    const cstr_1: ?[*]const u8 = c"123456";

    // string is null pointer
    std.debug.assert(std.mem.compare(u8, strnslice(cstr_null, 10), ""[0..0]) == std.mem.Compare.Equal);
    // null terminator is first byte
    std.debug.assert(std.mem.compare(u8, strnslice(cstr_0, 10), ""[0..0]) == std.mem.Compare.Equal);
    // null terminator is at "n" index
    std.debug.assert(std.mem.compare(u8, strnslice(cstr_1, 6), "123456"[0..6]) == std.mem.Compare.Equal);
    // null terminator is beyond "n" index
    std.debug.assert(std.mem.compare(u8, strnslice(cstr_1, 5), "123456"[0..5]) == std.mem.Compare.Equal);
    // null terminator is before "n" index
    std.debug.assert(std.mem.compare(u8, strnslice(cstr_1, 7), "123456"[0..6]) == std.mem.Compare.Equal);
}

test "eazyinput.zig: allocations and frees" {
    var buf = try eazyInputSliceAlloc(u8, default_max_line_len);
    try eazyInputSliceFree(buf);
}
