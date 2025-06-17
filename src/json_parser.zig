const std = @import("std");

const TestDeser = struct {
    key1: std.BoundedArray(u8, 64),
    key2: std.BoundedArray(u8, 64),
    key3: bool,
    key4: bool,

    pub fn init() !TestDeser {
        return .{
            .key1 = try .init(0),
            .key2 = try .init(0),
            .key3 = false,
            .key4 = false,
        };
    }
};

const Tokens = struct {
    const max_tokens = 64;

    token_chars: [max_tokens]u8 = undefined,
    token_idxes: [max_tokens]usize = undefined,
    len: usize = 0,

    const Self = @This();

    pub fn append(self: *Self, char: u8, index: usize) !void {
        if (self.len == max_tokens) return error.BufferOverflow;
        self.token_chars[self.len] = char;
        self.token_idxes[self.len] = index;
        self.len += 1;
    }

    pub fn get(self: *const Self, index: usize) struct { char: u8, index: usize } {
        return .{
            .char = self.token_chars[index],
            .index = self.token_idxes[index],
        };
    }
};

const JSONTypes = enum {
    string,
    boolean,
};

fn deserialize_to_struct(T: type, target_struct: *T, key: []const u8, value: anytype, value_type: JSONTypes) !void {
    const fields = @typeInfo(T).@"struct".fields;
    const type_kvs: [fields.len]std.meta.Tuple(&.{ []const u8, JSONTypes }) = comptime blk: {
        var kvs: [fields.len]std.meta.Tuple(&.{ []const u8, JSONTypes }) = undefined;
        for (fields, 0..) |field, i| {
            switch (@typeInfo(field.type)) {
                .bool => {
                    kvs[i] = .{ field.name, .boolean };
                },
                .@"struct" => |strct| {
                    // TODO: Should be more robust
                    var buffer = false;
                    var len = false;
                    for (strct.fields) |inner_field| {
                        switch (@typeInfo(inner_field.type)) {
                            .array => {
                                if (std.mem.eql(u8, inner_field.name, "buffer")) {
                                    buffer = true;
                                }
                            },
                            .int => {
                                if (std.mem.eql(u8, inner_field.name, "len")) {
                                    len = true;
                                }
                            },
                            else => return error.UnrecognizedFieldType,
                        }
                    }
                    if (buffer and len) {
                        kvs[i] = .{ field.name, .string };
                    } else {
                        return error.UnrecognizedFieldType;
                    }
                },
                else => return error.UnrecognizedFieldType,
            }
        }
        break :blk kvs;
    };
    const type_map = std.StaticStringMap(JSONTypes).initComptime(type_kvs);

    inline for (fields) |field| {
        if (std.mem.eql(u8, key, field.name)) {
            if (type_map.get(field.name) != value_type) {
                return error.WrongValueType;
            }

            if (value_type == .string) {
                const slice: []const u8 = value;
                if (@field(target_struct, field.name).buffer.len - @field(target_struct, field.name).len < slice.len) {
                    return error.BufferOverflow;
                }

                try @field(target_struct, field.name).appendSlice(value);
            } else if (value_type == .boolean) {
                @field(target_struct, field.name) = value;
                return;
            }
            return;
        }
    }

    return error.KeyNotFound;
}

test "simd" {
    const data = "{\"key1\": \"val1\", \"key2\": \"val2\", \"key3\": true, \"key4\": false}";

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
        const token_chars = [_]u8{ ':', '"', ',', '{', '}', 't', 'f' };

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
        const key_start = tokens.get(token_index);
        if (key_start.char != '"') return error.InvalidJson;
        const key_start_index = key_start.index + 1;
        var key_end_token_index = token_index + 1;
        var key_end = tokens.get(key_end_token_index);
        while (key_end.char != '"') {
            key_end_token_index += 1;
            if (key_end_token_index >= tokens.len) return error.InvalidJson;
            key_end = tokens.get(key_end_token_index);
        }

        if (tokens.token_chars[token_index + 2] != ':') return error.InvalidJson;

        const next_token = tokens.get(token_index + 3);
        var value_end_token_index: usize = token_index + 3;
        switch (next_token.char) {
            '[' => unreachable, //array
            '{' => unreachable, //json
            't', 'f' => {
                if (std.mem.eql(u8, data[next_token.index .. next_token.index + 4], "true")) {
                    try deserialize_to_struct(
                        TestDeser,
                        &deser_struct,
                        data[key_start_index..key_end.index],
                        true,
                        .boolean,
                    );
                } else if (std.mem.eql(u8, data[next_token.index .. next_token.index + 5], "false")) {
                    try deserialize_to_struct(
                        TestDeser,
                        &deser_struct,
                        data[key_start_index..key_end.index],
                        false,
                        .boolean,
                    );
                } else {
                    return error.InvalidJson;
                }
            },
            '"' => {
                // string
                const val_start_index = next_token.index + 1;
                value_end_token_index = token_index + 4;
                const val_end = tokens.get(value_end_token_index);
                while (val_end.char != '"') {
                    value_end_token_index += 1;
                    if (value_end_token_index >= tokens.len) return error.InvalidJson;
                    key_end = tokens.get(value_end_token_index);
                }

                try deserialize_to_struct(
                    TestDeser,
                    &deser_struct,
                    data[key_start_index..key_end.index],
                    data[val_start_index..val_end.index],
                    .string,
                );
            },
            else => return error.InvalidJson,
        }

        if (tokens.get(value_end_token_index + 1).char == ',') {
            if (tokens.get(value_end_token_index + 2).char != '"')
                return error.InvalidJson;
        } else if (tokens.get(value_end_token_index + 1).char != '}') {
            return error.InvalidJson;
        }

        token_index = value_end_token_index + 2;
    }

    inline for (@typeInfo(TestDeser).@"struct".fields) |field| {
        std.debug.print("key: {s}, val: {s}\n", .{ field.name, @field(deser_struct, field.name).slice() });
    }
}
