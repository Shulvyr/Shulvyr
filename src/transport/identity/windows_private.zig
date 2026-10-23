const std = @import("std");
const w = std.os.windows;
const Io = std.Io;

const Acl = extern struct { revision: u8, reserved: u8, size: u16, count: u16, reserved2: u16 };
const Descriptor = extern struct { revision: u8, reserved: u8, control: u16, owner: ?*anyopaque, group: ?*anyopaque, sacl: ?*Acl, dacl: ?*Acl };
const TokenUser = extern struct { sid: *anyopaque, attributes: u32 };
const Ace = extern struct { kind: u8, flags: u8, size: u16, mask: u32, sid_start: u32 };
const all_access: u32 = 0x1f01ff;

extern "advapi32" fn OpenProcessToken(w.HANDLE, u32, *w.HANDLE) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetTokenInformation(w.HANDLE, c_int, *anyopaque, u32, *u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn InitializeAcl(*Acl, u32, u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn AddAccessAllowedAce(*Acl, u32, u32, *anyopaque) callconv(.winapi) w.BOOL;
extern "advapi32" fn InitializeSecurityDescriptor(*Descriptor, u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn SetSecurityDescriptorOwner(*Descriptor, *anyopaque, w.BOOL) callconv(.winapi) w.BOOL;
extern "advapi32" fn SetSecurityDescriptorDacl(*Descriptor, w.BOOL, *Acl, w.BOOL) callconv(.winapi) w.BOOL;
extern "advapi32" fn SetSecurityDescriptorControl(*Descriptor, u16, u16) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetSecurityInfo(w.HANDLE, c_int, u32, *?*anyopaque, ?*?*anyopaque, *?*Acl, ?*?*Acl, *?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn GetSecurityDescriptorControl(*anyopaque, *u16, *u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn IsValidSecurityDescriptor(*anyopaque) callconv(.winapi) w.BOOL;
extern "advapi32" fn IsValidSid(*anyopaque) callconv(.winapi) w.BOOL;
extern "advapi32" fn EqualSid(*anyopaque, *anyopaque) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetAce(*Acl, u32, *?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;

/// Contains internal pointers into its buffers. Initialize at its final address
/// and do not copy it. Only the process account is allowed by newly created ACLs.
const Security = struct {
    token: [4096]u8 align(@alignOf(TokenUser)) = undefined,
    acl_bytes: [128]u8 align(@alignOf(Acl)) = undefined,
    descriptor: Descriptor = undefined,
    sid: *anyopaque = undefined,

    fn init(self: *Security) !void {
        var token: w.HANDLE = undefined;
        if (!OpenProcessToken(w.GetCurrentProcess(), 0x8, &token).toBool()) return error.KeyStoreAccountUnavailable;
        defer w.CloseHandle(token);
        var needed: u32 = 0;
        if (!GetTokenInformation(token, 1, &self.token, self.token.len, &needed).toBool() or needed > self.token.len or needed < @sizeOf(TokenUser)) return error.KeyStoreAccountUnavailable;
        const user: *const TokenUser = @ptrCast(&self.token);
        self.sid = user.sid;
        if (!IsValidSid(self.sid).toBool()) return error.KeyStoreAccountUnavailable;
        const acl: *Acl = @ptrCast(&self.acl_bytes);
        if (!InitializeAcl(acl, self.acl_bytes.len, 2).toBool() or !AddAccessAllowedAce(acl, 2, all_access, self.sid).toBool()) return error.KeyStoreSecurityUnavailable;
        if (!InitializeSecurityDescriptor(&self.descriptor, 1).toBool() or
            !SetSecurityDescriptorOwner(&self.descriptor, self.sid, .FALSE).toBool() or
            !SetSecurityDescriptorDacl(&self.descriptor, .TRUE, acl, .FALSE).toBool() or
            !SetSecurityDescriptorControl(&self.descriptor, 0x1000, 0x1000).toBool()) return error.KeyStoreSecurityUnavailable;
    }

    fn validate(self: *const Security, handle: w.HANDLE) !void {
        var owner: ?*anyopaque = null;
        var acl: ?*Acl = null;
        var descriptor: ?*anyopaque = null;
        if (GetSecurityInfo(handle, 1, 0x1 | 0x4, &owner, null, &acl, null, &descriptor) != 0) return error.KeyStoreSecurityUnavailable;
        defer _ = LocalFree(descriptor);
        const sd = descriptor orelse return error.InsecureKeyStore;
        var control: u16 = 0;
        var revision: u32 = 0;
        if (!IsValidSecurityDescriptor(sd).toBool() or !GetSecurityDescriptorControl(sd, &control, &revision).toBool() or revision != 1 or control & 0x1004 != 0x1004) return error.InsecureKeyStore;
        const actual_owner = owner orelse return error.InsecureKeyStore;
        if (!EqualSid(self.sid, actual_owner).toBool()) return error.InsecureKeyStore;
        const entries = acl orelse return error.InsecureKeyStore;
        if (entries.count != 1) return error.InsecureKeyStore;
        var raw: ?*anyopaque = null;
        if (!GetAce(entries, 0, &raw).toBool()) return error.InsecureKeyStore;
        const ace: *const Ace = @ptrCast(@alignCast(raw orelse return error.InsecureKeyStore));
        if (ace.kind != 0 or ace.flags != 0 or ace.mask != all_access or ace.size < @sizeOf(Ace)) return error.InsecureKeyStore;
        const sid = @as(*anyopaque, @ptrCast(@constCast(&ace.sid_start)));
        if (!IsValidSid(sid).toBool() or !EqualSid(self.sid, sid).toBool()) return error.InsecureKeyStore;
    }
};

pub fn openDirectory(parent: Io.Dir, name: []const u8, create: bool) !Io.Dir {
    var security: Security = undefined;
    try security.init();
    const handle = open(parent, name, true, create, &security.descriptor) catch |err| switch (err) {
        error.PathAlreadyExists => if (create) try open(parent, name, true, false, null) else return err,
        else => return err,
    };
    errdefer w.CloseHandle(handle);
    try security.validate(handle);
    return .{ .handle = handle };
}

pub fn openFile(parent: Io.Dir, name: []const u8, create: bool) !Io.File {
    var security: Security = undefined;
    try security.init();
    const handle = try open(parent, name, false, create, &security.descriptor);
    errdefer w.CloseHandle(handle);
    try security.validate(handle);
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

pub fn validate(handle: w.HANDLE) !void {
    var security: Security = undefined;
    try security.init();
    try security.validate(handle);
}

pub fn syncDirectory(io: Io, directory: Io.Dir) !void {
    try io.checkCancel();
    const handle = try open(directory, "", true, false, null);
    defer w.CloseHandle(handle);
    var status_block: w.IO_STATUS_BLOCK = undefined;
    switch (w.ntdll.NtFlushBuffersFile(handle, &status_block)) {
        .SUCCESS => {},
        .CANCELLED => return error.Canceled,
        .ACCESS_DENIED => return error.KeyStoreSyncDenied,
        else => return error.KeyStoreDirectorySyncUnsupported,
    }
}

fn open(parent: Io.Dir, name: []const u8, directory: bool, create: bool, descriptor: ?*Descriptor) !w.HANDLE {
    var name_buffer: [240]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&name_buffer, name);
    var text: w.UNICODE_STRING = .init(name_buffer[0..length]);
    const attributes: w.OBJECT.ATTRIBUTES = .{
        .RootDirectory = parent.handle,
        .ObjectName = &text,
        .SecurityDescriptor = descriptor,
    };
    var status_block: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const status = w.ntdll.NtCreateFile(&handle, .{ .GENERIC = .{ .READ = true, .WRITE = true }, .STANDARD = .{ .SYNCHRONIZE = true } }, &attributes, &status_block, null, .{ .NORMAL = true }, if (directory) .VALID_FLAGS else .{}, if (create) .CREATE else .OPEN, .{ .DIRECTORY_FILE = directory, .NON_DIRECTORY_FILE = !directory, .OPEN_REPARSE_POINT = true, .IO = .SYNCHRONOUS_NONALERT }, null, 0);
    return switch (status) {
        .SUCCESS => handle,
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .SHARING_VIOLATION, .FILE_LOCK_CONFLICT => error.KeyStoreBusy,
        .ACCESS_DENIED => error.AccessDenied,
        .NOT_A_DIRECTORY => error.NotDir,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .STOPPED_ON_SYMLINK => error.InsecureKeyStore,
        else => error.KeyStoreOpenFailed,
    };
}
