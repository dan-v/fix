//! The evaluator's single HTTP transport.
//!
//! libcurl owns protocol details (proxy/no-proxy, redirects, TLS, content
//! decoding and connection timeouts). This adapter only supplies Fix policy,
//! streams bytes to a staging file while hashing them, and translates curl's
//! result into stable fetch errors.

const std = @import("std");
const sync = @import("base").sync;

const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("stdio.h");
});

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Reporter = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, downloaded: u64, total: u64) void,
};

pub const Options = struct {
    headers: []const Header = &.{},
    reporter: ?Reporter = null,
    connect_timeout_seconds: u32 = 15,
    stalled_timeout_seconds: u32 = 300,
    max_bytes_per_second: u64 = 0,
    ca_file: ?[]const u8 = null,
    max_redirects: u32 = 10,
};

pub const Result = struct {
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    size: u64,
    status: u16,
};

/// Hash an already-downloaded cache file without loading it into evaluator
/// memory. Kept beside the download writer so publication and validation use
/// exactly the same decoded-byte hashing rule.
pub fn fileDigest(allocator: std.mem.Allocator, path: []const u8) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(file);

    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&buffer, 1, buffer.len, file);
        if (n != 0) hash.update(buffer[0..n]);
        if (n != buffer.len) {
            if (c.ferror(file) != 0) return error.FetchCacheReadFailed;
            break;
        }
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

var init_mu: sync.BlockingMutex = .{};
var initialized = false;

fn ensureInitialized() !void {
    init_mu.lock();
    defer init_mu.unlock();
    if (initialized) return;
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK)
        return error.CurlInitializationFailed;
    initialized = true;
}

const WriteContext = struct {
    file: *c.FILE,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    written: u64 = 0,
    write_failed: bool = false,

    fn callback(data: [*c]u8, size: usize, count: usize, ctx_ptr: ?*anyopaque) callconv(.c) usize {
        const self: *WriteContext = @ptrCast(@alignCast(ctx_ptr orelse return 0));
        const len = std.math.mul(usize, size, count) catch return 0;
        if (len == 0) return 0;
        const n = c.fwrite(data, 1, len, self.file);
        if (n != len) {
            self.write_failed = true;
            return n;
        }
        self.hash.update(data[0..len]);
        self.written += len;
        return len;
    }
};

const ProgressContext = struct {
    reporter: ?Reporter,

    fn callback(ctx_ptr: ?*anyopaque, download_total: c.curl_off_t, download_now: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
        const self: *ProgressContext = @ptrCast(@alignCast(ctx_ptr orelse return 0));
        const reporter = self.reporter orelse return 0;
        reporter.report(
            reporter.ctx,
            if (download_now > 0) @intCast(download_now) else 0,
            if (download_total > 0) @intCast(download_total) else 0,
        );
        return 0;
    }
};

fn set(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK)
        return error.CurlOptionFailed;
}

/// Download `url` into the new/truncated file at `path`, returning the SHA-256
/// of the decoded response body. `path` is staging storage and should only be
/// published by an atomic rename after this succeeds.
pub fn download(allocator: std.mem.Allocator, url: []const u8, path: []const u8, options: Options) !Result {
    try ensureInitialized();

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = c.fopen(path_z.ptr, "wb") orelse return error.FetchCacheWriteFailed;
    defer _ = c.fclose(file);

    const easy = c.curl_easy_init() orelse return error.CurlInitializationFailed;
    defer c.curl_easy_cleanup(easy);

    var header_list: ?*c.curl_slist = null;
    defer if (header_list) |list| c.curl_slist_free_all(list);
    var owned_headers: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (owned_headers.items) |header| allocator.free(header);
        owned_headers.deinit(allocator);
    }
    for (options.headers) |header| {
        const line = try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ header.name, header.value }, 0);
        try owned_headers.append(allocator, line);
        header_list = c.curl_slist_append(header_list, line.ptr) orelse return error.OutOfMemory;
    }

    var write_ctx = WriteContext{ .file = file };
    var progress_ctx = ProgressContext{ .reporter = options.reporter };
    var error_buffer: [c.CURL_ERROR_SIZE]u8 = @splat(0);

    try set(easy, c.CURLOPT_URL, url_z.ptr);
    try set(easy, c.CURLOPT_USERAGENT, "fix");
    try set(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    try set(easy, c.CURLOPT_MAXREDIRS, @as(c_long, @intCast(options.max_redirects)));
    try set(easy, c.CURLOPT_FAILONERROR, @as(c_long, 1));
    // An empty value asks libcurl to advertise every built-in encoding and
    // transparently decode it before invoking the write callback.
    try set(easy, c.CURLOPT_ACCEPT_ENCODING, "");
    try set(easy, c.CURLOPT_WRITEFUNCTION, WriteContext.callback);
    try set(easy, c.CURLOPT_WRITEDATA, &write_ctx);
    try set(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    try set(easy, c.CURLOPT_XFERINFOFUNCTION, ProgressContext.callback);
    try set(easy, c.CURLOPT_XFERINFODATA, &progress_ctx);
    try set(easy, c.CURLOPT_ERRORBUFFER, &error_buffer);
    if (header_list) |list| try set(easy, c.CURLOPT_HTTPHEADER, list);
    if (options.connect_timeout_seconds > 0)
        try set(easy, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, @intCast(options.connect_timeout_seconds)));
    if (options.stalled_timeout_seconds > 0) {
        try set(easy, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1));
        try set(easy, c.CURLOPT_LOW_SPEED_TIME, @as(c_long, @intCast(options.stalled_timeout_seconds)));
    }
    if (options.max_bytes_per_second > 0)
        try set(easy, c.CURLOPT_MAX_RECV_SPEED_LARGE, @as(c.curl_off_t, @intCast(options.max_bytes_per_second)));
    var ca_z: ?[:0]u8 = null;
    defer if (ca_z) |value| allocator.free(value);
    if (options.ca_file) |ca_file| {
        ca_z = try allocator.dupeZ(u8, ca_file);
        try set(easy, c.CURLOPT_CAINFO, ca_z.?.ptr);
    }

    const code = c.curl_easy_perform(easy);
    var response_code: c_long = 0;
    _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &response_code);
    if (code != c.CURLE_OK) {
        if (write_ctx.write_failed) return error.FetchCacheWriteFailed;
        if (response_code >= 400 and response_code < 500 and response_code != 408 and response_code != 429)
            return error.FetchClientError;
        return switch (code) {
            c.CURLE_UNSUPPORTED_PROTOCOL, c.CURLE_URL_MALFORMAT => error.FetchInvalidUrl,
            c.CURLE_TOO_MANY_REDIRECTS => error.FetchTooManyRedirects,
            c.CURLE_PEER_FAILED_VERIFICATION, c.CURLE_SSL_CACERT_BADFILE => error.FetchTlsVerificationFailed,
            else => error.FetchTransient,
        };
    }
    if (c.fflush(file) != 0) return error.FetchCacheWriteFailed;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    write_ctx.hash.final(&digest);
    return .{
        .digest = digest,
        .size = write_ctx.written,
        .status = if (response_code >= 0 and response_code <= std.math.maxInt(u16)) @intCast(response_code) else 0,
    };
}

test "HTTP download follows redirects and streams decoded bytes" {
    const testing = std.testing;
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.ip4.port;
    const Server = struct {
        fn run(s: *std.Io.net.Server) void {
            for (0..2) |request_index| {
                const stream = s.accept(testing.io) catch return;
                defer stream.close(testing.io);
                var read_buffer: [2048]u8 = undefined;
                var reader = std.Io.net.Stream.Reader.init(stream, testing.io, &read_buffer);
                while (true) {
                    const line = reader.interface.takeDelimiterExclusive('\n') catch return;
                    if (line.len == 0 or std.mem.eql(u8, line, "\r")) break;
                }
                var write_buffer: [2048]u8 = undefined;
                var writer = std.Io.net.Stream.Writer.init(stream, testing.io, &write_buffer);
                if (request_index == 0)
                    writer.interface.writeAll("HTTP/1.1 302 Found\r\nLocation: /body\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return
                else
                    writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\npayload") catch return;
                writer.interface.flush() catch return;
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const output = try std.fs.path.join(testing.allocator, &.{ root, "output" });
    defer testing.allocator.free(output);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/redirect", .{port});
    defer testing.allocator.free(url);
    const result = try download(testing.allocator, url, output, .{});
    thread.join();
    try testing.expectEqual(@as(u64, 7), result.size);
    const contents = try tmp.dir.readFileAlloc(testing.io, "output", testing.allocator, .limited(64));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("payload", contents);
}
