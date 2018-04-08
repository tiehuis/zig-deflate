const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const io = std.io;

const ArrayList = std.ArrayList;
const InStream = io.InStream;
const OutStream = io.OutStream;

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

pub const GrowableMemoryOutStream = struct {
    buffer: &ArrayList(u8),

    stream: Stream,

    pub const Error = error{OutOfMemory};
    pub const Stream = OutStream(Error);

    pub fn init(buffer: &ArrayList(u8)) GrowableMemoryOutStream {
        return GrowableMemoryOutStream {
            .buffer = buffer,
            .stream = Stream {
                .writeFn = writeFn,
            },
        };
    }

    fn writeFn(out_stream: &Stream, bytes: []const u8) !void {
        const self = @fieldParentPtr(GrowableMemoryOutStream, "stream", out_stream);
        return self.buffer.appendSlice(bytes);
    }
};

test "memory out stream" {
    var output = ArrayList(u8).init(debug.global_allocator);
    defer output.deinit();

    var out_stream = GrowableMemoryOutStream.init(&output);

    try out_stream.stream.writeByte('h');
    debug.assert(mem.eql(u8, output.toSliceConst(), "h"));

    try out_stream.stream.write("ere is some output");
    debug.assert(mem.eql(u8, output.toSliceConst(), "here is some output"));
}
