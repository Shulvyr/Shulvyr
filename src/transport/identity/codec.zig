const std = @import("std");
pub const Value = std.json.Value;

pub fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidIdentityObject;
    return value.object.get(name) orelse error.MissingIdentityField;
}

pub fn text(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidIdentityString;
    return value.string;
}

/// Accept padded and unpadded encodings, with canonical pad bits. Decoding may
/// modify destination on failure. Callers use private scratch or owned storage.
pub fn decode(output: []u8, input: []const u8, url: bool) ![]u8 {
    const decoder = if (url)
        (if (std.mem.indexOfScalar(u8, input, '=') != null) std.base64.url_safe.Decoder else std.base64.url_safe_no_pad.Decoder)
    else
        (if (std.mem.indexOfScalar(u8, input, '=') != null) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder);
    const length = decoder.calcSizeForSlice(input) catch return error.InvalidIdentityBase64;
    if (length > output.len) return error.IdentityBytesLimit;
    decoder.decode(output[0..length], input) catch return error.InvalidIdentityBase64;
    return output[0..length];
}

pub fn segments(compact: []const u8) ![3][]const u8 {
    var split = std.mem.splitScalar(u8, compact, '.');
    var result: [3][]const u8 = undefined;
    for (&result) |*part| part.* = split.next() orelse return error.InvalidCompactSignature;
    if (split.next() != null) return error.InvalidCompactSignature;
    return result;
}

pub fn es384Header(header: Value) !void {
    const algorithm = try text(try field(header, "alg"));
    if (!std.mem.eql(u8, algorithm, "ES384")) return error.UnsupportedIdentityAlgorithm;
    // No critical extensions or unencoded-payload mode are implemented.
    if (header.object.contains("crit") or header.object.contains("b64")) return error.UnsupportedIdentityHeader;
}
