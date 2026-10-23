pub fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const left = @intFromPtr(a.ptr);
    const right = @intFromPtr(b.ptr);
    return if (left <= right) right - left < a.len else left - right < b.len;
}
