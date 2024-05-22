const std = @import("std");
const cbor = @import("cbor");
const log = @import("log");
const Style = @import("theme").Style;

const vaxis = @import("vaxis");

pub const input = @import("input.zig");

pub const Plane = @import("Plane.zig");
pub const Cell = @import("Cell.zig");

pub const style = @import("style.zig").StyleBits;

const mod = input.modifier;
const key = input.key;
const event_type = input.event_type;

const Self = @This();
pub const log_name = "vaxis";

a: std.mem.Allocator,

vx: vaxis.Vaxis,

no_alternate: bool,
event_buffer: std.ArrayList(u8),
input_buffer: std.ArrayList(u8),

bracketed_paste: bool = false,
bracketed_paste_buffer: std.ArrayList(u8),

handler_ctx: *anyopaque,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: c_int, x: c_int, dragging: bool, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

logger: log.Logger,

const ModState = struct { ctrl: bool = false, shift: bool = false, alt: bool = false };

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

pub fn init(a: std.mem.Allocator, handler_ctx: *anyopaque, no_alternate: bool) !Self {
    const opts: vaxis.Vaxis.Options = .{
        .kitty_keyboard_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternate_keys = true,
            .report_all_as_ctl_seqs = true,
            .report_text = true,
        },
    };
    return .{
        .a = a,
        .vx = try vaxis.init(a, opts),
        .no_alternate = no_alternate,
        .event_buffer = std.ArrayList(u8).init(a),
        .input_buffer = std.ArrayList(u8).init(a),
        .bracketed_paste_buffer = std.ArrayList(u8).init(a),
        .handler_ctx = handler_ctx,
        .logger = log.logger(log_name),
    };
}

pub fn deinit(self: *Self) void {
    panic_cleanup_tty = null;
    self.vx.deinit(self.a);
    self.bracketed_paste_buffer.deinit();
    self.input_buffer.deinit();
    self.event_buffer.deinit();
}

var panic_cleanup_tty: ?*vaxis.Tty = null;
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (panic_cleanup_tty) |tty| tty.deinit();
    return std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub fn run(self: *Self) !void {
    if (self.vx.tty == null) {
        self.vx.tty = try vaxis.Tty.init();
        panic_cleanup_tty = &(self.vx.tty.?);
    }
    if (!self.no_alternate) try self.vx.enterAltScreen();
    try self.vx.queryTerminalSend();
    const ws = try vaxis.Tty.getWinsize(self.input_fd_blocking());
    try self.vx.resize(self.a, ws);
    self.vx.queueRefresh();
    try self.vx.setMouseMode(.pixels);
    try self.vx.setBracketedPaste(true);
}

pub fn render(self: *Self) !void {
    return self.vx.render();
}

pub fn refresh(self: *Self) !void {
    const ws = try vaxis.Tty.getWinsize(self.input_fd_blocking());
    try self.vx.resize(self.a, ws);
    self.vx.queueRefresh();
}

pub fn stop(self: *Self) void {
    _ = self;
}

pub fn stdplane(self: *Self) Plane {
    const name = "root";
    var plane: Plane = .{
        .window = self.vx.window(),
        .name_buf = undefined,
        .name_len = name.len,
    };
    @memcpy(plane.name_buf[0..name.len], name);
    return plane;
}

pub fn input_fd_blocking(self: Self) i32 {
    return self.vx.tty.?.fd;
}

pub fn leave_alternate_screen(self: *Self) void {
    self.vx.exitAltScreen() catch {};
}

pub fn process_input(self: *Self, input_: []const u8) !void {
    var parser: vaxis.Parser = .{
        .grapheme_data = &self.vx.screen.unicode.grapheme_data,
    };
    try self.input_buffer.appendSlice(input_);
    var buf = self.input_buffer.items;
    defer {
        if (buf.len == 0) {
            self.input_buffer.clearRetainingCapacity();
        } else {
            const rest = self.a.alloc(u8, buf.len) catch |e| std.debug.panic("{any}", .{e});
            @memcpy(rest, buf);
            self.input_buffer.deinit();
            self.input_buffer = std.ArrayList(u8).fromOwnedSlice(self.a, rest);
        }
    }
    while (buf.len > 0) {
        const result = try parser.parse(buf, self.a);
        if (result.n == 0)
            return;
        buf = buf[result.n..];
        const event = result.event orelse continue;
        switch (event) {
            .key_press => |key_| {
                const cbor_msg = try self.fmtmsg(.{
                    "I",
                    event_type.PRESS,
                    key_.codepoint,
                    key_.shifted_codepoint orelse key_.codepoint,
                    key_.text orelse input.utils.key_id_string(key_.base_layout_codepoint orelse key_.codepoint),
                    @as(u8, @bitCast(key_.mods)),
                });
                if (self.bracketed_paste and self.handle_bracketed_paste_input(cbor_msg) catch |e| {
                    self.bracketed_paste_buffer.clearAndFree();
                    self.bracketed_paste = false;
                    return e;
                }) {} else if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
            },
            .key_release => |*key_| {
                const cbor_msg = try self.fmtmsg(.{
                    "I",
                    event_type.RELEASE,
                    key_.codepoint,
                    key_.shifted_codepoint orelse key_.codepoint,
                    key_.text orelse input.utils.key_id_string(key_.base_layout_codepoint orelse key_.codepoint),
                    @as(u8, @bitCast(key_.mods)),
                });
                if (self.bracketed_paste) {} else if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
            },
            .mouse => |mouse| {
                const ypos = mouse.row - 1;
                const xpos = mouse.col - 1;
                const ycell = self.vx.screen.height_pix / self.vx.screen.height;
                const xcell = self.vx.screen.width_pix / self.vx.screen.width;
                const y = ypos / ycell;
                const x = xpos / xcell;
                const ypx = ypos % ycell;
                const xpx = xpos % xcell;
                if (self.dispatch_mouse) |f| switch (mouse.type) {
                    .motion => f(self.handler_ctx, @intCast(y), @intCast(x), try self.fmtmsg(.{
                        "M",
                        x,
                        y,
                        xpx,
                        ypx,
                    })),
                    .press => f(self.handler_ctx, @intCast(y), @intCast(x), try self.fmtmsg(.{
                        "B",
                        event_type.PRESS,
                        @intFromEnum(mouse.button),
                        input.utils.button_id_string(@intFromEnum(mouse.button)),
                        x,
                        y,
                        xpx,
                        ypx,
                    })),
                    .release => f(self.handler_ctx, @intCast(y), @intCast(x), try self.fmtmsg(.{
                        "B",
                        event_type.RELEASE,
                        @intFromEnum(mouse.button),
                        input.utils.button_id_string(@intFromEnum(mouse.button)),
                        x,
                        y,
                        xpx,
                        ypx,
                    })),
                    .drag => if (self.dispatch_mouse_drag) |f_|
                        f_(self.handler_ctx, @intCast(y), @intCast(x), true, try self.fmtmsg(.{
                            "D",
                            event_type.PRESS,
                            @intFromEnum(mouse.button),
                            input.utils.button_id_string(@intFromEnum(mouse.button)),
                            x,
                            y,
                            xpx,
                            ypx,
                        })),
                };
            },
            .focus_in => {
                if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"focus_in"}));
            },
            .focus_out => {
                if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"focus_out"}));
            },
            .paste_start => {
                self.bracketed_paste = true;
                self.bracketed_paste_buffer.clearRetainingCapacity();
            },
            .paste_end => try self.handle_bracketed_paste_end(),
            .paste => |text| {
                defer self.a.free(text);
                if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", text }));
            },
            .cap_unicode => {
                self.logger.print("unicode capability detected", .{});
                self.vx.caps.unicode = .unicode;
                self.vx.screen.width_method = .unicode;
            },
            .cap_da1 => {
                self.vx.enableDetectedFeatures() catch |e| self.logger.err("enable features", e);
            },
            .cap_kitty_keyboard => {
                self.logger.print("kitty keyboard capability detected", .{});
                self.vx.caps.kitty_keyboard = true;
            },
            .cap_kitty_graphics => {
                if (!self.vx.caps.kitty_graphics) {
                    self.vx.caps.kitty_graphics = true;
                }
            },
            .cap_rgb => {
                self.logger.print("rgb capability detected", .{});
                self.vx.caps.rgb = true;
            },
        }
    }
}

fn fmtmsg(self: *Self, value: anytype) ![]const u8 {
    self.event_buffer.clearRetainingCapacity();
    try cbor.writeValue(self.event_buffer.writer(), value);
    return self.event_buffer.items;
}

fn handle_bracketed_paste_input(self: *Self, cbor_msg: []const u8) !bool {
    var keypress: u32 = undefined;
    var egc_: u32 = undefined;
    if (try cbor.match(cbor_msg, .{ "I", cbor.number, cbor.extract(&keypress), cbor.extract(&egc_), cbor.string, 0 })) {
        switch (keypress) {
            key.ENTER => try self.bracketed_paste_buffer.appendSlice("\n"),
            else => if (!key.synthesized_p(keypress)) {
                var buf: [6]u8 = undefined;
                const bytes = try ucs32_to_utf8(&[_]u32{egc_}, &buf);
                try self.bracketed_paste_buffer.appendSlice(buf[0..bytes]);
            } else {
                try self.handle_bracketed_paste_end();
                return false;
            },
        }
        return true;
    }
    return false;
}

fn handle_bracketed_paste_end(self: *Self) !void {
    defer self.bracketed_paste_buffer.clearAndFree();
    if (!self.bracketed_paste) return;
    self.bracketed_paste = false;
    if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", self.bracketed_paste_buffer.items }));
}

pub fn set_terminal_title(self: *Self, text: []const u8) void {
    self.vx.setTitle(text) catch {};
}

pub fn copy_to_system_clipboard(self: *Self, text: []const u8) void {
    self.vx.copyToSystemClipboard(text, self.a) catch |e| log.logger(log_name).err("copy_to_system_clipboard", e);
}

pub fn request_system_clipboard(self: *Self) void {
    self.vx.requestSystemClipboard() catch |e| log.logger(log_name).err("request_system_clipboard", e);
}

pub fn request_mouse_cursor_text(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.text) else self.vx.setMouseShape(.default);
}

pub fn request_mouse_cursor_pointer(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.pointer) else self.vx.setMouseShape(.default);
}

pub fn request_mouse_cursor_default(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.default) else self.vx.setMouseShape(.default);
}

pub fn cursor_enable(self: *Self, y: c_int, x: c_int) !void {
    self.vx.screen.cursor_vis = true;
    self.vx.screen.cursor_row = @intCast(y);
    self.vx.screen.cursor_col = @intCast(x);
}

pub fn cursor_disable(self: *Self) void {
    self.vx.screen.cursor_vis = false;
}

pub fn ucs32_to_utf8(ucs32: []const u32, utf8: []u8) !usize {
    return @intCast(try std.unicode.utf8Encode(@intCast(ucs32[0]), utf8));
}
