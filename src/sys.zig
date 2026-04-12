/// System interface for libghostty — PNG decoder and logging.
const std = @import("std");
const gt = @import("ghostty.zig");

const stb = @cImport({
    @cInclude("stb_image.h");
});

/// PNG decode callback for libghostty's kitty graphics support.
/// Decodes raw PNG bytes into RGBA pixels, allocating via the
/// provided ghostty allocator.
fn decodePng(
    _: ?*anyopaque,
    allocator: ?*const gt.c.GhosttyAllocator,
    data: [*c]const u8,
    data_len: usize,
    out: ?*gt.c.GhosttySysImage,
) callconv(.c) bool {
    const out_ptr = out orelse return false;
    if (data_len == 0) return false;

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load_from_memory(
        data,
        @intCast(data_len),
        &w,
        &h,
        &channels,
        4, // force RGBA
    ) orelse return false;
    defer stb.stbi_image_free(pixels);

    const pixel_len: usize = @intCast(@as(u64, @intCast(w)) * @as(u64, @intCast(h)) * 4);
    const buf = gt.c.ghostty_alloc(allocator, pixel_len) orelse return false;

    @memcpy(buf[0..pixel_len], pixels[0..pixel_len]);

    out_ptr.width = @intCast(w);
    out_ptr.height = @intCast(h);
    out_ptr.data = buf;
    out_ptr.data_len = pixel_len;
    return true;
}

/// Log callback — forwards libghostty log messages to stderr.
fn logCallback(
    _: ?*anyopaque,
    level: gt.c.GhosttySysLogLevel,
    scope: [*c]const u8,
    scope_len: usize,
    message: [*c]const u8,
    message_len: usize,
) callconv(.c) void {
    // Use the built-in stderr logger so messages appear when
    // Emacs is started from a terminal or in *ghostel-debug*.
    const prefix = switch (level) {
        gt.c.GHOSTTY_SYS_LOG_LEVEL_ERROR => "error",
        gt.c.GHOSTTY_SYS_LOG_LEVEL_WARNING => "warn",
        gt.c.GHOSTTY_SYS_LOG_LEVEL_INFO => "info",
        gt.c.GHOSTTY_SYS_LOG_LEVEL_DEBUG => "debug",
        else => "?",
    };
    const scope_str = if (scope_len > 0) scope[0..scope_len] else "ghostty";
    const msg_str = if (message_len > 0) message[0..message_len] else "";
    std.debug.print("[{s}]({s}): {s}\n", .{ prefix, scope_str, msg_str });
}

/// Install system callbacks.  Call once at module init before any
/// terminal is created.
pub fn init() void {
    _ = gt.c.ghostty_sys_set(
        gt.c.GHOSTTY_SYS_OPT_DECODE_PNG,
        @as(?*const anyopaque, @ptrCast(&decodePng)),
    );

    if (@import("builtin").mode == .Debug) {
        _ = gt.c.ghostty_sys_set(
            gt.c.GHOSTTY_SYS_OPT_LOG,
            @as(?*const anyopaque, @ptrCast(&logCallback)),
        );
    }
}
