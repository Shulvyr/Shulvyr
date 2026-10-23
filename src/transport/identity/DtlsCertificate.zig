const std = @import("std");
const buffer = @import("../buffer.zig");
const Certificate = @This();
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const signature_algorithm = "\x30\x0a\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x02";
const key_algorithm = "\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07";
const name = "\x30\x17\x31\x15\x30\x13\x06\x03\x55\x04\x03\x0c\x0cShulvyr DTLS";
// Critical CA:false basic constraints and digitalSignature key usage.
const extensions = "\xa3\x20\x30\x1e" ++
    "\x30\x0c\x06\x03\x55\x1d\x13\x01\x01\xff\x04\x02\x30\x00" ++
    "\x30\x0e\x06\x03\x55\x1d\x0f\x01\x01\xff\x04\x04\x03\x02\x07\x80";

pub const Parameters = struct { now: i64, lifetime_seconds: u32 = 86400 };
pub const max_der_bytes = 512;
pub const max_certificate_pem_bytes = 768;
pub const max_private_key_pem_bytes = 256;
const latest_time = 253402300799; // Last second of year 9999.

der: [max_der_bytes]u8,
der_length: u16,
secret: [32]u8,
public_key: [65]u8,
not_before: i64,
not_after: i64,
active: bool,

/// Owns one ephemeral P-256 DTLS key and its self-signed X.509 certificate.
/// Do not copy this owner. It is separate from the persistent operator key.
/// Generation uses Zig's CSPRNG and crypto, without files or native providers.
pub fn generate(io: std.Io, parameters: Parameters) !Certificate {
    if (parameters.now < 0 or parameters.now > latest_time or parameters.lifetime_seconds == 0 or parameters.lifetime_seconds > 30 * 86400)
        return error.InvalidCertificateLifetime;
    const expiry = std.math.add(i64, parameters.now, parameters.lifetime_seconds) catch return error.InvalidCertificateLifetime;
    if (expiry > latest_time) return error.InvalidCertificateLifetime;
    var pair = Ecdsa.KeyPair.generate(io);
    defer std.crypto.secureZero(u8, &pair.secret_key.bytes);
    var serial: [16]u8 = undefined;
    io.random(&serial);
    serial[0] = (serial[0] & 0x7f) | 1;
    var serial_der: [18]u8 = undefined;
    const serial_number = try element(&serial_der, 0x02, &.{&serial});
    var before_buffer: [17]u8 = undefined;
    var after_buffer: [17]u8 = undefined;
    const before = try time(&before_buffer, parameters.now);
    const after = try time(&after_buffer, expiry);
    var validity_buffer: [36]u8 = undefined;
    const validity = try element(&validity_buffer, 0x30, &.{ before, after });
    const public = pair.public_key.toUncompressedSec1();
    var point_buffer: [68]u8 = undefined;
    const point = try element(&point_buffer, 0x03, &.{ &.{0}, &public });
    var spki_buffer: [91]u8 = undefined;
    const spki = try element(&spki_buffer, 0x30, &.{ key_algorithm, point });
    var tbs_buffer: [384]u8 = undefined;
    const tbs = try element(&tbs_buffer, 0x30, &.{ "\xa0\x03\x02\x01\x02", serial_number, signature_algorithm, name, validity, name, spki, extensions });
    var noise: [Ecdsa.noise_length]u8 = undefined;
    io.random(&noise);
    defer std.crypto.secureZero(u8, &noise);
    var signature_buffer: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const signature = (try pair.sign(tbs, noise)).toDer(&signature_buffer);
    var bits_buffer: [75]u8 = undefined;
    const bits = try element(&bits_buffer, 0x03, &.{ &.{0}, signature });
    var result: Certificate = .{ .der = @splat(0), .der_length = 0, .secret = pair.secret_key.bytes, .public_key = public, .not_before = parameters.now, .not_after = expiry, .active = true };
    errdefer result.deinit();
    result.der_length = @intCast((try element(&result.der, 0x30, &.{ tbs, signature_algorithm, bits })).len);
    return result;
}

pub fn deinit(self: *Certificate) void {
    std.crypto.secureZero(u8, std.mem.asBytes(self));
}

pub fn validateTime(self: *const Certificate, now: i64) !void {
    if (!self.active) return error.DtlsCertificateDestroyed;
    if (now < self.not_before) return error.CertificateNotYetValid;
    if (now > self.not_after) return error.CertificateExpired;
}

/// Public DER borrows the owner until deinit. Never treat this as a CA identity.
pub fn derBytes(self: *const Certificate) ![]const u8 {
    if (!self.active) return error.DtlsCertificateDestroyed;
    return self.der[0..self.der_length];
}

/// DTLS hashes the complete DER certificate, unlike the operator's SPKI pin.
pub fn fingerprint(self: *const Certificate) ![32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try self.derBytes(), &result, .{});
    return result;
}

/// Returns a sentinel-terminated PEM view in caller storage. Failure preserves
/// output. The output must not overlap the owner, including its secret scalar.
pub fn writeCertificatePem(self: *const Certificate, output: []u8) ![:0]const u8 {
    const der = try self.derBytes();
    if (buffer.overlaps(output, std.mem.asBytes(self))) return error.AliasedBuffer;
    return pem(output, der, "-----BEGIN CERTIFICATE-----\n", "-----END CERTIFICATE-----\n");
}

/// Explicit sensitive PKCS#8 export for a synchronous provider import. The
/// caller must clear its output and ensure the provider copies it before return.
pub fn writePrivateKeyPem(self: *const Certificate, output: []u8) ![:0]const u8 {
    if (!self.active) return error.DtlsCertificateDestroyed;
    if (buffer.overlaps(output, std.mem.asBytes(self))) return error.AliasedBuffer;
    const prefix = "\x30\x81\x87\x02\x01\x00" ++ key_algorithm ++ "\x04\x6d\x30\x6b\x02\x01\x01\x04\x20";
    var der: [138]u8 = undefined;
    defer std.crypto.secureZero(u8, &der);
    @memcpy(der[0..prefix.len], prefix);
    @memcpy(der[prefix.len..][0..32], &self.secret);
    @memcpy(der[prefix.len + 32 ..][0..5], "\xa1\x44\x03\x42\x00");
    @memcpy(der[prefix.len + 37 ..], &self.public_key);
    return pem(output, &der, "-----BEGIN PRIVATE KEY-----\n", "-----END PRIVATE KEY-----\n");
}

fn pem(output: []u8, der: []const u8, begin: []const u8, end: []const u8) ![:0]const u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_length = encoder.calcSize(der.len);
    const length = begin.len + encoded_length + (std.math.divCeil(usize, encoded_length, 64) catch unreachable);
    const required = length + end.len;
    if (output.len < required + 1) return error.NoSpace;
    var encoded_buffer: [684]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded_buffer);
    const encoded = encoder.encode(&encoded_buffer, der);
    var position: usize = 0;
    append(output, &position, begin);
    var offset: usize = 0;
    while (offset < encoded.len) {
        const count = @min(64, encoded.len - offset);
        append(output, &position, encoded[offset..][0..count]);
        append(output, &position, "\n");
        offset += count;
    }
    append(output, &position, end);
    output[position] = 0;
    return output[0..position :0];
}

fn element(output: []u8, tag: u8, parts: []const []const u8) ![]const u8 {
    var length: usize = 0;
    for (parts) |part| length = std.math.add(usize, length, part.len) catch return error.NoSpace;
    if (length > 65535) return error.NoSpace;
    const header: usize = if (length < 128) 2 else if (length < 256) 3 else 4;
    if (output.len < header + length) return error.NoSpace;
    output[0] = tag;
    switch (header) {
        2 => output[1] = @intCast(length),
        3 => {
            output[1] = 0x81;
            output[2] = @intCast(length);
        },
        4 => {
            output[1] = 0x82;
            output[2] = @intCast(length >> 8);
            output[3] = @truncate(length);
        },
        else => unreachable,
    }
    var position = header;
    for (parts) |part| append(output, &position, part);
    return output[0..position];
}

fn time(output: *[17]u8, seconds: i64) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    var digits: [15]u8 = undefined;
    const text = try std.fmt.bufPrint(&digits, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{ day.year, month.month.numeric(), @as(u8, month.day_index) + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute() });
    return element(output, if (day.year < 2050) 0x17 else 0x18, &.{if (day.year < 2050) text[2..] else text});
}

fn append(output: []u8, position: *usize, bytes: []const u8) void {
    @memcpy(output[position.*..][0..bytes.len], bytes);
    position.* += bytes.len;
}

pub fn format(_: *const Certificate, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("DtlsCertificate(redacted)");
}
