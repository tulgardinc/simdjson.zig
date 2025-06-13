const std = @import("std");

const TestDeser = struct {
    key1: std.BoundedArray(u8, 64),
    key2: std.BoundedArray(u8, 64),
    key3: std.BoundedArray(u8, 64),
    key4: std.BoundedArray(u8, 64),

    pub fn init() !TestDeser {
        return .{
            .key1 = try .init(0),
            .key2 = try .init(0),
            .key3 = try .init(0),
            .key4 = try .init(0),
        };
    }
};

const Tokens = struct {
    const max_tokens = 64;

    token_chars: [max_tokens]u8 = undefined,
    token_idxes: [max_tokens]usize = undefined,
    len: usize = 0,

    const Self = @This();

    pub fn append(self: *Self, char: u8, idx: usize) !void {
        if (self.len == max_tokens) return error.BufferOverflow;
        self.token_chars[self.len] = char;
        self.token_idxes[self.len] = idx;
        self.len += 1;
    }
};

const JSONTypes = enum {
    string,
};

fn deserialize_to_struct(T: type, strct: *T, key: []const u8, value: anytype, value_type: JSONTypes) !void {
    const fields = @typeInfo(T).@"struct".fields;

    inline for (fields) |field| {
        if (std.mem.eql(u8, key, field.name)) {
            if (value_type == .string) {
                const slice: []const u8 = value;
                if (@field(strct, field.name).buffer.len - @field(strct, field.name).len < slice.len) {
                    return error.WrongValueType;
                }

                try @field(strct, field.name).appendSlice(value);
                return;
            }

            return;
        }
    }

    return error.KeyNotFound;
}

test "simd" {
    const data = "{\"key1\": \"val1\", \"key2\": \"val2\", \"key3\": \"val3\", \"key4\": \"val4\"}";

    // len must be a power of 64 in prod and power of 8 here
    var buffer: [512]u8 = .{' '} ** 512;
    @memcpy(buffer[0..data.len], data);

    const chunk_len = 8;

    var chunk_ptr: ?*const @Vector(chunk_len, u8) = null;

    var deser_struct: TestDeser = try TestDeser.init();

    var tokens: Tokens = .{};

    var simd_index: usize = 0;
    while (simd_index < data.len) : (simd_index += chunk_len) {
        chunk_ptr = @ptrCast(@alignCast(buffer[simd_index .. simd_index + chunk_len]));
        const token_chars = [_]u8{ ':', '"', ',', '{', '}' };

        const ChunkInt = std.meta.Int(.unsigned, chunk_len);

        var has_char: @Vector(chunk_len, u1) = @splat(0);

        for (token_chars) |char| {
            const mask: @Vector(chunk_len, u8) = @splat(char);
            has_char |= @bitCast(chunk_ptr.?.* == mask);
        }

        var trailing_zeros: usize = @intCast(@ctz(@as(ChunkInt, @bitCast(has_char))));

        while (trailing_zeros < chunk_len) : ({
            const HasQuotesInt = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(has_char)));
            has_char &= @bitCast(@as(HasQuotesInt, @bitCast(has_char)) - 1);
            trailing_zeros = @intCast(@as(u8, @intCast(@ctz(@as(HasQuotesInt, @bitCast(has_char))))));
        }) {
            const index = simd_index + trailing_zeros;
            try tokens.append(data[index], index);
        }
    }

    if (tokens.token_chars[0] != '{' or
        tokens.token_idxes[0] != 0 or
        tokens.token_chars[tokens.len - 1] != '}' or
        tokens.token_idxes[tokens.len - 1] != data.len - 1)
    {
        return error.InvalidJson;
    }

    var token_index: usize = 1;
    while (token_index < tokens.len - 1) {
        if (tokens.token_chars[token_index] != '"') return error.InvalidJson;
        const key_start_index = tokens.token_idxes[token_index] + 1;
        if (tokens.token_chars[token_index + 1] != '"') return error.InvalidJson;
        const key_end_index = tokens.token_idxes[token_index + 1];

        if (tokens.token_chars[token_index + 2] != ':') return error.InvalidJson;

        const next_token = tokens.token_chars[token_index + 3];
        switch (next_token) {
            ',' => unreachable, //digit
            '[' => unreachable, //array
            '{' => unreachable, //json
            '"' => {
                // string
                const val_start_index = tokens.token_idxes[token_index + 3] + 1;
                if (tokens.token_chars[token_index + 4] != '"') return error.InvalidJson;
                const val_end_index = tokens.token_idxes[token_index + 4];

                try deserialize_to_struct(
                    TestDeser,
                    &deser_struct,
                    data[key_start_index..key_end_index],
                    data[val_start_index..val_end_index],
                    .string,
                );

                if (tokens.token_chars[token_index + 5] == ',') {
                    token_index += 6;
                } else {
                    token_index += 5;
                }
            },
            else => return error.InvalidJson,
        }
    }

    inline for (@typeInfo(TestDeser).@"struct".fields) |field| {
        std.debug.print("key: {s}, val: {s}\n", .{ field.name, @field(deser_struct, field.name).slice() });
    }
}
