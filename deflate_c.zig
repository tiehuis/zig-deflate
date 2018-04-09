const std = @import("std");
const hash = std.hash;
const deflate = @import("deflate.zig");

// max decompress is 4096
var c_output: [8192 * 1024]u8 = undefined;

export fn zig_decompress(in: &const u8, inlen: usize, out: &u8, outlen: &usize) c_int {
    // use a fixed buffer allocator to avoid allocating in the loop
    var fixed_allocator = std.heap.FixedBufferAllocator.init(c_output[0..]);

    var buf = deflate.decompressAlloc(&fixed_allocator.allocator, in[0..inlen], hash.Adler32) catch |err| {
        std.debug.warn("{}\n", err);
        return -1;
    };
    defer buf.deinit();

    for (buf.toSliceConst()) |b, i| out[i] = b;
    *outlen = buf.len;

    return 0;
}

