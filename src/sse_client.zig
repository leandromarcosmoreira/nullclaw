//! Standalone SSE (Server-Sent Events) streaming client.
//!
//! This module is kept separate from the rest of the codebase to avoid
//! Zig 0.15 namespace collision bugs when std.http is used alongside
//! modules that export 'http' symbols.
//!
//! Provides persistent SSE connections with chunked transfer encoding
//! support for real-time message delivery.

const std = @import("std");
const log = std.log.scoped(.sse_client);

/// Maximum SSE event size (256KB)
/// Events larger than this are truncated to prevent memory exhaustion
const MAX_EVENT_SIZE = 256 * 1024;

/// Maximum buffer size for read operations
/// Prevents buffer overflow attacks and memory exhaustion
const MAX_BUFFER_SIZE = 8192;

/// SSE connection that maintains a persistent HTTP connection for streaming
pub const SseConnection = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    connection: ?*std.http.Client.Connection,
    request: ?std.http.Client.Request,
    /// The body reader for streaming response data
    body_reader: ?*std.Io.Reader,
    url: []const u8,
    /// Buffer for reading response data
    transfer_buf: [4096]u8,
    /// Direct stream reader interface for low-level reading
    stream_reader_interface: ?*std.Io.Reader,

    pub const Error = error{
        NotConnected,
        ConnectionFailed,
        ReadError,
    };

    /// Initialize a new SSE connection (not yet connected)
    pub fn init(allocator: std.mem.Allocator, url: []const u8) SseConnection {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .connection = null,
            .request = null,
            .body_reader = null,
            .url = url,
            .transfer_buf = undefined,
            .stream_reader_interface = null,
        };
    }

    /// Clean up resources
    /// Properly closes HTTP connection and frees client resources
    pub fn deinit(self: *SseConnection) void {
        // Clear reader references before closing connection
        self.stream_reader_interface = null;
        self.body_reader = null;
        // Deinit request (this also closes the connection)
        if (self.request) |*req| {
            req.deinit();
            self.request = null;
        }
        self.connection = null; // Connection is owned by client, cleared by request.deinit
        // Deinit client (closes any remaining connections)
        self.client.deinit();
    }

    /// Connect to SSE endpoint and start streaming
    /// Returns the HTTP status code
    pub fn connect(self: *SseConnection) !u16 {
        // URL already includes account param (from sseBaseUrl in signal.zig)
        const uri = try std.Uri.parse(self.url);
        const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
        const resolved_port: u16 = uri.port orelse default_port;

        // Extract host for connection
        const host = switch (uri.host orelse return error.InvalidUrl) {
            .percent_encoded => |h| h,
            .raw => |h| h,
        };
        const authority_host = if (std.mem.indexOf(u8, host, ":")) |colon|
            host[0..colon]
        else
            host;

        // Connect
        const protocol: std.http.Client.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) .tls else .plain;
        self.connection = try self.client.connectTcpOptions(.{
            .host = authority_host,
            .port = resolved_port,
            .protocol = protocol,
        });

        // Set up stream reader interface for direct reading
        self.stream_reader_interface = self.connection.?.stream_reader.interface();

        // Build request options with SSE headers
        const extra_headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "text/event-stream" },
        };
        const options: std.http.Client.RequestOptions = .{
            .connection = self.connection,
            .extra_headers = &extra_headers,
        };

        // Create request
        var req = try self.client.request(.GET, uri, options);
        self.request = req;

        // Send request (no body for GET)
        try req.sendBodiless();

        // Receive response headers
        var redirect_buf: [4096]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);

        const status_code = @intFromEnum(response.head.status);
        if (status_code < 200 or status_code >= 300) {
            return error.ConnectionFailed;
        }

        // Get the body reader for streaming - this handles chunked transfer encoding
        self.body_reader = req.reader.bodyReader(&self.transfer_buf, response.head.transfer_encoding, response.head.content_length);

        log.info("SSE connected to {s} (status: {d})", .{ self.url, status_code });
        return status_code;
    }

    /// Read data from the SSE stream into the provided buffer
    /// Returns the number of bytes read, or 0 if no data available
    ///
    /// Strategy:
    /// 1. Drain all already-buffered data (non-blocking)
    /// 2. If data was read, return it immediately (don't wait for more)
    /// 3. If buffer empty, wait for first byte with take(1) (blocking)
    /// 4. After getting first byte, drain any additional arrivals
    /// 5. Return accumulated data
    ///
    /// This approach minimizes latency while maximizing throughput by:
    /// - Returning immediately when data is available
    /// - Only blocking when buffer is truly empty
    /// - Coalescing multiple small reads into larger batches
    pub fn read(self: *SseConnection, buf: []u8) !usize {
        if (self.stream_reader_interface == null) return error.NotConnected;
        if (buf.len == 0) return 0;
        // Limit buffer size to prevent overflow
        if (buf.len > MAX_BUFFER_SIZE) {
            return self.read(buf[0..MAX_BUFFER_SIZE]);
        }

        var total_read: usize = 0;

        // Phase 1: Drain all already-buffered data
        var buffered = self.stream_reader_interface.?.bufferedLen();
        while (buffered > 0 and total_read < buf.len) {
            const to_read = @min(buffered, buf.len - total_read);
            const data = self.stream_reader_interface.?.take(to_read) catch break;
            if (data.len == 0) break;
            @memcpy(buf[total_read..][0..data.len], data);
            total_read += data.len;
            buffered = self.stream_reader_interface.?.bufferedLen();
        }

        if (total_read >= buf.len) {
            // Buffer full - return what we have
            return total_read;
        }

        // Phase 2: If we have some data already, return it now
        // The caller will poll again soon for any new arrivals
        if (total_read > 0) {
            return total_read;
        }

        // Phase 3: Buffer empty and no data yet - wait for first byte
        const first = self.stream_reader_interface.?.take(1) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return error.ReadError,
        };

        if (first.len == 0) return 0;

        buf[0] = first[0];
        total_read = 1;

        // Phase 4: After getting first byte, drain any additional buffered data
        buffered = self.stream_reader_interface.?.bufferedLen();
        while (buffered > 0 and total_read < buf.len) {
            const to_read = @min(buffered, buf.len - total_read);
            const data = self.stream_reader_interface.?.take(to_read) catch break;
            if (data.len == 0) break;
            @memcpy(buf[total_read..][0..data.len], data);
            total_read += data.len;
            buffered = self.stream_reader_interface.?.bufferedLen();
        }

        return total_read;
    }

    /// Check if the connection is still active
    pub fn isConnected(self: *SseConnection) bool {
        return self.stream_reader_interface != null;
    }
};

/// SSE event data structure
pub const SseEvent = struct {
    data: []const u8,

    pub fn deinit(self: *SseEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Parse SSE events from a buffer
/// Returns a slice of events (caller must free each event.data and the slice itself)
///
/// Safety: Truncates events larger than MAX_EVENT_SIZE to prevent memory exhaustion.
/// Events are delimited by double newlines (\n\n).
/// Each data: line contributes to the event data, with newlines preserved.
pub fn parseEvents(allocator: std.mem.Allocator, buffer: []const u8) ![]SseEvent {
    var events: std.ArrayList(SseEvent) = .{};
    defer events.deinit(allocator);

    var current_data: std.ArrayList(u8) = .{};
    defer current_data.deinit(allocator);

    var total_event_size: usize = 0;

    var lines = std.mem.splitScalar(u8, buffer, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");

        if (trimmed.len == 0) {
            // Empty line marks end of event
            if (current_data.items.len > 0) {
                const data = try current_data.toOwnedSlice(allocator);
                try events.append(allocator, .{ .data = data });
                current_data = .{};
                total_event_size = 0;
            }
            continue;
        }

        // Skip comments (lines starting with :)
        if (trimmed[0] == ':') continue;

        // Parse data field
        if (std.mem.startsWith(u8, trimmed, "data:")) {
            const data_start = 5; // Skip "data:"
            const data = std.mem.trim(u8, trimmed[data_start..], " ");

            // Check event size limit before appending
            const newline_len: usize = if (current_data.items.len > 0) 1 else 0;
            const new_size = total_event_size + data.len + newline_len;
            if (new_size > MAX_EVENT_SIZE) {
                // Event too large - finalize current event and skip remaining data
                if (current_data.items.len > 0) {
                    const owned = try current_data.toOwnedSlice(allocator);
                    try events.append(allocator, .{ .data = owned });
                }
                current_data = .{};
                total_event_size = 0;
                continue;
            }

            if (current_data.items.len > 0) {
                try current_data.append(allocator, '\n');
            }
            try current_data.appendSlice(allocator, data);
            total_event_size = new_size;
        }
        // Could also handle id: and event: fields here if needed
    }

    // Handle any remaining data without trailing newline
    if (current_data.items.len > 0) {
        const data = try current_data.toOwnedSlice(allocator);
        try events.append(allocator, .{ .data = data });
    }

    return try events.toOwnedSlice(allocator);
}

test "parseEvents extracts SSE data fields" {
    const allocator = std.testing.allocator;

    // Test basic SSE format: data: json\n\n
    const sse_data = "data: {\"message\":\"hello\"}\n\ndata: {\"message\":\"world\"}\n\n";
    const events = try parseEvents(allocator, sse_data);
    defer {
        for (events) |*e| e.deinit(allocator);
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("{\"message\":\"hello\"}", events[0].data);
    try std.testing.expectEqualStrings("{\"message\":\"world\"}", events[1].data);
}

test "parseEvents skips comments" {
    const allocator = std.testing.allocator;

    const sse_data = ": comment\ndata: {\"msg\":\"test\"}\n\n";
    const events = try parseEvents(allocator, sse_data);
    defer {
        for (events) |*e| e.deinit(allocator);
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("{\"msg\":\"test\"}", events[0].data);
}

test "parseEvents handles multi-line data" {
    const allocator = std.testing.allocator;

    // Multi-line data should have newlines preserved
    const sse_data = "data: line1\ndata: line2\n\n";
    const events = try parseEvents(allocator, sse_data);
    defer {
        for (events) |*e| e.deinit(allocator);
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("line1\nline2", events[0].data);
}
