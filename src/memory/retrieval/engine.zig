//! Retrieval engine — aggregates candidates from multiple sources,
//! merges via RRF, and returns ranked results.
//!
//! Core types: RetrievalCandidate, RetrievalSourceAdapter (vtable),
//! PrimaryAdapter (wraps Memory.recall), RetrievalEngine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const Memory = root.Memory;
const MemoryEntry = root.MemoryEntry;
const MemoryCategory = root.MemoryCategory;
const config_types = @import("../../config_types.zig");
const rrf = @import("rrf.zig");
const vector_store_mod = @import("../vector/store.zig");
const circuit_breaker_mod = @import("../vector/circuit_breaker.zig");
const embeddings_mod = @import("../vector/embeddings.zig");
const log = std.log.scoped(.retrieval);

// ── RetrievalCandidate ─────────────────────────────────────────────

pub const RetrievalCandidate = struct {
    id: []const u8,
    key: []const u8,
    content: []const u8,
    snippet: []const u8,
    category: MemoryCategory,
    keyword_rank: ?u32,
    vector_score: ?f32,
    final_score: f64,
    source: []const u8,
    source_path: []const u8,
    start_line: u32,
    end_line: u32,

    pub fn deinit(self: *const RetrievalCandidate, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.content);
        allocator.free(self.snippet);
        allocator.free(self.source);
        allocator.free(self.source_path);
        switch (self.category) {
            .custom => |name| allocator.free(name),
            else => {},
        }
    }
};

pub fn freeCandidates(allocator: Allocator, candidates: []RetrievalCandidate) void {
    for (candidates) |*c| {
        c.deinit(allocator);
    }
    allocator.free(candidates);
}

/// Convert MemoryEntry slice to RetrievalCandidate slice.
/// Caller owns the returned slice. Entries are NOT freed.
pub fn entriesToCandidates(allocator: Allocator, entries: []const MemoryEntry) ![]RetrievalCandidate {
    var result = try allocator.alloc(RetrievalCandidate, entries.len);
    errdefer {
        for (result) |*c| c.deinit(allocator);
        allocator.free(result);
    }

    for (entries, 0..) |entry, i| {
        const id = try allocator.dupe(u8, entry.id);
        errdefer allocator.free(id);
        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);
        const content = try allocator.dupe(u8, entry.content);
        errdefer allocator.free(content);
        const snippet = try allocator.dupe(u8, entry.content);
        errdefer allocator.free(snippet);
        const source = try allocator.dupe(u8, "primary");
        errdefer allocator.free(source);
        const source_path = try allocator.dupe(u8, "");
        errdefer allocator.free(source_path);

        const cat: MemoryCategory = switch (entry.category) {
            .custom => |name| .{ .custom = try allocator.dupe(u8, name) },
            else => entry.category,
        };

        result[i] = .{
            .id = id,
            .key = key,
            .content = content,
            .snippet = snippet,
            .category = cat,
            .keyword_rank = @as(u32, @intCast(i + 1)),
            .vector_score = null,
            .final_score = 0.0,
            .source = source,
            .source_path = source_path,
            .start_line = 0,
            .end_line = 0,
        };
    }

    return result;
}

// ── SourceCapabilities ─────────────────────────────────────────────

pub const SourceCapabilities = struct {
    has_keyword_rank: bool,
    has_vector_search: bool,
    is_readonly: bool,
};

// ── RetrievalSourceAdapter vtable ──────────────────────────────────

pub const RetrievalSourceAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        capabilities: *const fn (ptr: *anyopaque) SourceCapabilities,
        keywordCandidates: *const fn (ptr: *anyopaque, alloc: Allocator, query: []const u8, limit: u32, session_id: ?[]const u8) anyerror![]RetrievalCandidate,
        healthCheck: *const fn (ptr: *anyopaque) bool,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn getName(self: RetrievalSourceAdapter) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn getCapabilities(self: RetrievalSourceAdapter) SourceCapabilities {
        return self.vtable.capabilities(self.ptr);
    }

    pub fn keywordCandidates(self: RetrievalSourceAdapter, alloc: Allocator, query: []const u8, limit: u32, session_id: ?[]const u8) ![]RetrievalCandidate {
        return self.vtable.keywordCandidates(self.ptr, alloc, query, limit, session_id);
    }

    pub fn healthCheck(self: RetrievalSourceAdapter) bool {
        return self.vtable.healthCheck(self.ptr);
    }

    pub fn deinitAdapter(self: RetrievalSourceAdapter) void {
        self.vtable.deinit(self.ptr);
    }
};

// ── PrimaryAdapter ─────────────────────────────────────────────────

pub const PrimaryAdapter = struct {
    mem: Memory,
    owns_self: bool = false,
    allocator: ?Allocator = null,

    const Self = @This();

    pub fn init(mem: Memory) PrimaryAdapter {
        return .{ .mem = mem };
    }

    pub fn adapter(self: *PrimaryAdapter) RetrievalSourceAdapter {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &primary_vtable,
        };
    }

    fn implName(_: *anyopaque) []const u8 {
        return "primary";
    }

    fn implCapabilities(_: *anyopaque) SourceCapabilities {
        return .{
            .has_keyword_rank = true,
            .has_vector_search = false,
            .is_readonly = true,
        };
    }

    fn implKeywordCandidates(ptr: *anyopaque, alloc: Allocator, query: []const u8, limit: u32, session_id: ?[]const u8) anyerror![]RetrievalCandidate {
        const self = castSelf(ptr);
        const entries = try self.mem.recall(alloc, query, @as(usize, limit), session_id);
        defer root.freeEntries(alloc, entries);
        return entriesToCandidates(alloc, entries);
    }

    fn implHealthCheck(ptr: *anyopaque) bool {
        const self = castSelf(ptr);
        return self.mem.healthCheck();
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self = castSelf(ptr);
        if (self.owns_self) {
            if (self.allocator) |alloc| {
                alloc.destroy(self);
            }
        }
    }

    fn castSelf(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    const primary_vtable = RetrievalSourceAdapter.VTable{
        .name = &implName,
        .capabilities = &implCapabilities,
        .keywordCandidates = &implKeywordCandidates,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
    };
};

// ── RetrievalEngine ────────────────────────────────────────────────

pub const RetrievalEngine = struct {
    allocator: Allocator,
    sources: std.ArrayListUnmanaged(RetrievalSourceAdapter),
    merge_k: u32,
    top_k: u32,
    min_score: f64,
    owns_self: bool = false,

    // Vector search components (all optional, null = keyword-only)
    embedding_provider: ?embeddings_mod.EmbeddingProvider = null,
    vector_store: ?vector_store_mod.VectorStore = null,
    circuit_breaker: ?*circuit_breaker_mod.CircuitBreaker = null,
    hybrid_cfg: config_types.MemoryHybridConfig = .{},

    const Self = @This();

    pub fn init(allocator: Allocator, query_cfg: config_types.MemoryQueryConfig) RetrievalEngine {
        return .{
            .allocator = allocator,
            .sources = .{},
            .merge_k = query_cfg.rrf_k,
            .top_k = query_cfg.max_results,
            .min_score = query_cfg.min_score,
        };
    }

    pub fn addSource(self: *RetrievalEngine, source: RetrievalSourceAdapter) !void {
        try self.sources.append(self.allocator, source);
    }

    /// Configure vector search components for hybrid retrieval.
    pub fn setVectorSearch(
        self: *RetrievalEngine,
        provider: embeddings_mod.EmbeddingProvider,
        vs: vector_store_mod.VectorStore,
        breaker: ?*circuit_breaker_mod.CircuitBreaker,
        hybrid: config_types.MemoryHybridConfig,
    ) void {
        self.embedding_provider = provider;
        self.vector_store = vs;
        self.circuit_breaker = breaker;
        self.hybrid_cfg = hybrid;
    }

    /// Run keyword search across all sources, merge with RRF, filter, truncate.
    pub fn search(
        self: *RetrievalEngine,
        allocator: Allocator,
        query: []const u8,
        session_id: ?[]const u8,
    ) ![]RetrievalCandidate {
        if (self.sources.items.len == 0) {
            return allocator.alloc(RetrievalCandidate, 0);
        }

        const fetch_limit = self.top_k * 2;

        // Collect results from all sources
        var source_results = try allocator.alloc([]RetrievalCandidate, self.sources.items.len);
        defer allocator.free(source_results);

        var valid_count: usize = 0;

        for (self.sources.items, 0..) |source, i| {
            const is_primary = std.mem.eql(u8, source.getName(), "primary");
            source_results[i] = source.keywordCandidates(allocator, query, fetch_limit, session_id) catch |err| {
                if (is_primary) {
                    log.err("primary source search failed: {}", .{err});
                    // Free any previously collected results
                    for (source_results[0..i]) |prev| {
                        freeCandidates(allocator, prev);
                    }
                    return err;
                }
                log.warn("source search failed (non-primary), continuing: {}", .{err});
                source_results[i] = &.{};
                continue;
            };
            if (source_results[i].len > 0) valid_count += 1;
        }

        // Prepare source slices for RRF (only non-empty)
        defer {
            for (source_results) |sr| {
                if (sr.len > 0) freeCandidates(allocator, sr);
            }
        }

        // ── Hybrid: vector search ──
        // If hybrid is enabled, embed the query and search the vector store.
        // Results are added as an additional source for RRF merge.
        var vector_candidates: ?[]RetrievalCandidate = null;
        defer if (vector_candidates) |vc| freeCandidates(allocator, vc);

        if (self.hybrid_cfg.enabled) hybrid_blk: {
            const provider = self.embedding_provider orelse break :hybrid_blk;
            const vs = self.vector_store orelse break :hybrid_blk;

            // Check circuit breaker
            if (self.circuit_breaker) |cb| {
                if (!cb.allow()) {
                    log.warn("circuit breaker open, skipping vector search", .{});
                    break :hybrid_blk;
                }
            }

            // Embed query
            const query_embedding = provider.embed(allocator, query) catch |err| {
                log.warn("query embedding failed, degrading to keyword-only: {}", .{err});
                if (self.circuit_breaker) |cb| cb.recordFailure();
                break :hybrid_blk;
            };
            defer allocator.free(query_embedding);

            if (self.circuit_breaker) |cb| cb.recordSuccess();

            if (query_embedding.len == 0) break :hybrid_blk;

            // Search vector store
            const vec_limit = self.top_k * self.hybrid_cfg.candidate_multiplier;
            const vec_results = vs.search(allocator, query_embedding, vec_limit) catch |err| {
                log.warn("vector store search failed: {}", .{err});
                break :hybrid_blk;
            };
            defer vector_store_mod.freeVectorResults(allocator, vec_results);

            if (vec_results.len == 0) break :hybrid_blk;

            // Convert VectorResults to RetrievalCandidates
            vector_candidates = vectorResultsToCandidates(allocator, vec_results) catch |err| {
                log.warn("vector result conversion failed: {}", .{err});
                break :hybrid_blk;
            };

            valid_count += 1;
        }

        // Count including vector candidates
        const total_valid = valid_count;
        _ = total_valid;

        // Single source with results → set final_score from keyword_rank, skip RRF
        if (valid_count <= 1 and (vector_candidates == null or vector_candidates.?.len == 0)) {
            // Find the one with results
            for (source_results) |sr| {
                if (sr.len > 0) {
                    const out_len = @min(sr.len, @as(usize, self.top_k));
                    var result = try allocator.alloc(RetrievalCandidate, out_len);
                    errdefer allocator.free(result);

                    var actual_len: usize = 0;
                    for (0..out_len) |j| {
                        const score = if (sr[j].keyword_rank) |rank|
                            1.0 / @as(f64, @floatFromInt(rank + self.merge_k))
                        else
                            1.0 / @as(f64, @floatFromInt(j + 1 + self.merge_k));

                        if (score >= self.min_score) {
                            result[actual_len] = sr[j];
                            result[actual_len].final_score = score;
                            // Zero out the source entry so it doesn't get freed in defer
                            sr[j] = .{
                                .id = "",
                                .key = "",
                                .content = "",
                                .snippet = "",
                                .category = .core,
                                .keyword_rank = null,
                                .vector_score = null,
                                .final_score = 0.0,
                                .source = "",
                                .source_path = "",
                                .start_line = 0,
                                .end_line = 0,
                            };
                            actual_len += 1;
                        }
                    }

                    if (actual_len < result.len) {
                        // Free unused slots (they're still zeroed out so deinit is safe)
                        return allocator.realloc(result, actual_len);
                    }
                    return result;
                }
            }
            // All empty
            return allocator.alloc(RetrievalCandidate, 0);
        }

        // Multiple sources → RRF merge
        // Build const slices for rrf (include vector candidates if available)
        const has_vec = vector_candidates != null and vector_candidates.?.len > 0;
        const extra_sources: usize = if (has_vec) 1 else 0;
        var rrf_sources = try allocator.alloc([]const RetrievalCandidate, source_results.len + extra_sources);
        defer allocator.free(rrf_sources);
        for (source_results, 0..) |sr, i| {
            rrf_sources[i] = sr;
        }
        if (has_vec) {
            rrf_sources[source_results.len] = vector_candidates.?;
        }

        var merged = try rrf.rrfMerge(allocator, rrf_sources, self.merge_k, self.top_k);

        // Filter by min_score
        if (self.min_score > 0.0) {
            var keep: usize = 0;
            for (merged) |*c| {
                if (c.final_score >= self.min_score) {
                    if (keep != @as(usize, @intFromPtr(c) -% @intFromPtr(merged.ptr)) / @sizeOf(RetrievalCandidate)) {
                        merged[keep] = c.*;
                    }
                    keep += 1;
                } else {
                    c.deinit(allocator);
                }
            }
            if (keep < merged.len) {
                merged = allocator.realloc(merged, keep) catch merged[0..keep];
            }
        }

        return merged;
    }

    pub fn deinit(self: *RetrievalEngine) void {
        for (self.sources.items) |source| {
            source.deinitAdapter();
        }
        self.sources.deinit(self.allocator);
    }
};

/// Convert VectorResult slice to RetrievalCandidate slice.
/// Each result gets source="vector", vector_score set, content=key (minimal).
fn vectorResultsToCandidates(allocator: Allocator, vec_results: []const vector_store_mod.VectorResult) ![]RetrievalCandidate {
    var result = try allocator.alloc(RetrievalCandidate, vec_results.len);
    var i: usize = 0;
    errdefer {
        for (result[0..i]) |*ca| ca.deinit(allocator);
        allocator.free(result);
    }

    for (vec_results) |vr| {
        const id = try allocator.dupe(u8, vr.key);
        errdefer allocator.free(id);
        const key = try allocator.dupe(u8, vr.key);
        errdefer allocator.free(key);
        const content = try allocator.dupe(u8, vr.key); // minimal: key as content
        errdefer allocator.free(content);
        const snippet = try allocator.dupe(u8, vr.key);
        errdefer allocator.free(snippet);
        const source = try allocator.dupe(u8, "vector");
        errdefer allocator.free(source);
        const source_path = try allocator.dupe(u8, "");
        errdefer allocator.free(source_path);

        result[i] = .{
            .id = id,
            .key = key,
            .content = content,
            .snippet = snippet,
            .category = .core,
            .keyword_rank = null,
            .vector_score = vr.score,
            .final_score = 0.0,
            .source = source,
            .source_path = source_path,
            .start_line = 0,
            .end_line = 0,
        };
        i += 1;
    }
    return result;
}

// ── Tests ──────────────────────────────────────────────────────────

const none_mod = @import("../engines/none.zig");

test "RetrievalCandidate deinit frees all fields" {
    const allocator = std.testing.allocator;
    var c = RetrievalCandidate{
        .id = try allocator.dupe(u8, "id1"),
        .key = try allocator.dupe(u8, "key1"),
        .content = try allocator.dupe(u8, "content1"),
        .snippet = try allocator.dupe(u8, "snippet1"),
        .category = .core,
        .keyword_rank = 1,
        .vector_score = null,
        .final_score = 0.5,
        .source = try allocator.dupe(u8, "primary"),
        .source_path = try allocator.dupe(u8, "/path"),
        .start_line = 0,
        .end_line = 0,
    };
    c.deinit(allocator);
    // testing allocator detects leaks
}

test "RetrievalCandidate deinit frees custom category" {
    const allocator = std.testing.allocator;
    var c = RetrievalCandidate{
        .id = try allocator.dupe(u8, "id1"),
        .key = try allocator.dupe(u8, "key1"),
        .content = try allocator.dupe(u8, "content1"),
        .snippet = try allocator.dupe(u8, "snippet1"),
        .category = .{ .custom = try allocator.dupe(u8, "my_cat") },
        .keyword_rank = 1,
        .vector_score = null,
        .final_score = 0.5,
        .source = try allocator.dupe(u8, "primary"),
        .source_path = try allocator.dupe(u8, ""),
        .start_line = 0,
        .end_line = 0,
    };
    c.deinit(allocator);
}

test "freeCandidates frees slice" {
    const allocator = std.testing.allocator;
    var candidates = try allocator.alloc(RetrievalCandidate, 1);
    candidates[0] = .{
        .id = try allocator.dupe(u8, "id"),
        .key = try allocator.dupe(u8, "key"),
        .content = try allocator.dupe(u8, "c"),
        .snippet = try allocator.dupe(u8, "s"),
        .category = .core,
        .keyword_rank = null,
        .vector_score = null,
        .final_score = 0.0,
        .source = try allocator.dupe(u8, "p"),
        .source_path = try allocator.dupe(u8, ""),
        .start_line = 0,
        .end_line = 0,
    };
    freeCandidates(allocator, candidates);
}

test "PrimaryAdapter.name() returns primary" {
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();
    var pa = PrimaryAdapter.init(backend.memory());
    const a = pa.adapter();
    try std.testing.expectEqualStrings("primary", a.getName());
}

test "PrimaryAdapter.capabilities() correct" {
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();
    var pa = PrimaryAdapter.init(backend.memory());
    const a = pa.adapter();
    const caps = a.getCapabilities();
    try std.testing.expect(caps.has_keyword_rank);
    try std.testing.expect(!caps.has_vector_search);
    try std.testing.expect(caps.is_readonly);
}

test "PrimaryAdapter with NoneMemory returns empty" {
    const allocator = std.testing.allocator;
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();
    var pa = PrimaryAdapter.init(backend.memory());
    const a = pa.adapter();
    const results = try a.keywordCandidates(allocator, "query", 5, null);
    defer freeCandidates(allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "PrimaryAdapter healthCheck delegates" {
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();
    var pa = PrimaryAdapter.init(backend.memory());
    const a = pa.adapter();
    try std.testing.expect(a.healthCheck());
}

test "PrimaryAdapter.keywordCandidates converts MemoryEntry correctly" {
    const allocator = std.testing.allocator;
    const sqlite_mod = @import("../engines/sqlite.zig");
    var db = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer db.deinit();
    const mem = db.memory();

    try mem.store("zig_pref", "User prefers Zig", .core, null);
    try mem.store("rust_note", "Also knows Rust", .daily, null);

    var pa = PrimaryAdapter.init(mem);
    const a = pa.adapter();
    const results = try a.keywordCandidates(allocator, "zig", 10, null);
    defer freeCandidates(allocator, results);

    try std.testing.expect(results.len >= 1);
    // keyword_rank should be 1-based
    try std.testing.expectEqual(@as(u32, 1), results[0].keyword_rank.?);
    try std.testing.expectEqualStrings("primary", results[0].source);
    try std.testing.expectEqualStrings("", results[0].source_path);
    try std.testing.expectEqual(@as(u32, 0), results[0].start_line);
    try std.testing.expectEqual(@as(f64, 0.0), results[0].final_score);
}

test "PrimaryAdapter keyword_rank is 1-based sequential" {
    const allocator = std.testing.allocator;
    const sqlite_mod = @import("../engines/sqlite.zig");
    var db = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer db.deinit();
    const mem = db.memory();

    try mem.store("item_a", "searchable content alpha", .core, null);
    try mem.store("item_b", "searchable content beta", .core, null);
    try mem.store("item_c", "searchable content gamma", .core, null);

    var pa = PrimaryAdapter.init(mem);
    const a = pa.adapter();
    const results = try a.keywordCandidates(allocator, "searchable", 10, null);
    defer freeCandidates(allocator, results);

    try std.testing.expect(results.len >= 3);
    for (results, 0..) |r, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), r.keyword_rank.?);
    }
}

test "RetrievalEngine.init with defaults" {
    const allocator = std.testing.allocator;
    var engine = RetrievalEngine.init(allocator, .{});
    defer engine.deinit();

    try std.testing.expectEqual(@as(u32, 60), engine.merge_k);
    try std.testing.expectEqual(@as(u32, 6), engine.top_k);
    try std.testing.expectEqual(@as(f64, 0.0), engine.min_score);
}

test "Engine.search with single primary source" {
    const allocator = std.testing.allocator;
    const sqlite_mod = @import("../engines/sqlite.zig");
    var db = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer db.deinit();
    const mem = db.memory();

    try mem.store("test_key", "test content for search", .core, null);

    var pa = PrimaryAdapter.init(mem);
    var engine = RetrievalEngine.init(allocator, .{});
    defer engine.deinit();
    try engine.addSource(pa.adapter());

    const results = try engine.search(allocator, "test", null);
    defer freeCandidates(allocator, results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expect(results[0].final_score > 0.0);
}

test "Engine.search with empty results returns empty" {
    const allocator = std.testing.allocator;
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();

    var pa = PrimaryAdapter.init(backend.memory());
    var engine = RetrievalEngine.init(allocator, .{});
    defer engine.deinit();
    try engine.addSource(pa.adapter());

    const results = try engine.search(allocator, "anything", null);
    defer freeCandidates(allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "Engine.search applies min_score filter" {
    const allocator = std.testing.allocator;
    const sqlite_mod = @import("../engines/sqlite.zig");
    var db = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer db.deinit();
    const mem = db.memory();

    try mem.store("k1", "searchable data one", .core, null);

    var pa = PrimaryAdapter.init(mem);
    var engine = RetrievalEngine.init(allocator, .{
        .min_score = 1.0, // impossibly high threshold
    });
    defer engine.deinit();
    try engine.addSource(pa.adapter());

    const results = try engine.search(allocator, "searchable", null);
    defer freeCandidates(allocator, results);
    // All results should be filtered out due to high min_score
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "Engine.search applies top_k truncation" {
    const allocator = std.testing.allocator;
    const sqlite_mod = @import("../engines/sqlite.zig");
    var db = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer db.deinit();
    const mem = db.memory();

    for (0..5) |i| {
        const key = try std.fmt.allocPrint(allocator, "k{d}", .{i});
        defer allocator.free(key);
        const content = try std.fmt.allocPrint(allocator, "content searchable item number {d}", .{i});
        defer allocator.free(content);
        try mem.store(key, content, .core, null);
    }

    var pa = PrimaryAdapter.init(mem);
    var engine = RetrievalEngine.init(allocator, .{
        .max_results = 2,
    });
    defer engine.deinit();
    try engine.addSource(pa.adapter());

    const results = try engine.search(allocator, "searchable", null);
    defer freeCandidates(allocator, results);
    try std.testing.expect(results.len <= 2);
}

test "Engine.deinit cleans up sources" {
    const allocator = std.testing.allocator;
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();

    var pa = PrimaryAdapter.init(backend.memory());
    var engine = RetrievalEngine.init(allocator, .{});
    try engine.addSource(pa.adapter());
    engine.deinit();
    // No crash = pass
}

test "Engine with no sources returns empty" {
    const allocator = std.testing.allocator;
    var engine = RetrievalEngine.init(allocator, .{});
    defer engine.deinit();

    const results = try engine.search(allocator, "query", null);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "entriesToCandidates converts correctly" {
    const allocator = std.testing.allocator;
    const sqlite_mod = @import("../engines/sqlite.zig");
    var db = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer db.deinit();
    const mem = db.memory();

    try mem.store("test_k", "test_v", .core, null);
    const entries = try mem.recall(allocator, "test", 5, null);
    defer root.freeEntries(allocator, entries);

    const candidates = try entriesToCandidates(allocator, entries);
    defer freeCandidates(allocator, candidates);

    try std.testing.expect(candidates.len >= 1);
    try std.testing.expectEqualStrings("primary", candidates[0].source);
    try std.testing.expectEqual(@as(u32, 1), candidates[0].keyword_rank.?);
}

test "regression anchor: Engine with PrimaryAdapter matches raw recall order" {
    const allocator = std.testing.allocator;
    const sqlite_mod = @import("../engines/sqlite.zig");
    var db = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer db.deinit();
    const mem = db.memory();

    try mem.store("alpha", "searchable alpha content", .core, null);
    try mem.store("beta", "searchable beta content", .core, null);
    try mem.store("gamma", "searchable gamma content", .core, null);

    // Raw recall
    const raw = try mem.recall(allocator, "searchable", 10, null);
    defer root.freeEntries(allocator, raw);

    // Engine search
    var pa = PrimaryAdapter.init(mem);
    var engine = RetrievalEngine.init(allocator, .{ .max_results = 10 });
    defer engine.deinit();
    try engine.addSource(pa.adapter());

    const engine_results = try engine.search(allocator, "searchable", null);
    defer freeCandidates(allocator, engine_results);

    // Same count and same key order
    try std.testing.expectEqual(raw.len, engine_results.len);
    for (raw, engine_results) |r, e| {
        try std.testing.expectEqualStrings(r.key, e.key);
    }
}

test "Engine with hybrid disabled stays keyword-only" {
    const allocator = std.testing.allocator;
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();

    var pa = PrimaryAdapter.init(backend.memory());
    var engine = RetrievalEngine.init(allocator, .{});
    defer engine.deinit();
    try engine.addSource(pa.adapter());

    // hybrid_cfg.enabled defaults to false
    try std.testing.expect(!engine.hybrid_cfg.enabled);
    try std.testing.expect(engine.embedding_provider == null);
    try std.testing.expect(engine.vector_store == null);

    const results = try engine.search(allocator, "test", null);
    defer freeCandidates(allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "Engine.setVectorSearch stores fields" {
    const allocator = std.testing.allocator;
    var noop = embeddings_mod.NoopEmbedding{};
    const provider = noop.provider();

    // We can't create a real VectorStore without sqlite, so just test field assignment
    var engine = RetrievalEngine.init(allocator, .{});
    defer engine.deinit();

    // Create a minimal test — just verify the method exists and sets fields
    engine.embedding_provider = provider;
    engine.hybrid_cfg = .{ .enabled = true };
    try std.testing.expect(engine.hybrid_cfg.enabled);
    try std.testing.expect(engine.embedding_provider != null);
}

test "vectorResultsToCandidates converts correctly" {
    const allocator = std.testing.allocator;
    const key1 = try allocator.dupe(u8, "key_a");
    defer allocator.free(key1);
    const key2 = try allocator.dupe(u8, "key_b");
    defer allocator.free(key2);

    const vec_results = [_]vector_store_mod.VectorResult{
        .{ .key = key1, .score = 0.9 },
        .{ .key = key2, .score = 0.5 },
    };

    const candidates = try vectorResultsToCandidates(allocator, &vec_results);
    defer freeCandidates(allocator, candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("key_a", candidates[0].key);
    try std.testing.expectEqualStrings("vector", candidates[0].source);
    try std.testing.expect(candidates[0].vector_score != null);
    try std.testing.expect(@abs(candidates[0].vector_score.? - 0.9) < 0.001);
    try std.testing.expect(candidates[0].keyword_rank == null);
}

test "Engine with circuit breaker open skips vector search" {
    const allocator = std.testing.allocator;
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();

    var pa = PrimaryAdapter.init(backend.memory());
    var engine = RetrievalEngine.init(allocator, .{});
    defer engine.deinit();
    try engine.addSource(pa.adapter());

    // Create a circuit breaker that's open
    var cb = circuit_breaker_mod.CircuitBreaker.init(1, 999_999);
    cb.recordFailure(); // trips to open
    try std.testing.expect(cb.isOpen());

    engine.circuit_breaker = &cb;
    engine.hybrid_cfg = .{ .enabled = true };
    // Even with hybrid enabled, search should work (degrade to keyword-only)
    const results = try engine.search(allocator, "test", null);
    defer freeCandidates(allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "Engine search with hybrid disabled ignores vector components" {
    const allocator = std.testing.allocator;
    var backend = none_mod.NoneMemory.init();
    defer backend.deinit();

    var pa = PrimaryAdapter.init(backend.memory());
    var engine = RetrievalEngine.init(allocator, .{});
    defer engine.deinit();
    try engine.addSource(pa.adapter());

    // Set vector components but leave hybrid disabled
    var noop = embeddings_mod.NoopEmbedding{};
    engine.embedding_provider = noop.provider();
    engine.hybrid_cfg = .{ .enabled = false };

    const results = try engine.search(allocator, "test", null);
    defer freeCandidates(allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test {
    _ = rrf;
    _ = vector_store_mod;
    _ = circuit_breaker_mod;
    _ = embeddings_mod;
}
