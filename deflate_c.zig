const std = @import("std");
const hash = std.hash;
const deflate = @import("deflate.zig");

// max decompress is 4096
var c_output: [8192]u8 = undefined;

export fn zig_decompress(in: &const u8, inlen: usize, out: &&const u8, outlen: &usize) c_int {
    // use a fixed buffer allocator to avoid allocating in the loop
    var fixed_allocator = std.heap.FixedBufferAllocator.init(c_output[0..]);

    var buf = deflate.decompressAlloc(&fixed_allocator.allocator, in[0..inlen], hash.Adler32) catch |err| return -1;
    defer buf.deinit();

    // Array is backed by global c_output array so just use directly
    *out = &c_output[0];
    *outlen = buf.len;
    return 0;
}

