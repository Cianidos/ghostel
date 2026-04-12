/// Kitty Graphics Protocol support via the libghostty C API.
///
/// Queries libghostty's authoritative placement and image state during
/// each redraw cycle, converts pixel data to PPM for Emacs display,
/// and calls into Elisp to apply image overlays.
const std = @import("std");
const emacs = @import("emacs.zig");
const Terminal = @import("terminal.zig");
const gt = @import("ghostty.zig");

/// Query all visible kitty graphics placements from libghostty and
/// emit them to Elisp for display.  Called after render_state_update()
/// during each redraw.
pub fn emitPlacements(env: emacs.Env, term: *Terminal) void {
    // Obtain the kitty graphics handle from the terminal.
    var graphics: gt.KittyGraphics = undefined;
    if (gt.c.ghostty_terminal_get(
        term.terminal,
        gt.DATA_KITTY_GRAPHICS,
        @ptrCast(&graphics),
    ) != gt.SUCCESS) return;

    // Create a placement iterator.
    var iterator: gt.KittyGraphicsPlacementIterator = undefined;
    if (gt.c.ghostty_kitty_graphics_placement_iterator_new(null, &iterator) != gt.SUCCESS) return;
    defer gt.c.ghostty_kitty_graphics_placement_iterator_free(iterator);

    // Populate it from the storage.
    if (gt.c.ghostty_kitty_graphics_get(
        graphics,
        gt.c.GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
        @ptrCast(&iterator),
    ) != gt.SUCCESS) return;

    // Iterate over all placements.
    while (gt.c.ghostty_kitty_graphics_placement_next(iterator)) {
        emitOnePlacement(env, term, graphics, iterator) catch continue;
    }
}

fn emitOnePlacement(
    env: emacs.Env,
    term: *Terminal,
    graphics: gt.KittyGraphics,
    iterator: gt.KittyGraphicsPlacementIterator,
) !void {
    // Get image ID and check if virtual.
    var image_id: u32 = 0;
    var is_virtual: bool = false;
    if (gt.c.ghostty_kitty_graphics_placement_get(
        iterator,
        gt.c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
        @ptrCast(&image_id),
    ) != gt.SUCCESS) return error.PlacementQuery;
    _ = gt.c.ghostty_kitty_graphics_placement_get(
        iterator,
        gt.c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
        @ptrCast(&is_virtual),
    );

    // Look up the image.
    const image = gt.c.ghostty_kitty_graphics_image(graphics, image_id) orelse return error.ImageNotFound;

    if (is_virtual) {
        // Virtual placements (yazi-style U+10EEEE unicode placeholders).
        // The API doesn't provide viewport positions — Elisp searches
        // the buffer for placeholder characters.
        const emacs_data = try getImageData(image);
        defer if (emacs_data.allocated) std.heap.c_allocator.free(emacs_data.data);

        const img_val = env.makeUnibyteString(emacs_data.data) orelse return error.MakeString;
        var args = [_]emacs.Value{
            img_val,
            if (emacs_data.is_png) env.intern("t") else env.nil(),
        };
        _ = env.funcall(emacs.sym.@"ghostel--kitty-display-virtual", &args);
        return;
    }

    // Non-virtual: get render info for viewport position.
    var info = std.mem.zeroes(gt.KittyGraphicsPlacementRenderInfo);
    info.size = @sizeOf(gt.KittyGraphicsPlacementRenderInfo);
    if (gt.c.ghostty_kitty_graphics_placement_render_info(
        iterator,
        image,
        term.terminal,
        &info,
    ) != gt.SUCCESS) return error.RenderInfo;

    if (!info.viewport_visible) return error.NotVisible;

    const emacs_data = try getImageData(image);
    defer if (emacs_data.allocated) std.heap.c_allocator.free(emacs_data.data);

    const img_val = env.makeUnibyteString(emacs_data.data) orelse return error.MakeString;
    var args = [_]emacs.Value{
        img_val,
        if (emacs_data.is_png) env.intern("t") else env.nil(),
        env.makeInteger(@intCast(info.viewport_row)),
        env.makeInteger(@intCast(info.viewport_col)),
        env.makeInteger(@intCast(info.grid_cols)),
        env.makeInteger(@intCast(info.grid_rows)),
        env.makeInteger(@intCast(info.pixel_width)),
        env.makeInteger(@intCast(info.pixel_height)),
    };
    _ = env.funcall(emacs.sym.@"ghostel--kitty-display-image", &args);
}

const ImageData = struct {
    data: []const u8,
    is_png: bool,
    allocated: bool,
};

fn getImageData(image: gt.KittyGraphicsImage) !ImageData {
    var format: gt.KittyImageFormat = undefined;
    var img_width: u32 = 0;
    var img_height: u32 = 0;
    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = 0;

    const keys = [_]gt.c.GhosttyKittyGraphicsImageData{
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN,
    };
    var values = [_]?*anyopaque{
        @ptrCast(&format),
        @ptrCast(&img_width),
        @ptrCast(&img_height),
        @ptrCast(&data_ptr),
        @ptrCast(&data_len),
    };
    if (gt.c.ghostty_kitty_graphics_image_get_multi(
        image,
        keys.len,
        &keys,
        @ptrCast(&values),
        null,
    ) != gt.SUCCESS) return error.ImageData;

    if (data_len == 0 or img_width == 0 or img_height == 0) return error.EmptyImage;

    const pixel_data = data_ptr[0..data_len];
    return switch (format) {
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_PNG => .{ .data = pixel_data, .is_png = true, .allocated = false },
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => .{
            .data = createPpm(pixel_data, img_width, img_height, 4) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_RGB => .{
            .data = createPpm(pixel_data, img_width, img_height, 3) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => .{
            .data = createPpm(pixel_data, img_width, img_height, 2) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => .{
            .data = createPpm(pixel_data, img_width, img_height, 1) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        else => return error.UnsupportedFormat,
    };
}

/// Convert raw pixel data to PPM (P6) format for Emacs.
/// Supports 1 (gray), 2 (gray+alpha), 3 (RGB), and 4 (RGBA) channels.
/// Alpha channel is discarded.  Returns an allocated slice.
fn createPpm(data: []const u8, width: u32, height: u32, channels: u32) ?[]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const expected = w * h * channels;
    if (data.len < expected) return null;

    // PPM header
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ w, h }) catch return null;

    const rgb_len = w * h * 3;
    const buf = std.heap.c_allocator.alloc(u8, header.len + rgb_len) catch return null;
    @memcpy(buf[0..header.len], header);

    var dst = buf[header.len..];
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        const src_off = i * channels;
        switch (channels) {
            1 => {
                const g = data[src_off];
                dst[i * 3 + 0] = g;
                dst[i * 3 + 1] = g;
                dst[i * 3 + 2] = g;
            },
            2 => {
                const g = data[src_off];
                dst[i * 3 + 0] = g;
                dst[i * 3 + 1] = g;
                dst[i * 3 + 2] = g;
            },
            3 => {
                dst[i * 3 + 0] = data[src_off + 0];
                dst[i * 3 + 1] = data[src_off + 1];
                dst[i * 3 + 2] = data[src_off + 2];
            },
            4 => {
                dst[i * 3 + 0] = data[src_off + 0];
                dst[i * 3 + 1] = data[src_off + 1];
                dst[i * 3 + 2] = data[src_off + 2];
            },
            else => return null,
        }
    }

    return buf;
}
