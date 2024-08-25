const std = @import("std");
const build_options = @import("build-options");
const mach = @import("mach");
const gpu = mach.gpu;
const imgui = @import("imgui");
const imgui_mach = imgui.backends.mach;

pub const name = .app;
pub const Mod = mach.Mod(@This());

pub const systems = .{
    .init = .{ .handler = init },
    .after_init = .{ .handler = afterInit },
    .deinit = .{ .handler = deinit },
    .tick = .{ .handler = tick },
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator: std.mem.Allocator = undefined;
var f: f32 = 0.0;
var color: [3]f32 = undefined;

title_timer: mach.Timer,

pub fn deinit(core: *mach.Core.Mod, game: *Mod) void {
    _ = game;
    imgui_mach.shutdown();
    imgui.destroyContext(null);
    core.schedule(.deinit);
    _ = gpa.deinit();
}

fn init(game: *Mod, core: *mach.Core.Mod) !void {
    core.schedule(.init);
    game.schedule(.after_init);
}

fn afterInit(game: *Mod, core: *mach.Core.Mod) !void {
    allocator = gpa.allocator();

    imgui.setZigAllocator(&allocator);
    _ = imgui.createContext(null);
    try imgui_mach.init(allocator, core.state().device, .{});

    var io = imgui.getIO();
    io.config_flags |= imgui.ConfigFlags_NavEnableKeyboard;
    io.font_global_scale = 1.0 / io.display_framebuffer_scale.y;

    const font_data = @embedFile("Roboto-Medium.ttf");
    const size_pixels = 12 * io.display_framebuffer_scale.y;

    var font_cfg: imgui.FontConfig = std.mem.zeroes(imgui.FontConfig);
    font_cfg.font_data_owned_by_atlas = false;
    font_cfg.oversample_h = 2;
    font_cfg.oversample_v = 1;
    font_cfg.glyph_max_advance_x = std.math.floatMax(f32);
    font_cfg.rasterizer_multiply = 1.0;
    font_cfg.rasterizer_density = 1.0;
    font_cfg.ellipsis_char = imgui.UNICODE_CODEPOINT_MAX;
    _ = io.fonts.?.addFontFromMemoryTTF(@constCast(@ptrCast(font_data.ptr)), font_data.len, size_pixels, &font_cfg, null);

    // Store our render pipeline in our module's state, so we can access it later on.
    game.init(.{
        .title_timer = try mach.Timer.start(),
    });
    try updateWindowTitle(core);

    core.schedule(.start);
}

fn tick(core: *mach.Core.Mod, game: *Mod) !void {
    var iter = mach.core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .close => core.schedule(.exit),
            else => {
                _ = imgui_mach.processEvent(event);
            },
        }
    }

    try render(core);

    if (game.state().title_timer.read() >= 1.0) {
        game.state().title_timer.reset();
        try updateWindowTitle(core);
    }
}

fn updateWindowTitle(core: *mach.Core.Mod) !void {
    try mach.Core.printTitle(
        core,
        core.state().main_window,
        "ImGui [ {d}fps ] [ Input {d}hz ]",
        .{
            // TODO(Core)
            mach.core.frameRate(),
            mach.core.inputRate(),
        },
    );
    core.schedule(.update);
}

fn render(core: *mach.Core.Mod) !void {
    const io = imgui.getIO();

    imgui_mach.newFrame() catch return;
    imgui.newFrame();

    imgui.text("Hello, world!");
    _ = imgui.sliderFloat("float", &f, 0.0, 1.0);
    _ = imgui.colorEdit3("color", &color, imgui.ColorEditFlags_None);
    imgui.text("Application average %.3f ms/frame (%.1f FPS)", 1000.0 / io.framerate, io.framerate);
    imgui.showDemoWindow(null);

    imgui.render();

    const back_buffer_view = mach.core.swap_chain.getCurrentTextureView().?;
    defer back_buffer_view.release();

    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = gpu.Color{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 },
        .load_op = .clear,
        .store_op = .store,
    };

    const label = @tagName(name) ++ ".tick";
    const encoder = core.state().device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
    });

    const pass = encoder.beginRenderPass(&render_pass_info);
    defer pass.release();
    imgui_mach.renderDrawData(imgui.getDrawData().?, pass) catch {};
    pass.end();

    var command = encoder.finish(null);
    defer command.release();

    var queue = core.state().queue;
    queue.submit(&[_]*gpu.CommandBuffer{command});
    core.schedule(.present_frame);
}
