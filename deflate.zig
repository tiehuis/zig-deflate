// An implementation of the DEFLATE decompression algorithm.
//
// - https://www.ietf.org/rfc/rfc1951.txt
// - https://github.com/madler/zlib/blob/master/contrib/puff/puff.c

const std = @import("std");
const debug = std.debug;
const math = std.math;
const mem = std.mem;
const hash = std.hash;
const io = std.io;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

// Maximum bits in a huffman code.
const max_bits = 15;
// Maximum number of literal/length codes.
const max_lcodes = 286;
// Maximum number of distance codes.
const max_dcodes = 30;
// Maximum code lengths to read.
const max_codes = max_lcodes + max_dcodes;
// Number of fixed literal codes.
const fix_lcodes = 288;

const HuffmanTable = struct {
    // Number of symbols of each length
    count: [max_bits + 1]u16,
    // Symbols ordered by length in the huffman tree
    symbol: [max_codes]u16,
    symbol_len: usize,
    // Whether the table is complete (no gaps)
    is_complete: bool,

    // Generate a huffman table given a list of code lengths representing the set of ordered
    // symbols. It is possible to pass in lengths which over-allocate symbols to huffman encodings
    // in which case an error is returned.
    //
    // If the lengths under-allocate the table is still usable.
    //
    // We require a stack-allocated array to stored symbols since each huffman tree may vary
    // in the number of symbols it encodes. This must live at least as longer as the returned table.
    pub fn init(lengths: []const u16) !HuffmanTable {
        var h = HuffmanTable {
            .count = []const u16 {0} ** (max_bits + 1),
            .symbol = undefined,
            .symbol_len = lengths.len,
            .is_complete = false,
        };

        for (lengths) |sym| {
            h.count[sym] += 1;
        }

        // decode step will fail even though complete
        if (h.count[0] == lengths.len) {
            return h;
        }

        // ensure we are not over-subscribed on any length set
        var left: i32 = 1;
        for (h.count[1..]) |len| {
            left *= 2;
            left -= i32(len);
            if (left < 0) {
                return error.HuffmanTableOverSubscribed;
            }
        }

        // offsets into symbol table for each length for one-pass sorting, e.g. counting sort
        var offsets: [max_bits + 1]u16 = undefined;
        offsets[1] = 0;

        var ii: usize = 1;
        while (ii < max_bits) : (ii += 1) {
            offsets[ii + 1] = offsets[ii] + h.count[ii];
        }

        for (lengths) |len, i| {
            if (len != 0) {
                h.symbol[offsets[len]] = u16(i);
                offsets[len] += 1;
            }
        }

        h.is_complete = left == 0;
        return h;
    }
};

const custom_stream = @import("stream.zig");

// comptime here for errors is slightly ugly, it would be great if we didn't need this and could
// just runtime switch.
pub fn InflateState(comptime InError: type, comptime OutError: type, comptime HashFunction: var) type {
    return struct {
        const Self = this;
        const SlidingWindow = custom_stream.SlidingWindowOutStream(OutError, 1 << 15);

        // Output stream which keeps a 32K sliding window for RLE decoding.
        // TODO: Store the stream instance instead.
        output: SlidingWindow,

        input: &io.InStream(InError),
        read_count: usize,

        hashfn: HashFunction,

        bit_buffer: u16,
        bit_count: u8,

        pub fn init(in_stream: &io.InStream(InError), out_stream: &io.OutStream(OutError)) Self {
            return Self {
                .output = SlidingWindow.init(out_stream),
                .input = in_stream,
                .read_count = 0,
                .hashfn = HashFunction.init(),
                .bit_buffer = 0,
                .bit_count = 0,
            };
        }

        // Read individual unaligned bits from the input stream.
        pub fn readBits(state: &Self, need: u4) !u16 {
            var val = state.bit_buffer;
            while (state.bit_count < need) {
                var b: [1]u8 = undefined;
                _ = try state.input.read(b[0..]);
                state.read_count += 1;

                val |= math.shl(u16, b[0], state.bit_count);
                state.read_count += 1;
                state.bit_count += 8;
            }

            state.bit_buffer = val >> need;
            state.bit_count -= need;

            return u16(val & ((u16(1) << need) - 1));
        }

        // Read a byte without error. Assumes there is sufficient bytes on the stream.
        pub fn readByte(state: &Self) u8 {
            return u8(state.readBits(8) catch unreachable);
        }

        // Decode a single huffman code using the specified table from the stream.
        //
        // TODO: Use fast version.
        pub fn decode(state: &Self, huffman_table: &const HuffmanTable) !u16 {
            // number of bits being decoded
            var code: u16 = 0;
            // first code of length len
            var first: u16 = 0;
            // number of codes of length len
            var count: u16 = 0;
            // index of first code of length len in symbol table
            var index: usize = 0;

            var len: usize = 1;
            while (len <= max_bits) : (len += 1) {
                code |= try state.readBits(1);
                count = huffman_table.count[len];

                // ugly casts
                if (i32(code) - i32(count) < i32(first)) {
                    return huffman_table.symbol[usize(i32(index) + i32(code) - i32(first))];
                }

                index += count;
                first += count;
                first <<= 1;
                code <<= 1;
            }

            return error.RanOutOfHuffmanCodes;
        }

        pub fn decode2(state: &InflateState, huffman_table: &const HuffmanTable) !u16 {
            // number of bits being decoded
            var code: u16 = 0;
            // first code of length len
            var first: u16 = 0;
            // number of codes of length len
            var count: u16 = 0;
            // index of first code of length len in symbol table
            var index: usize = 0;

            var bit_buffer = state.bit_buffer;
            var left = state.bit_count;

            var next_pos: usize = 1;
            var len: u8 = 1;

            while (true) {
                var i: usize = 0;
                while (i < left) : (i += 1) {
                    code |= bit_buffer & 1;
                    bit_buffer >>= 1;

                    count = huffman_table.count[next_pos];
                    next_pos += 1;

                    if (i32(code) - i32(count) < i32(first)) {
                        state.bit_buffer = bit_buffer;
                        state.bit_count = (state.bit_count - len) & 7;
                        return huffman_table.symbol[usize(i32(index) + i32(code) - i32(first))];
                    }

                    index += count;
                    first += count;
                    first <<= 1;
                    code <<= 1;
                    len += 1;
                }

                left = max_bits + 1 - len;
                if (left == 0) {
                    break;
                }

                var b: [1]u8 = undefined;
                try state.input.read(b[0..]);
                state.read_count += 1;

                bit_buffer = b[0];

                if (left > 8) {
                    left = 8;
                }

            }

            return error.RanOutOfHuffmanCodes;
        }

        // Read huffman codes from the stream and decode until end of block.
        fn decodeBlock(state: &Self, length: &const HuffmanTable, distance: &const HuffmanTable) !void {
            // size base for length codes 257..285
            const lens: [29]u16 = []const u16 {
                3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
            };

            // extra bits for length codes 257..285
            const lext: [29]u4 = []const u4 {
                0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
            };

            // offset base for distance codes 0..29
            const dists: [30]u16 = []const u16 {
                1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                8193, 12289, 16385, 24577,
            };

            // extra bits for distance codes 0..29
            const dext: [30]u4 = []const u4 {
                0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
                12, 12, 13, 13,
            };

            while (true) {
                var symbol = try state.decode(length);
                if (symbol < 0) {
                    return error.InvalidSymbol;
                }

                // literal
                if (symbol < 256) {
                    var b: [1] u8 = []u8 { u8(symbol) };
                    state.hashfn.update(b[0..]);
                    try state.output.stream.write(b[0..]);
                }
                // length
                else if (symbol > 256) {
                    symbol -= 257;
                    if (symbol >= 29) {
                        return error.InvalidFixedCode;
                    }

                    const len = lens[symbol] + try state.readBits(lext[symbol]);
                    symbol = try state.decode(distance);
                    if (symbol < 0) {
                        return error.InvalidSymbol;
                    }

                    const dist = dists[symbol] + try state.readBits(dext[symbol]);

                    // Lookback into the output sliding window for the matching run
                    const slice = state.output.windowSlice();
                    const symbol_slice = slice[slice.len - dist .. slice.len - dist + len];

                    state.hashfn.update(symbol_slice);
                    try state.output.stream.write(symbol_slice);
                }
                // end of block
                else {
                    break;
                }
            }
        }

        // A stored block is one stored with no compression. It can be copied directly to output
        // provided a simple length check is maintained in the header.
        pub fn decodeStored(state: &Self) !void {
            state.bit_buffer = 0;
            state.bit_count = 0;

            var b: [4]u8 = undefined;
            _ = try state.input.read(b[0..]);
            state.read_count += 4;

            const l1 = b[0];
            const l2 = b[1];
            const l1_complement = b[2];
            const l2_complement = b[3];

            if (~l1 != l1_complement or ~l2 != l2_complement) {
                return error.StoredLengthDoesNotMatchComplement;
            }

            const len = u16(l1) | (u16(l2) << 8);

            // Read in chunks from input to output, pass from in to out len bytes
            var i: usize = 0;
            // TODO: do in chunks of os page size.
            while (i < len) : (i += 1) {
                var b2: [1]u8 = undefined;
                _ = try state.input.read(b2[0..]);
                state.read_count += 1;

                state.hashfn.update(b2[0..]);
                try state.output.stream.write(b2[0..]);
            }
        }

        // A fixed block is compressed but uses a fixed table as specified in the rfc. This is useful
        // for short data segments where storing an optimal huffman table in the block would cause a
        // greater overhead than using a slightly less optimal table.
        pub fn decodeFixed(state: &Self) !void {
            const literal_table = comptime block: {
                @setEvalBranchQuota(2000);

                var lengths: [fix_lcodes]u16 = undefined;
                {
                    var i: usize = 0;
                    while (i < 144) : (i += 1) {
                        lengths[i] = 8;
                    }
                    while (i < 256) : (i += 1) {
                        lengths[i] = 9;
                    }
                    while (i < 280) : (i += 1) {
                        lengths[i] = 7;
                    }
                    while (i < fix_lcodes) : (i += 1) {
                        lengths[i] = 8;
                    }
                }

                break :block (HuffmanTable.init(lengths) catch unreachable);
            };

            const distance_table = comptime block: {
                var lengths: [max_dcodes]u16 = undefined;
                var i: usize = 0;
                while (i < max_dcodes) : (i += 1) {
                    lengths[i] = 5;
                }

                break :block HuffmanTable.init(lengths) catch unreachable;
            };

            return state.decodeBlock(&literal_table, &distance_table);
        }

        // A dynamic block has the huffman tables embedded at the beginning. These tables are generated
        // by the encoder to be as optimal as possible for each block.
        pub fn decodeDynamic(state: &Self) !void {
            const order: [19]u16 = []const u16 {
                16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
            };

            const nlen = (try state.readBits(5)) + 257;
            const ndist = (try state.readBits(5)) + 1;
            const ncode = (try state.readBits(4)) + 4;

            if (nlen > max_lcodes or ndist > max_dcodes) {
                return error.InvalidHuffmanTableLengths;
            }

            // read code lengths
            var lengths: [max_codes]u16 = undefined;
            {
                var i: usize = 0;
                while (i < ncode) : (i += 1) {
                    lengths[order[i]] = try state.readBits(3);
                }
                while (i < 19) : (i += 1) {
                    lengths[order[i]] = 0;
                }
            }

            // TODO: Store complete status as a flag.
            const length_table = try HuffmanTable.init(lengths[0..19]);
            if (!length_table.is_complete) {
                return error.DecodeTableIsNotComplete;
            }

            // read length and distance tables
            {
                // last length to repeat
                var len: u16 = 0;
                var i: usize = 0;
                while (i < nlen + ndist) {
                    var symbol = try state.decode(&length_table);
                    if (symbol < 0) {
                        return error.InvalidSymbol;
                    }

                    // length in range of table
                    if (symbol < 16) {
                        lengths[i] = symbol;
                        i += 1;
                    }
                    // repeat instruction
                    else {
                        len = 0;
                        // repeat length 3..6 times
                        if (symbol == 16) {
                            if (i == 0) {
                                return error.NoLastLength;
                            }
                            len = lengths[i - 1];
                            symbol = 3 + try state.readBits(2);
                        }
                        // repeat zero 3..10 times
                        else if (symbol == 17) {
                            symbol = 3 + try state.readBits(3);
                        }
                        // repeat zero 11..138 times
                        else {
                            symbol = 11 + try state.readBits(7);
                        }

                        if (i + symbol > nlen + ndist) {
                            return error.TooManyLengths;
                        }

                        // repeat symbol
                        var j: usize = 0;
                        while (j < symbol) : (j += 1) {
                            lengths[i] = len;
                            i += 1;
                        }
                    }
                }
            }

            if (lengths[256] == 0) {
                return error.MissingEndOfBlockCode;
            }

            // huffman table for literal/length codes
            // TODO: Huffman is ok for incomplete table here if single length 1 code.
            const literal_table = try HuffmanTable.init(lengths[0..nlen]);

            // huffman table for distance codes
            const distance_table = try HuffmanTable.init(lengths[nlen..nlen+ndist]);

            return state.decodeBlock(&literal_table, &distance_table);
        }
    };
}

pub fn decompress(comptime InError: type, in_stream: &io.InStream(InError),
                  comptime OutError: type, out_stream: &io.OutStream(OutError),
                  comptime HashFunction: var) !u32 {
    const InflateStateImpl = InflateState(InError, OutError, HashFunction);
    var state = InflateStateImpl.init(in_stream, out_stream);

    while (true) {
        const final = (try state.readBits(1)) != 0;
        const block_type = try state.readBits(2);

        switch (block_type) {
            0 => try state.decodeStored(),
            1 => try state.decodeFixed(),
            2 => try state.decodeDynamic(),
            3 => return error.InvalidBlockType,

            else => unreachable,
        }

        if (final) {
            break;
        }
    }

    return state.hashfn.final();
}

pub fn decompressAlloc(allocator: &Allocator, input: []const u8, comptime HashFunction: var) !ArrayList(u8) {
    var buffer = ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    var in_stream = custom_stream.MemoryInStream.init(input);
    var out_stream = custom_stream.GrowableMemoryOutStream.init(&buffer);

    _ = try decompress(custom_stream.MemoryInStream.Error, &in_stream.stream,
                   custom_stream.GrowableMemoryOutStream.Error, &out_stream.stream, HashFunction);

    return buffer;
}

test "single block stored" {
    const stored = "\x00\x01\x02\x03\x04\x05\x06\x07";
    const data =
        "\x01" ++       // last block, stored
        "\x08\x00" ++   // 8 bytes len
        "\xf7\xff" ++
        stored;

    const result = try decompressAlloc(debug.global_allocator, data, hash.Adler32);
    debug.assert(mem.eql(u8, result.toSliceConst(), stored));
}

test "single fixed" {
    var expected: [256]u8 = undefined;
    for (expected) |*b, i| *b = @truncate(u8, i);

    const data =
        "\x01\x00\x01\xff\xfe\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d" ++
        "\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20" ++
        "\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33" ++
        "\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f\x40\x41\x42\x43\x44\x45\x46" ++
        "\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59" ++
        "\x5a\x5b\x5c\x5d\x5e\x5f\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c" ++
        "\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e\x7f" ++
        "\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92" ++
        "\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5" ++
        "\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8" ++
        "\xb9\xba\xbb\xbc\xbd\xbe\xbf\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb" ++
        "\xcc\xcd\xce\xcf\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde" ++
        "\xdf\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef\xf0\xf1" ++
        "\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff";

    const result = try decompressAlloc(debug.global_allocator, data, hash.Adler32);
    debug.assert(mem.eql(u8, result.toSliceConst(), expected));
}

test "fuzz issue 1" {
    const expected = "\x28\x91\xe0\x7f\x90\x9f\xcc\x71\x6b\x1b";
    const compressed = "\xd3\x98\xf8\xa0\x7e\xc2\xfc\x33\x85\xd9\xd2\x00";

    const result = try decompressAlloc(debug.global_allocator, compressed, hash.Adler32);
    debug.assert(mem.eql(u8, result.toSliceConst(), expected));

}

test "fuzz issue 2" {
    const expected =
        "\x8a\xc6\x8a\xe4\x18\x4a\x84\xf5\x98\x62\xfb\x34";

    const compressed =
        "\xeb\x3a\xd6\xf5\x44\xc2\xab\xe5\xeb\x8c\xa4\xdf\x26\x00";

    const result = try decompressAlloc(debug.global_allocator, compressed, hash.Adler32);
    debug.assert(mem.eql(u8, result.toSliceConst(), expected));
}
