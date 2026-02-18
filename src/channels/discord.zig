const std = @import("std");
const root = @import("root.zig");

const log = std.log.scoped(.discord);

/// Discord channel — connects via WebSocket gateway, sends via REST API.
/// Splits messages at 2000 chars (Discord limit).
pub const DiscordChannel = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    guild_id: ?[]const u8,
    listen_to_bots: bool,

    pub const MAX_MESSAGE_LEN: usize = 2000;
    pub const GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json";

    pub fn init(
        allocator: std.mem.Allocator,
        bot_token: []const u8,
        guild_id: ?[]const u8,
        listen_to_bots: bool,
    ) DiscordChannel {
        return .{
            .allocator = allocator,
            .bot_token = bot_token,
            .guild_id = guild_id,
            .listen_to_bots = listen_to_bots,
        };
    }

    pub fn channelName(_: *DiscordChannel) []const u8 {
        return "discord";
    }

    /// Build a Discord REST API URL for sending to a channel.
    pub fn sendUrl(buf: []u8, channel_id: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("https://discord.com/api/v10/channels/{s}/messages", .{channel_id});
        return fbs.getWritten();
    }

    /// Extract bot user ID from a bot token.
    /// Discord bot tokens are base64(bot_user_id).random.hmac
    pub fn extractBotUserId(token: []const u8) ?[]const u8 {
        // Find the first '.'
        const dot_pos = std.mem.indexOf(u8, token, ".") orelse return null;
        return token[0..dot_pos];
    }

    pub fn healthCheck(_: *DiscordChannel) bool {
        return true;
    }

    // ── Channel vtable ──────────────────────────────────────────────

    /// Send a message to a Discord channel via REST API.
    /// Splits at MAX_MESSAGE_LEN (2000 chars).
    pub fn sendMessage(self: *DiscordChannel, channel_id: []const u8, text: []const u8) !void {
        var it = root.splitMessage(text, MAX_MESSAGE_LEN);
        while (it.next()) |chunk| {
            try self.sendChunk(channel_id, chunk);
        }
    }

    fn sendChunk(self: *DiscordChannel, channel_id: []const u8, text: []const u8) !void {
        var url_buf: [256]u8 = undefined;
        const url = try sendUrl(&url_buf, channel_id);

        // Build JSON body: {"content":"..."}
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        try body_list.appendSlice(self.allocator, "{\"content\":");
        try root.json_util.appendJsonString(&body_list, self.allocator, text);
        try body_list.appendSlice(self.allocator, "}");

        // Build auth header value: "Authorization: Bot <token>"
        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bot {s}", .{self.bot_token});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{auth_header}) catch |err| {
            log.err("Discord API POST failed: {}", .{err});
            return error.DiscordApiError;
        };
        self.allocator.free(resp);
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        _ = ptr;
        // Discord REST-only mode: no persistent connection needed
    }

    fn vtableStop(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8) anyerror!void {
        const self: *DiscordChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *DiscordChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *DiscordChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *DiscordChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "discord send url" {
    var buf: [256]u8 = undefined;
    const url = try DiscordChannel.sendUrl(&buf, "123456");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/123456/messages", url);
}

test "discord extract bot user id" {
    const id = DiscordChannel.extractBotUserId("MTIzNDU2.Ghijk.abcdef");
    try std.testing.expectEqualStrings("MTIzNDU2", id.?);
}

test "discord extract bot user id no dot" {
    try std.testing.expect(DiscordChannel.extractBotUserId("notokenformat") == null);
}

// ════════════════════════════════════════════════════════════════════════════
// Additional Discord Tests (ported from ZeroClaw Rust)
// ════════════════════════════════════════════════════════════════════════════

test "discord send url with different channel ids" {
    var buf: [256]u8 = undefined;
    const url1 = try DiscordChannel.sendUrl(&buf, "999");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/999/messages", url1);

    var buf2: [256]u8 = undefined;
    const url2 = try DiscordChannel.sendUrl(&buf2, "1234567890");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/1234567890/messages", url2);
}

test "discord extract bot user id multiple dots" {
    // Token format: base64(user_id).timestamp.hmac
    const id = DiscordChannel.extractBotUserId("MTIzNDU2.fake.hmac");
    try std.testing.expectEqualStrings("MTIzNDU2", id.?);
}

test "discord extract bot user id empty token" {
    // Empty string before dot means empty result
    const id = DiscordChannel.extractBotUserId("");
    try std.testing.expect(id == null);
}

test "discord extract bot user id single dot" {
    const id = DiscordChannel.extractBotUserId("abc.");
    try std.testing.expectEqualStrings("abc", id.?);
}

test "discord max message len constant" {
    try std.testing.expectEqual(@as(usize, 2000), DiscordChannel.MAX_MESSAGE_LEN);
}

test "discord gateway url constant" {
    try std.testing.expectEqualStrings("wss://gateway.discord.gg/?v=10&encoding=json", DiscordChannel.GATEWAY_URL);
}

test "discord init stores fields" {
    const ch = DiscordChannel.init(std.testing.allocator, "my-bot-token", "guild-123", true);
    try std.testing.expectEqualStrings("my-bot-token", ch.bot_token);
    try std.testing.expectEqualStrings("guild-123", ch.guild_id.?);
    try std.testing.expect(ch.listen_to_bots);
}

test "discord init no guild id" {
    const ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    try std.testing.expect(ch.guild_id == null);
    try std.testing.expect(!ch.listen_to_bots);
}

test "discord send url buffer too small returns error" {
    var buf: [10]u8 = undefined;
    const result = DiscordChannel.sendUrl(&buf, "123456");
    try std.testing.expect(if (result) |_| false else |_| true);
}
