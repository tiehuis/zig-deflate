const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const io = std.io;

const ArrayList = std.ArrayList;
const InStream = io.InStream;
const OutStream = io.OutStream;

// Stream from a fixed input buffer.
pub const MemoryInStream = struct {
    buffer: []const u8,
    position: usize,
    stream: Stream,

    pub const Error = error{EndOfStream};
    pub const Stream = InStream(Error);

    pub fn init(buffer: []const u8) MemoryInStream {
        return MemoryInStream {
            .buffer = buffer,
            .position = 0,
            .stream = Stream {
                .readFn = readFn,
            },
        };
    }

    fn readFn(in_stream: &Stream, buffer: []u8) Error!usize {
        const self = @fieldParentPtr(MemoryInStream, "stream", in_stream);

        if (self.position >= self.buffer.len) {
            return Error.EndOfStream;
        }

        var copy_amount = buffer.len;
        if (self.position + copy_amount >= self.buffer.len) {
            copy_amount = self.buffer.len - self.position;
        }

        mem.copy(u8, buffer, self.buffer[self.position .. self.position + copy_amount]);
        self.position += copy_amount;
        return copy_amount;
    }
};

test "memory in stream" {
    var input = "here is some input";

    var mem_stream = MemoryInStream.init(input[0..]);

    debug.assert((try mem_stream.stream.readByte()) == 'h');

    const rest = try mem_stream.stream.readAllAlloc(debug.global_allocator, 128);
    defer debug.global_allocator.free(rest);

    debug.assert(mem.eql(u8, rest, input[1..]));
}

pub const MemoryOutStream = struct {
    buffer: &ArrayList(u8),
    stream: Stream,

    pub const Error = error{OutOfMemory};
    pub const Stream = OutStream(Error);

    pub fn init(buffer: &ArrayList(u8)) MemoryOutStream {
        return MemoryOutStream {
            .buffer = buffer,
            .stream = Stream {
                .writeFn = writeFn,
            },
        };
    }

    fn writeFn(out_stream: &Stream, bytes: []const u8) Error!void {
        const self = @fieldParentPtr(MemoryOutStream, "stream", out_stream);
        return self.buffer.appendSlice(bytes);
    }
};

test "memory out stream" {
    var output = ArrayList(u8).init(debug.global_allocator);
    defer output.deinit();

    var out_stream = MemoryOutStream.init(&output);

    try out_stream.stream.writeByte('h');
    debug.assert(mem.eql(u8, output.toSliceConst(), "h"));

    try out_stream.stream.write("ere is some output");
    debug.assert(mem.eql(u8, output.toSliceConst(), "here is some output"));
}

// Wrapper which intercepts an OutStream, caching the last N bytes in a sliding window.
pub fn SlidingWindowOutStream(comptime out_error: type, comptime window_size: usize) type {
    return struct {
        const Self = this;

        // A double-sized sliding window allows us to minimize reshuffles while maintaining
        // a contiguous slice for our window.
        window: [2 * window_size]u8,
        // Length of the window. Once this is `window_size` it will not grow or shrink.
        window_len: usize,
        // Index to start of window slice. window_start < window_size.
        window_start: usize,

        base_out_stream: &Stream,
        stream: Stream,

        pub const Error = out_error;
        pub const Stream = io.OutStream(Error);

        pub fn init(base_out_stream: &Stream) Self {
            return Self {
                .window = undefined,
                .window_len = 0,
                .window_start = 0,

                .base_out_stream = base_out_stream,
                .stream = Stream {
                    .writeFn = writeFn,
                },
            };
        }

        pub fn windowSlice(self: &Self) []const u8 {
            return self.window[self.window_start .. self.window_start + self.window_len];
        }

        pub fn clearWindow(self: &Self) void {
            self.window_len = 0;
            self.window_start = 0;
        }

        fn writeFn(out_stream: &Stream, bytes: []const u8) !void {
            const self = @fieldParentPtr(Self, "stream", out_stream);

            try self.base_out_stream.write(bytes);

            if (bytes.len + self.window_start + self.window_len >= 2 * window_size) {
                if (bytes.len >= window_size) {
                    mem.copy(u8, self.window[0..window_size], bytes[bytes.len - window_size..]);
                } else {
                    const amount_to_move = window_size - bytes.len;
                    const window_end = self.window_start + self.window_len;
                    mem.copy(u8, self.window[0..amount_to_move], self.window[window_end - amount_to_move..window_end]);
                    mem.copy(u8, self.window[amount_to_move..window_size], bytes[0..]);
                }

                self.window_start = 0;
                self.window_len = window_size;
            } else {
                mem.copy(u8, self.window[self.window_start + self.window_len..], bytes);

                self.window_len += bytes.len;
                if (self.window_len > window_size) {
                    self.window_start += self.window_len - window_size;
                    self.window_len = window_size;
                }
            }
        }
    };
}

test "sliding window out stream" {
    var output = ArrayList(u8).init(debug.global_allocator);
    defer output.deinit();

    var backing_out_stream = MemoryOutStream.init(&output);
    var out_stream = SlidingWindowOutStream(MemoryOutStream.Error, 8).init(&backing_out_stream.stream);

    // partial write
    try out_stream.stream.write("012");
    debug.assert(mem.eql(u8, out_stream.windowSlice(), "012"));

    // exceed half window
    try out_stream.stream.write("3456789");
    debug.assert(mem.eql(u8, out_stream.windowSlice(), "23456789"));

    // exceed double window
    try out_stream.stream.write("abcdefg");
    debug.assert(mem.eql(u8, out_stream.windowSlice(), "9abcdefg"));

    // full window overwrite
    try out_stream.stream.write("hijklmnopqrstuvwxyz");
    debug.assert(mem.eql(u8, out_stream.windowSlice(), "stuvwxyz"));

    debug.assert(mem.eql(u8, output.toSliceConst(), "0123456789abcdefghijklmnopqrstuvwxyz"));
}
