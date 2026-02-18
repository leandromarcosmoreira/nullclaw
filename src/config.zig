const std = @import("std");
pub const config_types = @import("config_types.zig");
pub const config_parse = @import("config_parse.zig");

// ── Re-export all types so downstream `@import("config.zig").Foo` still works ──

pub const AutonomyLevel = config_types.AutonomyLevel;
pub const HardwareTransport = config_types.HardwareTransport;
pub const SandboxBackend = config_types.SandboxBackend;
pub const ObservabilityConfig = config_types.ObservabilityConfig;
pub const AutonomyConfig = config_types.AutonomyConfig;
pub const DockerRuntimeConfig = config_types.DockerRuntimeConfig;
pub const RuntimeConfig = config_types.RuntimeConfig;
pub const ModelFallbackEntry = config_types.ModelFallbackEntry;
pub const ReliabilityConfig = config_types.ReliabilityConfig;
pub const SchedulerConfig = config_types.SchedulerConfig;
pub const AgentConfig = config_types.AgentConfig;
pub const ModelRouteConfig = config_types.ModelRouteConfig;
pub const HeartbeatConfig = config_types.HeartbeatConfig;
pub const CronConfig = config_types.CronConfig;
pub const TelegramConfig = config_types.TelegramConfig;
pub const DiscordConfig = config_types.DiscordConfig;
pub const SlackConfig = config_types.SlackConfig;
pub const WebhookConfig = config_types.WebhookConfig;
pub const IMessageConfig = config_types.IMessageConfig;
pub const MatrixConfig = config_types.MatrixConfig;
pub const WhatsAppConfig = config_types.WhatsAppConfig;
pub const IrcConfig = config_types.IrcConfig;
pub const LarkReceiveMode = config_types.LarkReceiveMode;
pub const LarkConfig = config_types.LarkConfig;
pub const DingTalkConfig = config_types.DingTalkConfig;
pub const ChannelsConfig = config_types.ChannelsConfig;
pub const MemoryConfig = config_types.MemoryConfig;
pub const TunnelConfig = config_types.TunnelConfig;
pub const GatewayConfig = config_types.GatewayConfig;
pub const ComposioConfig = config_types.ComposioConfig;
pub const SecretsConfig = config_types.SecretsConfig;
pub const BrowserComputerUseConfig = config_types.BrowserComputerUseConfig;
pub const BrowserConfig = config_types.BrowserConfig;
pub const HttpRequestConfig = config_types.HttpRequestConfig;
pub const IdentityConfig = config_types.IdentityConfig;
pub const CostConfig = config_types.CostConfig;
pub const PeripheralBoardConfig = config_types.PeripheralBoardConfig;
pub const PeripheralsConfig = config_types.PeripheralsConfig;
pub const HardwareConfig = config_types.HardwareConfig;
pub const SandboxConfig = config_types.SandboxConfig;
pub const ResourceLimitsConfig = config_types.ResourceLimitsConfig;
pub const AuditConfig = config_types.AuditConfig;
pub const SecurityConfig = config_types.SecurityConfig;
pub const DelegateAgentConfig = config_types.DelegateAgentConfig;
pub const NamedAgentConfig = config_types.NamedAgentConfig;
pub const McpServerConfig = config_types.McpServerConfig;
pub const ModelPricing = config_types.ModelPricing;

// ── Top-level Config ────────────────────────────────────────────

pub const Config = struct {
    // Computed paths (not serialized)
    workspace_dir: []const u8,
    config_path: []const u8,

    // Top-level fields
    api_key: ?[]const u8 = null,
    api_url: ?[]const u8 = null,
    default_provider: []const u8 = "openrouter",
    default_model: ?[]const u8 = "anthropic/claude-sonnet-4",
    default_temperature: f64 = 0.7,

    // Model routing and delegate agents
    model_routes: []const ModelRouteConfig = &.{},
    agents: []const NamedAgentConfig = &.{},
    mcp_servers: []const McpServerConfig = &.{},

    // Nested sub-configs
    observability: ObservabilityConfig = .{},
    autonomy: AutonomyConfig = .{},
    runtime: RuntimeConfig = .{},
    reliability: ReliabilityConfig = .{},
    scheduler: SchedulerConfig = .{},
    agent: AgentConfig = .{},
    heartbeat: HeartbeatConfig = .{},
    cron: CronConfig = .{},
    channels: ChannelsConfig = .{},
    memory: MemoryConfig = .{},
    tunnel: TunnelConfig = .{},
    gateway: GatewayConfig = .{},
    composio: ComposioConfig = .{},
    secrets: SecretsConfig = .{},
    browser: BrowserConfig = .{},
    http_request: HttpRequestConfig = .{},
    identity: IdentityConfig = .{},
    cost: CostConfig = .{},
    peripherals: PeripheralsConfig = .{},
    hardware: HardwareConfig = .{},
    security: SecurityConfig = .{},

    // Convenience aliases for backward-compat flat access used by other modules.
    // These are set during load() to mirror nested values.
    temperature: f64 = 0.7,
    max_tokens: u32 = 4096,
    memory_backend: []const u8 = "sqlite",
    memory_auto_save: bool = true,
    heartbeat_enabled: bool = false,
    heartbeat_interval_minutes: u32 = 30,
    gateway_host: []const u8 = "127.0.0.1",
    gateway_port: u16 = 3000,
    workspace_only: bool = true,
    max_actions_per_hour: u32 = 20,

    allocator: std.mem.Allocator,

    /// Sync flat convenience fields from the nested sub-configs.
    pub fn syncFlatFields(self: *Config) void {
        self.temperature = self.default_temperature;
        self.memory_backend = self.memory.backend;
        self.memory_auto_save = self.memory.auto_save;
        self.heartbeat_enabled = self.heartbeat.enabled;
        self.heartbeat_interval_minutes = self.heartbeat.interval_minutes;
        self.gateway_host = self.gateway.host;
        self.gateway_port = self.gateway.port;
        self.workspace_only = self.autonomy.workspace_only;
        self.max_actions_per_hour = self.autonomy.max_actions_per_hour;
    }

    pub fn load(allocator: std.mem.Allocator) !Config {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.NoHomeDir,
            else => return err,
        };
        defer allocator.free(home);

        const config_dir = try std.fs.path.join(allocator, &.{ home, ".nullclaw" });
        const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.json" });
        const workspace_dir = try std.fs.path.join(allocator, &.{ config_dir, "workspace" });

        var cfg = Config{
            .workspace_dir = workspace_dir,
            .config_path = config_path,
            .allocator = allocator,
        };

        // Try to read existing config file
        if (std.fs.openFileAbsolute(config_path, .{})) |file| {
            defer file.close();
            const content = try file.readToEndAlloc(allocator, 1024 * 64);
            defer allocator.free(content);
            cfg.parseJson(content) catch {};
        } else |_| {
            // Config file doesn't exist yet — use defaults
        }

        // Environment variable overrides
        cfg.applyEnvOverrides();

        // Sync flat fields from nested structs
        cfg.syncFlatFields();

        return cfg;
    }

    /// Parse a JSON array of strings into an allocated slice.
    pub fn parseStringArray(self: *Config, arr: std.json.Array) ![]const []const u8 {
        return config_parse.parseStringArray(self.allocator, arr);
    }

    pub fn parseJson(self: *Config, content: []const u8) !void {
        return config_parse.parseJson(self, content);
    }

    /// Apply NULLCLAW_* environment variable overrides.
    pub fn applyEnvOverrides(self: *Config) void {
        // API Key
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_API_KEY")) |key| {
            self.api_key = key;
        } else |_| {}

        // Provider
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_PROVIDER")) |prov| {
            self.default_provider = prov;
        } else |_| {}

        // Model
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_MODEL")) |model| {
            self.default_model = model;
        } else |_| {}

        // Temperature
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_TEMPERATURE")) |temp_str| {
            defer self.allocator.free(temp_str);
            if (std.fmt.parseFloat(f64, temp_str)) |temp| {
                if (temp >= 0.0 and temp <= 2.0) {
                    self.default_temperature = temp;
                }
            } else |_| {}
        } else |_| {}

        // Gateway port
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_GATEWAY_PORT")) |port_str| {
            defer self.allocator.free(port_str);
            if (std.fmt.parseInt(u16, port_str, 10)) |port| {
                self.gateway.port = port;
            } else |_| {}
        } else |_| {}

        // Gateway host
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_GATEWAY_HOST")) |host| {
            self.gateway.host = host;
        } else |_| {}

        // Workspace
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_WORKSPACE")) |ws| {
            self.workspace_dir = ws;
        } else |_| {}

        // Allow public bind
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_ALLOW_PUBLIC_BIND")) |val| {
            defer self.allocator.free(val);
            self.gateway.allow_public_bind = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        } else |_| {}

        // Base URL (maps to api_url)
        if (std.process.getEnvVarOwned(self.allocator, "NULLCLAW_BASE_URL")) |url| {
            self.api_url = url;
        } else |_| {}
    }

    /// Save config as JSON to the config_path.
    pub fn save(self: *const Config) !void {
        const dir = std.fs.path.dirname(self.config_path) orelse return error.InvalidConfigPath;

        // Ensure parent directory exists
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file = try std.fs.createFileAbsolute(self.config_path, .{});
        defer file.close();

        var buf: [8192]u8 = undefined;
        var bw = file.writer(&buf);
        const w = &bw.interface;

        try w.print("{{\n", .{});

        // Top-level fields
        if (self.api_key) |key| {
            try w.print("  \"api_key\": \"{s}\",\n", .{key});
        }
        try w.print("  \"default_provider\": \"{s}\",\n", .{self.default_provider});
        if (self.default_model) |model| {
            try w.print("  \"default_model\": \"{s}\",\n", .{model});
        }
        try w.print("  \"default_temperature\": {d:.1},\n", .{self.default_temperature});

        // Observability
        try w.print("  \"observability\": {{\n", .{});
        try w.print("    \"backend\": \"{s}\"\n", .{self.observability.backend});
        try w.print("  }},\n", .{});

        // Autonomy
        try w.print("  \"autonomy\": {{\n", .{});
        try w.print("    \"level\": \"{s}\",\n", .{@tagName(self.autonomy.level)});
        try w.print("    \"workspace_only\": {s},\n", .{if (self.autonomy.workspace_only) "true" else "false"});
        try w.print("    \"max_actions_per_hour\": {d},\n", .{self.autonomy.max_actions_per_hour});
        try w.print("    \"max_cost_per_day_cents\": {d}\n", .{self.autonomy.max_cost_per_day_cents});
        try w.print("  }},\n", .{});

        // Heartbeat
        try w.print("  \"heartbeat\": {{\n", .{});
        try w.print("    \"enabled\": {s},\n", .{if (self.heartbeat.enabled) "true" else "false"});
        try w.print("    \"interval_minutes\": {d}\n", .{self.heartbeat.interval_minutes});
        try w.print("  }},\n", .{});

        // Memory
        try w.print("  \"memory\": {{\n", .{});
        try w.print("    \"backend\": \"{s}\",\n", .{self.memory.backend});
        try w.print("    \"auto_save\": {s},\n", .{if (self.memory.auto_save) "true" else "false"});
        try w.print("    \"hygiene_enabled\": {s},\n", .{if (self.memory.hygiene_enabled) "true" else "false"});
        try w.print("    \"archive_after_days\": {d},\n", .{self.memory.archive_after_days});
        try w.print("    \"purge_after_days\": {d},\n", .{self.memory.purge_after_days});
        try w.print("    \"conversation_retention_days\": {d}\n", .{self.memory.conversation_retention_days});
        try w.print("  }},\n", .{});

        // Gateway
        try w.print("  \"gateway\": {{\n", .{});
        try w.print("    \"port\": {d},\n", .{self.gateway.port});
        try w.print("    \"host\": \"{s}\",\n", .{self.gateway.host});
        try w.print("    \"require_pairing\": {s}\n", .{if (self.gateway.require_pairing) "true" else "false"});
        try w.print("  }},\n", .{});

        // Cost
        try w.print("  \"cost\": {{\n", .{});
        try w.print("    \"enabled\": {s},\n", .{if (self.cost.enabled) "true" else "false"});
        try w.print("    \"daily_limit_usd\": {d:.1},\n", .{self.cost.daily_limit_usd});
        try w.print("    \"monthly_limit_usd\": {d:.1}\n", .{self.cost.monthly_limit_usd});
        try w.print("  }},\n", .{});

        // Hardware
        try w.print("  \"hardware\": {{\n", .{});
        try w.print("    \"enabled\": {s},\n", .{if (self.hardware.enabled) "true" else "false"});
        try w.print("    \"transport\": \"{s}\",\n", .{@tagName(self.hardware.transport)});
        try w.print("    \"baud_rate\": {d}\n", .{self.hardware.baud_rate});
        try w.print("  }}\n", .{});

        try w.print("}}\n", .{});
        try w.flush();
    }

    pub fn ensureDirs(self: *const Config) !void {
        const dir = std.fs.path.dirname(self.config_path) orelse return;
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        std.fs.makeDirAbsolute(self.workspace_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // ── Validation ──────────────────────────────────────────────

    pub const ValidationError = error{
        TemperatureOutOfRange,
        InvalidPort,
        InvalidRetryCount,
        InvalidBackoffMs,
    };

    pub fn validate(self: *const Config) ValidationError!void {
        if (self.default_temperature < 0.0 or self.default_temperature > 2.0) {
            return ValidationError.TemperatureOutOfRange;
        }
        if (self.gateway.port == 0) {
            return ValidationError.InvalidPort;
        }
        if (self.reliability.provider_retries > 100) {
            return ValidationError.InvalidRetryCount;
        }
        if (self.reliability.provider_backoff_ms > 600_000) {
            return ValidationError.InvalidBackoffMs;
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────

test "config defaults" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqualStrings("openrouter", cfg.default_provider);
    try std.testing.expectEqual(@as(f64, 0.7), cfg.default_temperature);
    try std.testing.expectEqual(@as(f64, 0.7), cfg.temperature);
    try std.testing.expectEqualStrings("sqlite", cfg.memory_backend);
    try std.testing.expect(cfg.memory_auto_save);
    try std.testing.expect(!cfg.heartbeat_enabled);
    try std.testing.expect(cfg.workspace_only);
    try std.testing.expectEqual(@as(u32, 20), cfg.max_actions_per_hour);
}

test "nested sub-config defaults" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    // Observability
    try std.testing.expectEqualStrings("none", cfg.observability.backend);
    try std.testing.expect(cfg.observability.otel_endpoint == null);

    // Autonomy
    try std.testing.expectEqual(AutonomyLevel.supervised, cfg.autonomy.level);
    try std.testing.expect(cfg.autonomy.workspace_only);
    try std.testing.expectEqual(@as(u32, 20), cfg.autonomy.max_actions_per_hour);
    try std.testing.expectEqual(@as(u32, 500), cfg.autonomy.max_cost_per_day_cents);
    try std.testing.expect(cfg.autonomy.require_approval_for_medium_risk);
    try std.testing.expect(cfg.autonomy.block_high_risk_commands);

    // Runtime
    try std.testing.expectEqualStrings("native", cfg.runtime.kind);
    try std.testing.expectEqualStrings("alpine:3.20", cfg.runtime.docker.image);
    try std.testing.expectEqualStrings("none", cfg.runtime.docker.network);
    try std.testing.expectEqual(@as(?u64, 512), cfg.runtime.docker.memory_limit_mb);
    try std.testing.expect(cfg.runtime.docker.read_only_rootfs);
    try std.testing.expect(cfg.runtime.docker.mount_workspace);

    // Reliability
    try std.testing.expectEqual(@as(u32, 2), cfg.reliability.provider_retries);
    try std.testing.expectEqual(@as(u64, 500), cfg.reliability.provider_backoff_ms);

    // Scheduler
    try std.testing.expect(cfg.scheduler.enabled);
    try std.testing.expectEqual(@as(u32, 64), cfg.scheduler.max_tasks);
    try std.testing.expectEqual(@as(u32, 4), cfg.scheduler.max_concurrent);

    // Agent
    try std.testing.expect(!cfg.agent.compact_context);
    try std.testing.expectEqual(@as(u32, 10), cfg.agent.max_tool_iterations);
    try std.testing.expectEqual(@as(u32, 50), cfg.agent.max_history_messages);
    try std.testing.expect(!cfg.agent.parallel_tools);
    try std.testing.expectEqualStrings("auto", cfg.agent.tool_dispatcher);

    // Heartbeat
    try std.testing.expect(!cfg.heartbeat.enabled);
    try std.testing.expectEqual(@as(u32, 30), cfg.heartbeat.interval_minutes);

    // Channels
    try std.testing.expect(cfg.channels.cli);
    try std.testing.expect(cfg.channels.telegram == null);
    try std.testing.expect(cfg.channels.discord == null);

    // Memory
    try std.testing.expectEqualStrings("sqlite", cfg.memory.backend);
    try std.testing.expect(cfg.memory.auto_save);
    try std.testing.expect(cfg.memory.hygiene_enabled);
    try std.testing.expectEqual(@as(u32, 7), cfg.memory.archive_after_days);
    try std.testing.expectEqual(@as(u32, 30), cfg.memory.purge_after_days);
    try std.testing.expectEqual(@as(u32, 30), cfg.memory.conversation_retention_days);
    try std.testing.expectEqualStrings("none", cfg.memory.embedding_provider);
    try std.testing.expectEqualStrings("text-embedding-3-small", cfg.memory.embedding_model);
    try std.testing.expectEqual(@as(u32, 1536), cfg.memory.embedding_dimensions);
    try std.testing.expect(!cfg.memory.response_cache_enabled);
    try std.testing.expect(!cfg.memory.snapshot_enabled);
    try std.testing.expect(cfg.memory.auto_hydrate);

    // Gateway
    try std.testing.expectEqual(@as(u16, 3000), cfg.gateway.port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.gateway.host);
    try std.testing.expect(cfg.gateway.require_pairing);
    try std.testing.expect(!cfg.gateway.allow_public_bind);

    // Cost
    try std.testing.expect(!cfg.cost.enabled);
    try std.testing.expectEqual(@as(f64, 10.0), cfg.cost.daily_limit_usd);
    try std.testing.expectEqual(@as(f64, 100.0), cfg.cost.monthly_limit_usd);
    try std.testing.expectEqual(@as(u8, 80), cfg.cost.warn_at_percent);

    // Identity
    try std.testing.expectEqualStrings("openclaw", cfg.identity.format);
    try std.testing.expect(cfg.identity.aieos_path == null);

    // Composio
    try std.testing.expect(!cfg.composio.enabled);
    try std.testing.expectEqualStrings("default", cfg.composio.entity_id);

    // Secrets
    try std.testing.expect(cfg.secrets.encrypt);

    // Browser
    try std.testing.expect(!cfg.browser.enabled);
    try std.testing.expectEqualStrings("agent_browser", cfg.browser.backend);
    try std.testing.expect(cfg.browser.native_headless);

    // HTTP Request
    try std.testing.expect(!cfg.http_request.enabled);
    try std.testing.expectEqual(@as(u32, 1_000_000), cfg.http_request.max_response_size);
    try std.testing.expectEqual(@as(u64, 30), cfg.http_request.timeout_secs);

    // Hardware
    try std.testing.expect(!cfg.hardware.enabled);
    try std.testing.expectEqual(HardwareTransport.none, cfg.hardware.transport);
    try std.testing.expectEqual(@as(u32, 115200), cfg.hardware.baud_rate);

    // Peripherals
    try std.testing.expect(!cfg.peripherals.enabled);
    try std.testing.expect(cfg.peripherals.datasheet_dir == null);

    // Security
    try std.testing.expect(cfg.security.sandbox.enabled == null);
    try std.testing.expectEqual(SandboxBackend.auto, cfg.security.sandbox.backend);
    try std.testing.expectEqual(@as(u32, 512), cfg.security.resources.max_memory_mb);
    try std.testing.expectEqual(@as(u64, 60), cfg.security.resources.max_cpu_time_seconds);
    try std.testing.expect(cfg.security.audit.enabled);
    try std.testing.expectEqualStrings("audit.log", cfg.security.audit.log_path);

    // Tunnel
    try std.testing.expectEqualStrings("none", cfg.tunnel.provider);
}

test "json parse roundtrip" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "default_provider": "anthropic",
        \\  "default_model": "claude-opus-4",
        \\  "default_temperature": 0.5,
        \\  "api_key": "sk-test",
        \\  "heartbeat": {"enabled": true, "interval_minutes": 15},
        \\  "memory": {"backend": "markdown", "auto_save": false},
        \\  "gateway": {"port": 9090, "host": "0.0.0.0"},
        \\  "autonomy": {"level": "full", "workspace_only": false, "max_actions_per_hour": 50},
        \\  "runtime": {"kind": "docker"},
        \\  "cost": {"enabled": true, "daily_limit_usd": 25.0}
        \\}
    ;

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    try cfg.parseJson(json);
    cfg.syncFlatFields();

    try std.testing.expectEqualStrings("anthropic", cfg.default_provider);
    try std.testing.expectEqualStrings("claude-opus-4", cfg.default_model.?);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.default_temperature);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.temperature);
    try std.testing.expectEqualStrings("sk-test", cfg.api_key.?);
    try std.testing.expect(cfg.heartbeat.enabled);
    try std.testing.expect(cfg.heartbeat_enabled);
    try std.testing.expectEqual(@as(u32, 15), cfg.heartbeat.interval_minutes);
    try std.testing.expectEqualStrings("markdown", cfg.memory.backend);
    try std.testing.expectEqualStrings("markdown", cfg.memory_backend);
    try std.testing.expect(!cfg.memory.auto_save);
    try std.testing.expect(!cfg.memory_auto_save);
    try std.testing.expectEqual(@as(u16, 9090), cfg.gateway.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.gateway.host);
    try std.testing.expectEqual(AutonomyLevel.full, cfg.autonomy.level);
    try std.testing.expect(!cfg.autonomy.workspace_only);
    try std.testing.expect(!cfg.workspace_only);
    try std.testing.expectEqual(@as(u32, 50), cfg.autonomy.max_actions_per_hour);
    try std.testing.expectEqualStrings("docker", cfg.runtime.kind);
    try std.testing.expect(cfg.cost.enabled);
    try std.testing.expectEqual(@as(f64, 25.0), cfg.cost.daily_limit_usd);

    // Clean up allocated strings
    allocator.free(cfg.default_provider);
    allocator.free(cfg.default_model.?);
    allocator.free(cfg.api_key.?);
    allocator.free(cfg.memory.backend);
    allocator.free(cfg.gateway.host);
    allocator.free(cfg.runtime.kind);
}

test "validation rejects bad temperature" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_temperature = 5.0,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(Config.ValidationError.TemperatureOutOfRange, cfg.validate());
}

test "validation rejects zero port" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.gateway.port = 0;
    try std.testing.expectError(Config.ValidationError.InvalidPort, cfg.validate());
}

test "validation passes for defaults" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try cfg.validate();
}

test "syncFlatFields propagates nested values" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.default_temperature = 1.5;
    cfg.memory.backend = "lucid";
    cfg.memory.auto_save = false;
    cfg.heartbeat.enabled = true;
    cfg.heartbeat.interval_minutes = 10;
    cfg.gateway.host = "0.0.0.0";
    cfg.gateway.port = 9999;
    cfg.autonomy.workspace_only = false;
    cfg.autonomy.max_actions_per_hour = 999;

    cfg.syncFlatFields();

    try std.testing.expectEqual(@as(f64, 1.5), cfg.temperature);
    try std.testing.expectEqualStrings("lucid", cfg.memory_backend);
    try std.testing.expect(!cfg.memory_auto_save);
    try std.testing.expect(cfg.heartbeat_enabled);
    try std.testing.expectEqual(@as(u32, 10), cfg.heartbeat_interval_minutes);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.gateway_host);
    try std.testing.expectEqual(@as(u16, 9999), cfg.gateway_port);
    try std.testing.expect(!cfg.workspace_only);
    try std.testing.expectEqual(@as(u32, 999), cfg.max_actions_per_hour);
}

// ── Channel config struct validation ─────────────────────────────

test "telegram config constructible" {
    const tc = TelegramConfig{ .bot_token = "123:XYZ" };
    try std.testing.expectEqualStrings("123:XYZ", tc.bot_token);
}

test "discord config constructible with guild" {
    const dc = DiscordConfig{ .bot_token = "discord-token", .guild_id = "12345" };
    try std.testing.expectEqualStrings("discord-token", dc.bot_token);
    try std.testing.expectEqualStrings("12345", dc.guild_id.?);
}

test "discord config optional guild null" {
    const dc = DiscordConfig{ .bot_token = "tok" };
    try std.testing.expect(dc.guild_id == null);
    try std.testing.expect(!dc.listen_to_bots);
}

test "discord config listen to bots default false" {
    const dc = DiscordConfig{ .bot_token = "tok" };
    try std.testing.expect(!dc.listen_to_bots);
}

test "slack config constructible" {
    const sc = SlackConfig{ .bot_token = "xoxb-tok" };
    try std.testing.expectEqualStrings("xoxb-tok", sc.bot_token);
    try std.testing.expect(sc.app_token == null);
    try std.testing.expect(sc.channel_id == null);
}

test "slack config with channel" {
    const sc = SlackConfig{ .bot_token = "xoxb-tok", .channel_id = "C123" };
    try std.testing.expectEqualStrings("C123", sc.channel_id.?);
}

test "webhook config defaults" {
    const wc = WebhookConfig{};
    try std.testing.expectEqual(@as(u16, 8080), wc.port);
    try std.testing.expect(wc.secret == null);
}

test "webhook config with secret" {
    const wc = WebhookConfig{ .secret = "my-secret-key" };
    try std.testing.expectEqualStrings("my-secret-key", wc.secret.?);
}

test "imessage config defaults" {
    const ic = IMessageConfig{};
    try std.testing.expect(!ic.enabled);
}

test "matrix config constructible" {
    const mc = MatrixConfig{
        .homeserver = "https://matrix.org",
        .access_token = "syt_token_abc",
        .room_id = "!room123:matrix.org",
    };
    try std.testing.expectEqualStrings("https://matrix.org", mc.homeserver);
    try std.testing.expectEqualStrings("syt_token_abc", mc.access_token);
    try std.testing.expectEqualStrings("!room123:matrix.org", mc.room_id);
}

test "whatsapp config constructible" {
    const wc = WhatsAppConfig{
        .access_token = "EAABx",
        .phone_number_id = "123456789",
        .verify_token = "my-verify-token",
    };
    try std.testing.expectEqualStrings("EAABx", wc.access_token);
    try std.testing.expectEqualStrings("123456789", wc.phone_number_id);
    try std.testing.expectEqualStrings("my-verify-token", wc.verify_token);
    try std.testing.expect(wc.app_secret == null);
}

test "whatsapp config with app secret" {
    const wc = WhatsAppConfig{
        .access_token = "tok",
        .phone_number_id = "123",
        .verify_token = "ver",
        .app_secret = "secret123",
    };
    try std.testing.expectEqualStrings("secret123", wc.app_secret.?);
}

test "irc config defaults" {
    const ic = IrcConfig{ .server = "irc.libera.chat", .nickname = "ycbot" };
    try std.testing.expectEqual(@as(u16, 6697), ic.port);
    try std.testing.expect(ic.username == null);
    try std.testing.expect(ic.server_password == null);
    try std.testing.expect(ic.nickserv_password == null);
    try std.testing.expect(ic.sasl_password == null);
    try std.testing.expect(ic.verify_tls);
}

test "lark config constructible" {
    const lc = LarkConfig{ .app_id = "app-id", .app_secret = "app-secret" };
    try std.testing.expectEqualStrings("app-id", lc.app_id);
    try std.testing.expectEqualStrings("app-secret", lc.app_secret);
    try std.testing.expect(lc.encrypt_key == null);
    try std.testing.expect(lc.verification_token == null);
    try std.testing.expect(!lc.use_feishu);
}

test "lark config feishu mode" {
    const lc = LarkConfig{ .app_id = "id", .app_secret = "sec", .use_feishu = true };
    try std.testing.expect(lc.use_feishu);
}

test "dingtalk config constructible" {
    const dt = DingTalkConfig{ .client_id = "cid", .client_secret = "csec" };
    try std.testing.expectEqualStrings("cid", dt.client_id);
    try std.testing.expectEqualStrings("csec", dt.client_secret);
}

// ── Channels config ─────────────────────────────────────────────

test "channels config default all none except cli" {
    const c = ChannelsConfig{};
    try std.testing.expect(c.cli);
    try std.testing.expect(c.telegram == null);
    try std.testing.expect(c.discord == null);
    try std.testing.expect(c.slack == null);
    try std.testing.expect(c.webhook == null);
    try std.testing.expect(c.imessage == null);
    try std.testing.expect(c.matrix == null);
    try std.testing.expect(c.whatsapp == null);
    try std.testing.expect(c.irc == null);
    try std.testing.expect(c.lark == null);
    try std.testing.expect(c.dingtalk == null);
}

test "channels config with telegram" {
    const c = ChannelsConfig{
        .telegram = TelegramConfig{ .bot_token = "123:ABC" },
    };
    try std.testing.expect(c.telegram != null);
    try std.testing.expectEqualStrings("123:ABC", c.telegram.?.bot_token);
}

test "channels config with discord" {
    const c = ChannelsConfig{
        .discord = DiscordConfig{ .bot_token = "dtok", .guild_id = "g123" },
    };
    try std.testing.expect(c.discord != null);
    try std.testing.expectEqualStrings("dtok", c.discord.?.bot_token);
    try std.testing.expectEqualStrings("g123", c.discord.?.guild_id.?);
}

test "channels config with imessage and matrix" {
    const c = ChannelsConfig{
        .imessage = IMessageConfig{},
        .matrix = MatrixConfig{
            .homeserver = "https://m.org",
            .access_token = "tok",
            .room_id = "!r:m",
        },
    };
    try std.testing.expect(c.imessage != null);
    try std.testing.expect(c.matrix != null);
    try std.testing.expectEqualStrings("https://m.org", c.matrix.?.homeserver);
}

test "channels config with whatsapp" {
    const c = ChannelsConfig{
        .whatsapp = WhatsAppConfig{
            .access_token = "tok",
            .phone_number_id = "123",
            .verify_token = "ver",
        },
    };
    try std.testing.expect(c.whatsapp != null);
    try std.testing.expectEqualStrings("123", c.whatsapp.?.phone_number_id);
}

test "channels config with lark and dingtalk" {
    const c = ChannelsConfig{
        .lark = LarkConfig{ .app_id = "lid", .app_secret = "lsec" },
        .dingtalk = DingTalkConfig{ .client_id = "did", .client_secret = "dsec" },
    };
    try std.testing.expect(c.lark != null);
    try std.testing.expect(c.dingtalk != null);
    try std.testing.expectEqualStrings("lid", c.lark.?.app_id);
    try std.testing.expectEqualStrings("did", c.dingtalk.?.client_id);
}

// ── Gateway config defaults and security ─────────────────────────

test "gateway config default values" {
    const g = GatewayConfig{};
    try std.testing.expectEqual(@as(u16, 3000), g.port);
    try std.testing.expectEqualStrings("127.0.0.1", g.host);
    try std.testing.expect(g.require_pairing);
    try std.testing.expect(!g.allow_public_bind);
    try std.testing.expectEqual(@as(u32, 10), g.pair_rate_limit_per_minute);
    try std.testing.expectEqual(@as(u32, 60), g.webhook_rate_limit_per_minute);
    try std.testing.expectEqual(@as(u64, 300), g.idempotency_ttl_secs);
}

test "gateway config requires pairing by default" {
    const g = GatewayConfig{};
    try std.testing.expect(g.require_pairing);
}

test "gateway config blocks public bind by default" {
    const g = GatewayConfig{};
    try std.testing.expect(!g.allow_public_bind);
}

test "gateway config custom values" {
    const g = GatewayConfig{
        .port = 8080,
        .host = "0.0.0.0",
        .require_pairing = false,
        .allow_public_bind = true,
        .pair_rate_limit_per_minute = 20,
        .webhook_rate_limit_per_minute = 120,
        .idempotency_ttl_secs = 600,
    };
    try std.testing.expectEqual(@as(u16, 8080), g.port);
    try std.testing.expectEqualStrings("0.0.0.0", g.host);
    try std.testing.expect(!g.require_pairing);
    try std.testing.expect(g.allow_public_bind);
    try std.testing.expectEqual(@as(u32, 20), g.pair_rate_limit_per_minute);
}

// ── Composio config ─────────────────────────────────────────────

test "composio config default disabled" {
    const c = ComposioConfig{};
    try std.testing.expect(!c.enabled);
    try std.testing.expect(c.api_key == null);
    try std.testing.expectEqualStrings("default", c.entity_id);
}

test "composio config custom" {
    const c = ComposioConfig{
        .enabled = true,
        .api_key = "comp-key-123",
        .entity_id = "user42",
    };
    try std.testing.expect(c.enabled);
    try std.testing.expectEqualStrings("comp-key-123", c.api_key.?);
    try std.testing.expectEqualStrings("user42", c.entity_id);
}

// ── Secrets config ──────────────────────────────────────────────

test "secrets config default encrypts" {
    const s = SecretsConfig{};
    try std.testing.expect(s.encrypt);
}

test "secrets config can disable" {
    const s = SecretsConfig{ .encrypt = false };
    try std.testing.expect(!s.encrypt);
}

// ── Browser config ──────────────────────────────────────────────

test "browser config default disabled" {
    const b = BrowserConfig{};
    try std.testing.expect(!b.enabled);
    try std.testing.expectEqualStrings("agent_browser", b.backend);
    try std.testing.expect(b.native_headless);
    try std.testing.expectEqualStrings("http://127.0.0.1:9515", b.native_webdriver_url);
    try std.testing.expect(b.native_chrome_path == null);
    try std.testing.expect(b.session_name == null);
}

test "browser computer use config defaults" {
    const cu = BrowserComputerUseConfig{};
    try std.testing.expectEqualStrings("http://127.0.0.1:8787/v1/actions", cu.endpoint);
    try std.testing.expect(cu.api_key == null);
    try std.testing.expectEqual(@as(u64, 15_000), cu.timeout_ms);
    try std.testing.expect(!cu.allow_remote_endpoint);
    try std.testing.expect(cu.max_coordinate_x == null);
    try std.testing.expect(cu.max_coordinate_y == null);
}

test "browser config custom values" {
    const b = BrowserConfig{
        .enabled = true,
        .backend = "auto",
        .native_headless = false,
        .native_webdriver_url = "http://localhost:4444",
        .native_chrome_path = "/usr/bin/chromium",
    };
    try std.testing.expect(b.enabled);
    try std.testing.expectEqualStrings("auto", b.backend);
    try std.testing.expect(!b.native_headless);
    try std.testing.expectEqualStrings("/usr/bin/chromium", b.native_chrome_path.?);
}

// ── HTTP request config ─────────────────────────────────────────

test "http request config defaults" {
    const h = HttpRequestConfig{};
    try std.testing.expect(!h.enabled);
    try std.testing.expectEqual(@as(u32, 1_000_000), h.max_response_size);
    try std.testing.expectEqual(@as(u64, 30), h.timeout_secs);
}

test "http request config custom" {
    const h = HttpRequestConfig{ .enabled = true, .max_response_size = 500_000, .timeout_secs = 60 };
    try std.testing.expect(h.enabled);
    try std.testing.expectEqual(@as(u32, 500_000), h.max_response_size);
    try std.testing.expectEqual(@as(u64, 60), h.timeout_secs);
}

// ── Identity config ─────────────────────────────────────────────

test "identity config defaults" {
    const i = IdentityConfig{};
    try std.testing.expectEqualStrings("openclaw", i.format);
    try std.testing.expect(i.aieos_path == null);
    try std.testing.expect(i.aieos_inline == null);
}

test "identity config custom" {
    const i = IdentityConfig{ .format = "aieos", .aieos_path = "identity.json" };
    try std.testing.expectEqualStrings("aieos", i.format);
    try std.testing.expectEqualStrings("identity.json", i.aieos_path.?);
}

// ── Cost config ─────────────────────────────────────────────────

test "cost config defaults" {
    const c = CostConfig{};
    try std.testing.expect(!c.enabled);
    try std.testing.expectEqual(@as(f64, 10.0), c.daily_limit_usd);
    try std.testing.expectEqual(@as(f64, 100.0), c.monthly_limit_usd);
    try std.testing.expectEqual(@as(u8, 80), c.warn_at_percent);
    try std.testing.expect(!c.allow_override);
}

test "cost config custom" {
    const c = CostConfig{
        .enabled = true,
        .daily_limit_usd = 25.0,
        .monthly_limit_usd = 250.0,
        .warn_at_percent = 90,
        .allow_override = true,
    };
    try std.testing.expect(c.enabled);
    try std.testing.expectEqual(@as(f64, 25.0), c.daily_limit_usd);
    try std.testing.expectEqual(@as(u8, 90), c.warn_at_percent);
    try std.testing.expect(c.allow_override);
}

// ── Peripherals config ──────────────────────────────────────────

test "peripherals config default disabled" {
    const p = PeripheralsConfig{};
    try std.testing.expect(!p.enabled);
    try std.testing.expect(p.datasheet_dir == null);
}

test "peripheral board config defaults" {
    const b = PeripheralBoardConfig{};
    try std.testing.expectEqualStrings("", b.board);
    try std.testing.expectEqualStrings("serial", b.transport);
    try std.testing.expect(b.path == null);
    try std.testing.expectEqual(@as(u32, 115200), b.baud);
}

test "peripheral board config custom" {
    const b = PeripheralBoardConfig{
        .board = "nucleo-f401re",
        .transport = "serial",
        .path = "/dev/ttyACM0",
        .baud = 115200,
    };
    try std.testing.expectEqualStrings("nucleo-f401re", b.board);
    try std.testing.expectEqualStrings("/dev/ttyACM0", b.path.?);
}

// ── Hardware config ─────────────────────────────────────────────

test "hardware config defaults" {
    const h = HardwareConfig{};
    try std.testing.expect(!h.enabled);
    try std.testing.expectEqual(HardwareTransport.none, h.transport);
    try std.testing.expect(h.serial_port == null);
    try std.testing.expectEqual(@as(u32, 115200), h.baud_rate);
    try std.testing.expect(h.probe_target == null);
    try std.testing.expect(!h.workspace_datasheets);
}

test "hardware config serial mode" {
    const h = HardwareConfig{
        .enabled = true,
        .transport = .serial,
        .serial_port = "/dev/ttyACM0",
        .baud_rate = 9600,
    };
    try std.testing.expect(h.enabled);
    try std.testing.expectEqual(HardwareTransport.serial, h.transport);
    try std.testing.expectEqualStrings("/dev/ttyACM0", h.serial_port.?);
}

test "hardware config probe mode" {
    const h = HardwareConfig{
        .enabled = true,
        .transport = .probe,
        .probe_target = "STM32F401RE",
    };
    try std.testing.expectEqual(HardwareTransport.probe, h.transport);
    try std.testing.expectEqualStrings("STM32F401RE", h.probe_target.?);
}

// ── Security sub-configs ────────────────────────────────────────

test "sandbox config defaults" {
    const s = SandboxConfig{};
    try std.testing.expect(s.enabled == null);
    try std.testing.expectEqual(SandboxBackend.auto, s.backend);
}

test "sandbox config explicit enable" {
    const s = SandboxConfig{ .enabled = true, .backend = .firejail };
    try std.testing.expect(s.enabled.?);
    try std.testing.expectEqual(SandboxBackend.firejail, s.backend);
}

test "resource limits config defaults" {
    const r = ResourceLimitsConfig{};
    try std.testing.expectEqual(@as(u32, 512), r.max_memory_mb);
    try std.testing.expectEqual(@as(u64, 60), r.max_cpu_time_seconds);
    try std.testing.expectEqual(@as(u32, 10), r.max_subprocesses);
    try std.testing.expect(r.memory_monitoring);
}

test "resource limits config custom" {
    const r = ResourceLimitsConfig{
        .max_memory_mb = 1024,
        .max_cpu_time_seconds = 120,
        .max_subprocesses = 20,
        .memory_monitoring = false,
    };
    try std.testing.expectEqual(@as(u32, 1024), r.max_memory_mb);
    try std.testing.expectEqual(@as(u64, 120), r.max_cpu_time_seconds);
    try std.testing.expect(!r.memory_monitoring);
}

test "audit config defaults" {
    const a = AuditConfig{};
    try std.testing.expect(a.enabled);
    try std.testing.expectEqualStrings("audit.log", a.log_path);
    try std.testing.expectEqual(@as(u32, 100), a.max_size_mb);
    try std.testing.expect(!a.sign_events);
}

test "audit config custom" {
    const a = AuditConfig{
        .enabled = false,
        .log_path = "custom_audit.log",
        .max_size_mb = 50,
        .sign_events = true,
    };
    try std.testing.expect(!a.enabled);
    try std.testing.expectEqualStrings("custom_audit.log", a.log_path);
    try std.testing.expect(a.sign_events);
}

test "security config defaults" {
    const s = SecurityConfig{};
    try std.testing.expect(s.sandbox.enabled == null);
    try std.testing.expectEqual(SandboxBackend.auto, s.sandbox.backend);
    try std.testing.expectEqual(@as(u32, 512), s.resources.max_memory_mb);
    try std.testing.expect(s.audit.enabled);
}

// ── Delegate agent config ───────────────────────────────────────

test "delegate agent config defaults" {
    const d = DelegateAgentConfig{
        .provider = "anthropic",
        .model = "claude-sonnet-4",
    };
    try std.testing.expectEqualStrings("anthropic", d.provider);
    try std.testing.expectEqualStrings("claude-sonnet-4", d.model);
    try std.testing.expect(d.system_prompt == null);
    try std.testing.expect(d.api_key == null);
    try std.testing.expect(d.temperature == null);
    try std.testing.expectEqual(@as(u32, 3), d.max_depth);
}

test "delegate agent config custom" {
    const d = DelegateAgentConfig{
        .provider = "openai",
        .model = "gpt-4o",
        .system_prompt = "You are a helper",
        .api_key = "sk-test",
        .temperature = 0.5,
        .max_depth = 5,
    };
    try std.testing.expectEqualStrings("You are a helper", d.system_prompt.?);
    try std.testing.expectEqualStrings("sk-test", d.api_key.?);
    try std.testing.expectEqual(@as(f64, 0.5), d.temperature.?);
    try std.testing.expectEqual(@as(u32, 5), d.max_depth);
}

// ── Autonomy config ─────────────────────────────────────────────

test "autonomy config defaults" {
    const a = AutonomyConfig{};
    try std.testing.expectEqual(AutonomyLevel.supervised, a.level);
    try std.testing.expect(a.workspace_only);
    try std.testing.expectEqual(@as(u32, 20), a.max_actions_per_hour);
    try std.testing.expectEqual(@as(u32, 500), a.max_cost_per_day_cents);
    try std.testing.expect(a.require_approval_for_medium_risk);
    try std.testing.expect(a.block_high_risk_commands);
}

test "autonomy config full mode" {
    const a = AutonomyConfig{
        .level = .full,
        .workspace_only = false,
        .max_actions_per_hour = 100,
        .max_cost_per_day_cents = 2000,
        .require_approval_for_medium_risk = false,
        .block_high_risk_commands = false,
    };
    try std.testing.expectEqual(AutonomyLevel.full, a.level);
    try std.testing.expect(!a.workspace_only);
    try std.testing.expect(!a.require_approval_for_medium_risk);
    try std.testing.expect(!a.block_high_risk_commands);
}

// ── Runtime config ──────────────────────────────────────────────

test "runtime config defaults" {
    const r = RuntimeConfig{};
    try std.testing.expectEqualStrings("native", r.kind);
    try std.testing.expectEqualStrings("alpine:3.20", r.docker.image);
    try std.testing.expectEqualStrings("none", r.docker.network);
    try std.testing.expectEqual(@as(?u64, 512), r.docker.memory_limit_mb);
    try std.testing.expect(r.docker.read_only_rootfs);
    try std.testing.expect(r.docker.mount_workspace);
}

test "runtime config docker mode" {
    const r = RuntimeConfig{
        .kind = "docker",
        .docker = DockerRuntimeConfig{
            .image = "ubuntu:24.04",
            .network = "bridge",
            .memory_limit_mb = 1024,
            .cpu_limit = 2.0,
            .read_only_rootfs = false,
            .mount_workspace = false,
        },
    };
    try std.testing.expectEqualStrings("docker", r.kind);
    try std.testing.expectEqualStrings("ubuntu:24.04", r.docker.image);
    try std.testing.expectEqualStrings("bridge", r.docker.network);
    try std.testing.expectEqual(@as(?u64, 1024), r.docker.memory_limit_mb);
    try std.testing.expect(!r.docker.read_only_rootfs);
}

// ── Reliability config ──────────────────────────────────────────

test "reliability config defaults" {
    const r = ReliabilityConfig{};
    try std.testing.expectEqual(@as(u32, 2), r.provider_retries);
    try std.testing.expectEqual(@as(u64, 500), r.provider_backoff_ms);
    try std.testing.expectEqual(@as(u64, 2), r.channel_initial_backoff_secs);
    try std.testing.expectEqual(@as(u64, 60), r.channel_max_backoff_secs);
    try std.testing.expectEqual(@as(u64, 15), r.scheduler_poll_secs);
    try std.testing.expectEqual(@as(u32, 2), r.scheduler_retries);
}

// ── Scheduler config ────────────────────────────────────────────

test "scheduler config defaults" {
    const s = SchedulerConfig{};
    try std.testing.expect(s.enabled);
    try std.testing.expectEqual(@as(u32, 64), s.max_tasks);
    try std.testing.expectEqual(@as(u32, 4), s.max_concurrent);
}

test "scheduler config disabled" {
    const s = SchedulerConfig{ .enabled = false, .max_tasks = 10, .max_concurrent = 1 };
    try std.testing.expect(!s.enabled);
    try std.testing.expectEqual(@as(u32, 10), s.max_tasks);
}

// ── Agent config ────────────────────────────────────────────────

test "agent config defaults" {
    const a = AgentConfig{};
    try std.testing.expect(!a.compact_context);
    try std.testing.expectEqual(@as(u32, 10), a.max_tool_iterations);
    try std.testing.expectEqual(@as(u32, 50), a.max_history_messages);
    try std.testing.expect(!a.parallel_tools);
    try std.testing.expectEqualStrings("auto", a.tool_dispatcher);
    try std.testing.expectEqual(@as(u64, 128_000), a.token_limit);
}

test "agent config compact mode" {
    const a = AgentConfig{
        .compact_context = true,
        .max_tool_iterations = 20,
        .max_history_messages = 80,
        .parallel_tools = true,
        .tool_dispatcher = "xml",
    };
    try std.testing.expect(a.compact_context);
    try std.testing.expectEqual(@as(u32, 20), a.max_tool_iterations);
    try std.testing.expectEqual(@as(u32, 80), a.max_history_messages);
    try std.testing.expect(a.parallel_tools);
    try std.testing.expectEqualStrings("xml", a.tool_dispatcher);
}

// ── Model route config ──────────────────────────────────────────

test "model route config constructible" {
    const m = ModelRouteConfig{
        .hint = "reasoning",
        .provider = "openrouter",
        .model = "anthropic/claude-opus-4",
    };
    try std.testing.expectEqualStrings("reasoning", m.hint);
    try std.testing.expectEqualStrings("openrouter", m.provider);
    try std.testing.expect(m.api_key == null);
}

test "model route config with api key" {
    const m = ModelRouteConfig{
        .hint = "fast",
        .provider = "groq",
        .model = "llama-3.3-70b-versatile",
        .api_key = "gsk_test",
    };
    try std.testing.expectEqualStrings("gsk_test", m.api_key.?);
}

// ── Heartbeat config ────────────────────────────────────────────

test "heartbeat config defaults" {
    const h = HeartbeatConfig{};
    try std.testing.expect(!h.enabled);
    try std.testing.expectEqual(@as(u32, 30), h.interval_minutes);
}

test "heartbeat config enabled" {
    const h = HeartbeatConfig{ .enabled = true, .interval_minutes = 15 };
    try std.testing.expect(h.enabled);
    try std.testing.expectEqual(@as(u32, 15), h.interval_minutes);
}

// ── Cron config ─────────────────────────────────────────────────

test "CronConfig max_run_history default" {
    const c = CronConfig{};
    try std.testing.expectEqual(@as(u32, 50), c.max_run_history);
}

test "CronConfig max_run_history custom" {
    const c = CronConfig{ .max_run_history = 100 };
    try std.testing.expectEqual(@as(u32, 100), c.max_run_history);
}

// ── Memory config ───────────────────────────────────────────────

test "memory config defaults" {
    const m = MemoryConfig{};
    try std.testing.expectEqualStrings("sqlite", m.backend);
    try std.testing.expect(m.auto_save);
    try std.testing.expect(m.hygiene_enabled);
    try std.testing.expectEqual(@as(u32, 7), m.archive_after_days);
    try std.testing.expectEqual(@as(u32, 30), m.purge_after_days);
    try std.testing.expectEqual(@as(u32, 30), m.conversation_retention_days);
    try std.testing.expectEqualStrings("none", m.embedding_provider);
    try std.testing.expectEqualStrings("text-embedding-3-small", m.embedding_model);
    try std.testing.expectEqual(@as(u32, 1536), m.embedding_dimensions);
    try std.testing.expectEqual(@as(f64, 0.7), m.vector_weight);
    try std.testing.expectEqual(@as(f64, 0.3), m.keyword_weight);
    try std.testing.expectEqual(@as(u32, 10_000), m.embedding_cache_size);
    try std.testing.expectEqual(@as(u32, 512), m.chunk_max_tokens);
    try std.testing.expect(!m.response_cache_enabled);
    try std.testing.expectEqual(@as(u32, 60), m.response_cache_ttl_minutes);
    try std.testing.expectEqual(@as(u32, 5_000), m.response_cache_max_entries);
    try std.testing.expect(!m.snapshot_enabled);
    try std.testing.expect(!m.snapshot_on_hygiene);
    try std.testing.expect(m.auto_hydrate);
}

test "memory config snapshot settings" {
    const m = MemoryConfig{
        .snapshot_enabled = true,
        .snapshot_on_hygiene = true,
        .auto_hydrate = false,
    };
    try std.testing.expect(m.snapshot_enabled);
    try std.testing.expect(m.snapshot_on_hygiene);
    try std.testing.expect(!m.auto_hydrate);
}

test "memory config response cache settings" {
    const m = MemoryConfig{
        .response_cache_enabled = true,
        .response_cache_ttl_minutes = 120,
        .response_cache_max_entries = 10_000,
    };
    try std.testing.expect(m.response_cache_enabled);
    try std.testing.expectEqual(@as(u32, 120), m.response_cache_ttl_minutes);
    try std.testing.expectEqual(@as(u32, 10_000), m.response_cache_max_entries);
}

// ── Tunnel config ───────────────────────────────────────────────

test "tunnel config default none" {
    const t = TunnelConfig{};
    try std.testing.expectEqualStrings("none", t.provider);
}

test "tunnel config cloudflare" {
    const t = TunnelConfig{ .provider = "cloudflare" };
    try std.testing.expectEqualStrings("cloudflare", t.provider);
}

// ── Observability config ────────────────────────────────────────

test "observability config defaults" {
    const o = ObservabilityConfig{};
    try std.testing.expectEqualStrings("none", o.backend);
    try std.testing.expect(o.otel_endpoint == null);
    try std.testing.expect(o.otel_service_name == null);
}

test "observability config otel" {
    const o = ObservabilityConfig{
        .backend = "otel",
        .otel_endpoint = "http://localhost:4318",
        .otel_service_name = "nullclaw",
    };
    try std.testing.expectEqualStrings("otel", o.backend);
    try std.testing.expectEqualStrings("http://localhost:4318", o.otel_endpoint.?);
    try std.testing.expectEqualStrings("nullclaw", o.otel_service_name.?);
}

// ── Validation edge cases ───────────────────────────────────────

test "validation rejects negative temperature" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_temperature = -1.0,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(Config.ValidationError.TemperatureOutOfRange, cfg.validate());
}

test "validation accepts boundary temperatures" {
    const cfg_zero = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_temperature = 0.0,
        .allocator = std.testing.allocator,
    };
    try cfg_zero.validate();

    const cfg_two = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_temperature = 2.0,
        .allocator = std.testing.allocator,
    };
    try cfg_two.validate();
}

test "validation rejects excessive retries" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.provider_retries = 101;
    try std.testing.expectError(Config.ValidationError.InvalidRetryCount, cfg.validate());
}

test "validation rejects excessive backoff" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.provider_backoff_ms = 700_000;
    try std.testing.expectError(Config.ValidationError.InvalidBackoffMs, cfg.validate());
}

test "validation accepts max boundary retries" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.provider_retries = 100;
    try cfg.validate();
}

test "validation accepts max boundary backoff" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.reliability.provider_backoff_ms = 600_000;
    try cfg.validate();
}

// ── JSON parse: sub-config sections ─────────────────────────────

test "json parse observability section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"observability": {"backend": "otel", "otel_endpoint": "http://localhost:4318", "otel_service_name": "yc"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("otel", cfg.observability.backend);
    try std.testing.expectEqualStrings("http://localhost:4318", cfg.observability.otel_endpoint.?);
    try std.testing.expectEqualStrings("yc", cfg.observability.otel_service_name.?);
    allocator.free(cfg.observability.backend);
    allocator.free(cfg.observability.otel_endpoint.?);
    allocator.free(cfg.observability.otel_service_name.?);
}

test "json parse scheduler section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"scheduler": {"enabled": false, "max_tasks": 128, "max_concurrent": 8}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.scheduler.enabled);
    try std.testing.expectEqual(@as(u32, 128), cfg.scheduler.max_tasks);
    try std.testing.expectEqual(@as(u32, 8), cfg.scheduler.max_concurrent);
}

test "json parse agent section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agent": {"compact_context": true, "max_tool_iterations": 20, "max_history_messages": 80, "parallel_tools": true, "tool_dispatcher": "xml"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.agent.compact_context);
    try std.testing.expectEqual(@as(u32, 20), cfg.agent.max_tool_iterations);
    try std.testing.expectEqual(@as(u32, 80), cfg.agent.max_history_messages);
    try std.testing.expect(cfg.agent.parallel_tools);
    try std.testing.expectEqualStrings("xml", cfg.agent.tool_dispatcher);
    allocator.free(cfg.agent.tool_dispatcher);
}

test "json parse composio section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"composio": {"enabled": true, "api_key": "comp-key", "entity_id": "user1"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.composio.enabled);
    try std.testing.expectEqualStrings("comp-key", cfg.composio.api_key.?);
    try std.testing.expectEqualStrings("user1", cfg.composio.entity_id);
    allocator.free(cfg.composio.api_key.?);
    allocator.free(cfg.composio.entity_id);
}

test "json parse secrets section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"secrets": {"encrypt": false}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(!cfg.secrets.encrypt);
}

test "json parse identity section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"identity": {"format": "aieos", "aieos_path": "id.json"}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("aieos", cfg.identity.format);
    try std.testing.expectEqualStrings("id.json", cfg.identity.aieos_path.?);
    allocator.free(cfg.identity.format);
    allocator.free(cfg.identity.aieos_path.?);
}

test "json parse hardware section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"hardware": {"enabled": true, "transport": "serial", "serial_port": "/dev/ttyACM0", "baud_rate": 9600}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.hardware.enabled);
    try std.testing.expectEqual(HardwareTransport.serial, cfg.hardware.transport);
    try std.testing.expectEqualStrings("/dev/ttyACM0", cfg.hardware.serial_port.?);
    try std.testing.expectEqual(@as(u32, 9600), cfg.hardware.baud_rate);
    allocator.free(cfg.hardware.serial_port.?);
}

test "json parse security section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"security": {"sandbox": {"enabled": true, "backend": "firejail"}, "resources": {"max_memory_mb": 1024, "max_cpu_time_seconds": 120}, "audit": {"enabled": false, "log_path": "custom.log"}}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.security.sandbox.enabled.?);
    try std.testing.expectEqual(SandboxBackend.firejail, cfg.security.sandbox.backend);
    try std.testing.expectEqual(@as(u32, 1024), cfg.security.resources.max_memory_mb);
    try std.testing.expectEqual(@as(u64, 120), cfg.security.resources.max_cpu_time_seconds);
    try std.testing.expect(!cfg.security.audit.enabled);
    try std.testing.expectEqualStrings("custom.log", cfg.security.audit.log_path);
    allocator.free(cfg.security.audit.log_path);
}

test "json parse browser section" {
    const allocator = std.testing.allocator;
    const json =
        \\{"browser": {"enabled": true, "backend": "auto", "native_headless": false}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.browser.enabled);
    try std.testing.expectEqualStrings("auto", cfg.browser.backend);
    try std.testing.expect(!cfg.browser.native_headless);
    allocator.free(cfg.browser.backend);
}

test "json parse empty object uses defaults" {
    const allocator = std.testing.allocator;
    const json = "{}";
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("openrouter", cfg.default_provider);
    try std.testing.expectEqual(@as(f64, 0.7), cfg.default_temperature);
    try std.testing.expect(cfg.secrets.encrypt);
}

test "json parse integer temperature coerced to float" {
    const allocator = std.testing.allocator;
    const json =
        \\{"default_temperature": 1}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(f64, 1.0), cfg.default_temperature);
}

// ── Enum tests ──────────────────────────────────────────────────

test "autonomy level enum values" {
    try std.testing.expectEqualStrings("supervised", @tagName(AutonomyLevel.supervised));
    try std.testing.expectEqualStrings("read_only", @tagName(AutonomyLevel.read_only));
    try std.testing.expectEqualStrings("full", @tagName(AutonomyLevel.full));
}

test "hardware transport enum values" {
    try std.testing.expectEqualStrings("none", @tagName(HardwareTransport.none));
    try std.testing.expectEqualStrings("native", @tagName(HardwareTransport.native));
    try std.testing.expectEqualStrings("serial", @tagName(HardwareTransport.serial));
    try std.testing.expectEqualStrings("probe", @tagName(HardwareTransport.probe));
}

test "sandbox backend enum values" {
    try std.testing.expectEqualStrings("auto", @tagName(SandboxBackend.auto));
    try std.testing.expectEqualStrings("landlock", @tagName(SandboxBackend.landlock));
    try std.testing.expectEqualStrings("firejail", @tagName(SandboxBackend.firejail));
    try std.testing.expectEqualStrings("bubblewrap", @tagName(SandboxBackend.bubblewrap));
    try std.testing.expectEqualStrings("docker", @tagName(SandboxBackend.docker));
    try std.testing.expectEqualStrings("none", @tagName(SandboxBackend.none));
}

// ── New fields: autonomy allowed_commands / forbidden_paths ─────

test "autonomy config default empty command lists" {
    const a = AutonomyConfig{};
    try std.testing.expectEqual(@as(usize, 0), a.allowed_commands.len);
    try std.testing.expectEqual(@as(usize, 0), a.forbidden_paths.len);
}

test "autonomy config with allowed commands" {
    const a = AutonomyConfig{
        .allowed_commands = &.{ "ls", "cat", "git" },
    };
    try std.testing.expectEqual(@as(usize, 3), a.allowed_commands.len);
    try std.testing.expectEqualStrings("ls", a.allowed_commands[0]);
    try std.testing.expectEqualStrings("cat", a.allowed_commands[1]);
    try std.testing.expectEqualStrings("git", a.allowed_commands[2]);
}

test "autonomy config with forbidden paths" {
    const a = AutonomyConfig{
        .forbidden_paths = &.{ "/etc/passwd", "/root" },
    };
    try std.testing.expectEqual(@as(usize, 2), a.forbidden_paths.len);
    try std.testing.expectEqualStrings("/etc/passwd", a.forbidden_paths[0]);
    try std.testing.expectEqualStrings("/root", a.forbidden_paths[1]);
}

test "json parse autonomy allowed commands and forbidden paths" {
    const allocator = std.testing.allocator;
    const json =
        \\{"autonomy": {"allowed_commands": ["ls", "cat", "git status"], "forbidden_paths": ["/etc/shadow", "/root/.ssh"]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 3), cfg.autonomy.allowed_commands.len);
    try std.testing.expectEqualStrings("ls", cfg.autonomy.allowed_commands[0]);
    try std.testing.expectEqualStrings("cat", cfg.autonomy.allowed_commands[1]);
    try std.testing.expectEqualStrings("git status", cfg.autonomy.allowed_commands[2]);
    try std.testing.expectEqual(@as(usize, 2), cfg.autonomy.forbidden_paths.len);
    try std.testing.expectEqualStrings("/etc/shadow", cfg.autonomy.forbidden_paths[0]);
    try std.testing.expectEqualStrings("/root/.ssh", cfg.autonomy.forbidden_paths[1]);
    for (cfg.autonomy.allowed_commands) |cmd| allocator.free(cmd);
    allocator.free(cfg.autonomy.allowed_commands);
    for (cfg.autonomy.forbidden_paths) |p| allocator.free(p);
    allocator.free(cfg.autonomy.forbidden_paths);
}

// ── New fields: gateway paired_tokens ───────────────────────────

test "gateway config default empty paired tokens" {
    const g = GatewayConfig{};
    try std.testing.expectEqual(@as(usize, 0), g.paired_tokens.len);
}

test "gateway config with paired tokens" {
    const g = GatewayConfig{
        .paired_tokens = &.{ "tok-abc-123", "tok-def-456" },
    };
    try std.testing.expectEqual(@as(usize, 2), g.paired_tokens.len);
    try std.testing.expectEqualStrings("tok-abc-123", g.paired_tokens[0]);
    try std.testing.expectEqualStrings("tok-def-456", g.paired_tokens[1]);
}

test "json parse gateway paired tokens" {
    const allocator = std.testing.allocator;
    const json =
        \\{"gateway": {"paired_tokens": ["token-1", "token-2", "token-3"]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 3), cfg.gateway.paired_tokens.len);
    try std.testing.expectEqualStrings("token-1", cfg.gateway.paired_tokens[0]);
    try std.testing.expectEqualStrings("token-2", cfg.gateway.paired_tokens[1]);
    try std.testing.expectEqualStrings("token-3", cfg.gateway.paired_tokens[2]);
    for (cfg.gateway.paired_tokens) |t| allocator.free(t);
    allocator.free(cfg.gateway.paired_tokens);
}

// ── New fields: browser allowed_domains ─────────────────────────

test "browser config default empty allowed domains" {
    const b = BrowserConfig{};
    try std.testing.expectEqual(@as(usize, 0), b.allowed_domains.len);
}

test "browser config with allowed domains" {
    const b = BrowserConfig{
        .allowed_domains = &.{ "example.com", "docs.rs" },
    };
    try std.testing.expectEqual(@as(usize, 2), b.allowed_domains.len);
    try std.testing.expectEqualStrings("example.com", b.allowed_domains[0]);
    try std.testing.expectEqualStrings("docs.rs", b.allowed_domains[1]);
}

test "json parse browser allowed domains" {
    const allocator = std.testing.allocator;
    const json =
        \\{"browser": {"enabled": true, "allowed_domains": ["github.com", "docs.rs"]}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expect(cfg.browser.enabled);
    try std.testing.expectEqual(@as(usize, 2), cfg.browser.allowed_domains.len);
    try std.testing.expectEqualStrings("github.com", cfg.browser.allowed_domains[0]);
    try std.testing.expectEqualStrings("docs.rs", cfg.browser.allowed_domains[1]);
    for (cfg.browser.allowed_domains) |d| allocator.free(d);
    allocator.free(cfg.browser.allowed_domains);
}

// ── New fields: model_routes ────────────────────────────────────

test "config default empty model routes" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 0), cfg.model_routes.len);
}

test "json parse model routes" {
    const allocator = std.testing.allocator;
    const json =
        \\{"model_routes": [
        \\  {"hint": "reasoning", "provider": "openrouter", "model": "anthropic/claude-opus-4"},
        \\  {"hint": "fast", "provider": "groq", "model": "llama-3.3-70b", "api_key": "gsk_test"}
        \\]}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.model_routes.len);
    try std.testing.expectEqualStrings("reasoning", cfg.model_routes[0].hint);
    try std.testing.expectEqualStrings("openrouter", cfg.model_routes[0].provider);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4", cfg.model_routes[0].model);
    try std.testing.expect(cfg.model_routes[0].api_key == null);
    try std.testing.expectEqualStrings("fast", cfg.model_routes[1].hint);
    try std.testing.expectEqualStrings("groq", cfg.model_routes[1].provider);
    try std.testing.expectEqualStrings("llama-3.3-70b", cfg.model_routes[1].model);
    try std.testing.expectEqualStrings("gsk_test", cfg.model_routes[1].api_key.?);
    // Cleanup
    for (cfg.model_routes) |r| {
        allocator.free(r.hint);
        allocator.free(r.provider);
        allocator.free(r.model);
        if (r.api_key) |k| allocator.free(k);
    }
    allocator.free(cfg.model_routes);
}

test "json parse model routes skips invalid entries" {
    const allocator = std.testing.allocator;
    const json =
        \\{"model_routes": [
        \\  {"hint": "ok", "provider": "p", "model": "m"},
        \\  {"hint": "missing_model", "provider": "p"},
        \\  {"invalid": true}
        \\]}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.model_routes.len);
    try std.testing.expectEqualStrings("ok", cfg.model_routes[0].hint);
    allocator.free(cfg.model_routes[0].hint);
    allocator.free(cfg.model_routes[0].provider);
    allocator.free(cfg.model_routes[0].model);
    allocator.free(cfg.model_routes);
}

// ── New fields: agents ──────────────────────────────────────────

test "config default empty agents" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 0), cfg.agents.len);
}

test "named agent config constructible" {
    const n = NamedAgentConfig{
        .name = "researcher",
        .provider = "anthropic",
        .model = "claude-sonnet-4",
    };
    try std.testing.expectEqualStrings("researcher", n.name);
    try std.testing.expectEqualStrings("anthropic", n.provider);
    try std.testing.expectEqualStrings("claude-sonnet-4", n.model);
    try std.testing.expect(n.system_prompt == null);
    try std.testing.expect(n.api_key == null);
    try std.testing.expect(n.temperature == null);
    try std.testing.expectEqual(@as(u32, 3), n.max_depth);
}

test "json parse agents" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": [
        \\  {"name": "researcher", "provider": "anthropic", "model": "claude-sonnet-4", "system_prompt": "Research things", "max_depth": 5},
        \\  {"name": "coder", "provider": "openai", "model": "gpt-4o", "api_key": "sk-test", "temperature": 0.3}
        \\]}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.agents.len);
    try std.testing.expectEqualStrings("researcher", cfg.agents[0].name);
    try std.testing.expectEqualStrings("anthropic", cfg.agents[0].provider);
    try std.testing.expectEqualStrings("claude-sonnet-4", cfg.agents[0].model);
    try std.testing.expectEqualStrings("Research things", cfg.agents[0].system_prompt.?);
    try std.testing.expectEqual(@as(u32, 5), cfg.agents[0].max_depth);
    try std.testing.expect(cfg.agents[0].api_key == null);
    try std.testing.expectEqualStrings("coder", cfg.agents[1].name);
    try std.testing.expectEqualStrings("openai", cfg.agents[1].provider);
    try std.testing.expectEqualStrings("gpt-4o", cfg.agents[1].model);
    try std.testing.expectEqualStrings("sk-test", cfg.agents[1].api_key.?);
    try std.testing.expectEqual(@as(f64, 0.3), cfg.agents[1].temperature.?);
    try std.testing.expectEqual(@as(u32, 3), cfg.agents[1].max_depth);
    // Cleanup
    for (cfg.agents) |a| {
        allocator.free(a.name);
        allocator.free(a.provider);
        allocator.free(a.model);
        if (a.system_prompt) |sp| allocator.free(sp);
        if (a.api_key) |k| allocator.free(k);
    }
    allocator.free(cfg.agents);
}

test "json parse agents skips invalid entries" {
    const allocator = std.testing.allocator;
    const json =
        \\{"agents": [
        \\  {"name": "ok", "provider": "p", "model": "m"},
        \\  {"name": "missing_model", "provider": "p"},
        \\  42
        \\]}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.agents.len);
    try std.testing.expectEqualStrings("ok", cfg.agents[0].name);
    allocator.free(cfg.agents[0].name);
    allocator.free(cfg.agents[0].provider);
    allocator.free(cfg.agents[0].model);
    allocator.free(cfg.agents);
}

// ── Combined: all new fields in one JSON ────────────────────────

test "json parse all new fields together" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "model_routes": [{"hint": "fast", "provider": "groq", "model": "llama-3.3-70b"}],
        \\  "agents": [{"name": "helper", "provider": "anthropic", "model": "claude-haiku-3.5"}],
        \\  "autonomy": {"allowed_commands": ["ls"], "forbidden_paths": ["/root"]},
        \\  "gateway": {"paired_tokens": ["tok-1"]},
        \\  "browser": {"allowed_domains": ["example.com"]}
        \\}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.model_routes.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.agents.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.autonomy.allowed_commands.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.autonomy.forbidden_paths.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.gateway.paired_tokens.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.browser.allowed_domains.len);
    // Cleanup
    allocator.free(cfg.model_routes[0].hint);
    allocator.free(cfg.model_routes[0].provider);
    allocator.free(cfg.model_routes[0].model);
    allocator.free(cfg.model_routes);
    allocator.free(cfg.agents[0].name);
    allocator.free(cfg.agents[0].provider);
    allocator.free(cfg.agents[0].model);
    allocator.free(cfg.agents);
    allocator.free(cfg.autonomy.allowed_commands[0]);
    allocator.free(cfg.autonomy.allowed_commands);
    allocator.free(cfg.autonomy.forbidden_paths[0]);
    allocator.free(cfg.autonomy.forbidden_paths);
    allocator.free(cfg.gateway.paired_tokens[0]);
    allocator.free(cfg.gateway.paired_tokens);
    allocator.free(cfg.browser.allowed_domains[0]);
    allocator.free(cfg.browser.allowed_domains);
}

// ── Sprint 4: config gap fields ─────────────────────────────────

test "config api_url defaults to null" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(cfg.api_url == null);
}

test "json parse api_url" {
    const allocator = std.testing.allocator;
    const json =
        \\{"api_url": "http://10.0.0.1:11434"}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqualStrings("http://10.0.0.1:11434", cfg.api_url.?);
    allocator.free(cfg.api_url.?);
}

test "lark receive mode enum values" {
    try std.testing.expectEqualStrings("websocket", @tagName(LarkReceiveMode.websocket));
    try std.testing.expectEqualStrings("webhook", @tagName(LarkReceiveMode.webhook));
}

test "lark config defaults" {
    const lark = LarkConfig{ .app_id = "cli_123", .app_secret = "secret" };
    try std.testing.expectEqual(@as(usize, 0), lark.allowed_users.len);
    try std.testing.expectEqual(LarkReceiveMode.websocket, lark.receive_mode);
    try std.testing.expect(lark.port == null);
}

test "channel configs allowed_users defaults to empty" {
    const tg = TelegramConfig{ .bot_token = "tok" };
    try std.testing.expectEqual(@as(usize, 0), tg.allowed_users.len);

    const dc = DiscordConfig{ .bot_token = "tok" };
    try std.testing.expectEqual(@as(usize, 0), dc.allowed_users.len);
    try std.testing.expect(!dc.mention_only);

    const sl = SlackConfig{ .bot_token = "tok" };
    try std.testing.expectEqual(@as(usize, 0), sl.allowed_users.len);

    const mx = MatrixConfig{ .homeserver = "h", .access_token = "t", .room_id = "r" };
    try std.testing.expectEqual(@as(usize, 0), mx.allowed_users.len);

    const dt = DingTalkConfig{ .client_id = "id", .client_secret = "sec" };
    try std.testing.expectEqual(@as(usize, 0), dt.allowed_users.len);

    const irc = IrcConfig{ .server = "irc.example.com", .nickname = "bot" };
    try std.testing.expectEqual(@as(usize, 0), irc.allowed_users.len);
    try std.testing.expectEqual(@as(usize, 0), irc.channels.len);
}

test "whatsapp config allowed_numbers defaults to empty" {
    const wa = WhatsAppConfig{ .access_token = "t", .phone_number_id = "p", .verify_token = "v" };
    try std.testing.expectEqual(@as(usize, 0), wa.allowed_numbers.len);
}

test "reliability config api_keys defaults empty" {
    const r = ReliabilityConfig{};
    try std.testing.expectEqual(@as(usize, 0), r.api_keys.len);
    try std.testing.expectEqual(@as(usize, 0), r.model_fallbacks.len);
}

test "http request config allowed_domains defaults empty" {
    const h = HttpRequestConfig{};
    try std.testing.expectEqual(@as(usize, 0), h.allowed_domains.len);
}

test "autonomy level read_only exists" {
    try std.testing.expectEqualStrings("read_only", @tagName(AutonomyLevel.read_only));
    try std.testing.expectEqualStrings("supervised", @tagName(AutonomyLevel.supervised));
    try std.testing.expectEqualStrings("full", @tagName(AutonomyLevel.full));
}

test "sandbox config firejail_args defaults empty" {
    const s = SandboxConfig{};
    try std.testing.expectEqual(@as(usize, 0), s.firejail_args.len);
}

test "model fallback entry constructible" {
    const entry = ModelFallbackEntry{
        .model = "claude-opus-4",
        .fallbacks = &.{ "claude-sonnet-4", "gpt-4o" },
    };
    try std.testing.expectEqualStrings("claude-opus-4", entry.model);
    try std.testing.expectEqual(@as(usize, 2), entry.fallbacks.len);
}

// ── Environment variable override tests ─────────────────────────

test "applyEnvOverrides does not crash on default config" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    // Should not crash even when no NULLCLAW_* env vars are set
    cfg.applyEnvOverrides();
    // Default values should remain intact
    try std.testing.expectEqualStrings("openrouter", cfg.default_provider);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", cfg.default_model.?);
    try std.testing.expect(cfg.api_key == null);
    try std.testing.expect(cfg.api_url == null);
}

test "applyEnvOverrides preserves existing values when env vars absent" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
        .default_provider = "anthropic",
        .default_model = "claude-opus-4",
        .api_key = "sk-test-key-123",
        .default_temperature = 0.5,
    };
    cfg.applyEnvOverrides();
    // All values should remain the same since no env vars are set
    try std.testing.expectEqualStrings("anthropic", cfg.default_provider);
    try std.testing.expectEqualStrings("claude-opus-4", cfg.default_model.?);
    try std.testing.expectEqualStrings("sk-test-key-123", cfg.api_key.?);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.default_temperature);
}

test "applyEnvOverrides preserves workspace_dir when env var absent" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/custom/workspace",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    cfg.applyEnvOverrides();
    try std.testing.expectEqualStrings("/custom/workspace", cfg.workspace_dir);
}

test "applyEnvOverrides preserves gateway config when env vars absent" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    cfg.gateway.port = 9999;
    cfg.gateway.host = "0.0.0.0";
    cfg.gateway.allow_public_bind = true;
    cfg.applyEnvOverrides();
    try std.testing.expectEqual(@as(u16, 9999), cfg.gateway.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.gateway.host);
    try std.testing.expect(cfg.gateway.allow_public_bind);
}

test "applyEnvOverrides preserves api_url when NULLCLAW_BASE_URL absent" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
        .api_url = "http://localhost:11434",
    };
    cfg.applyEnvOverrides();
    try std.testing.expectEqualStrings("http://localhost:11434", cfg.api_url.?);
}

test "applyEnvOverrides preserves null api_url when NULLCLAW_BASE_URL absent" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    cfg.applyEnvOverrides();
    try std.testing.expect(cfg.api_url == null);
}

test "applyEnvOverrides is idempotent on default config" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    // Apply overrides multiple times — should not change defaults
    cfg.applyEnvOverrides();
    cfg.applyEnvOverrides();
    cfg.applyEnvOverrides();
    try std.testing.expectEqualStrings("openrouter", cfg.default_provider);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", cfg.default_model.?);
    try std.testing.expect(cfg.api_key == null);
    try std.testing.expectEqual(@as(f64, 0.7), cfg.default_temperature);
}

test "syncFlatFields copies nested values to flat aliases" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    cfg.default_temperature = 1.2;
    cfg.memory.backend = "json";
    cfg.memory.auto_save = false;
    cfg.heartbeat.enabled = true;
    cfg.heartbeat.interval_minutes = 15;
    cfg.gateway.host = "0.0.0.0";
    cfg.gateway.port = 4000;
    cfg.autonomy.workspace_only = false;
    cfg.autonomy.max_actions_per_hour = 99;
    cfg.syncFlatFields();
    try std.testing.expectEqual(@as(f64, 1.2), cfg.temperature);
    try std.testing.expectEqualStrings("json", cfg.memory_backend);
    try std.testing.expect(!cfg.memory_auto_save);
    try std.testing.expect(cfg.heartbeat_enabled);
    try std.testing.expectEqual(@as(u32, 15), cfg.heartbeat_interval_minutes);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.gateway_host);
    try std.testing.expectEqual(@as(u16, 4000), cfg.gateway_port);
    try std.testing.expect(!cfg.workspace_only);
    try std.testing.expectEqual(@as(u32, 99), cfg.max_actions_per_hour);
}

// ── MCP config tests ────────────────────────────────────────────

test "config default empty mcp_servers" {
    const cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 0), cfg.mcp_servers.len);
}

test "json parse mcp_servers" {
    const allocator = std.testing.allocator;
    const json =
        \\{"mcp_servers": {
        \\  "filesystem": {
        \\    "command": "npx",
        \\    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        \\  },
        \\  "git": {
        \\    "command": "mcp-server-git"
        \\  }
        \\}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 2), cfg.mcp_servers.len);
    // Find filesystem entry (order may vary due to hash map)
    var found_fs = false;
    var found_git = false;
    for (cfg.mcp_servers) |s| {
        if (std.mem.eql(u8, s.name, "filesystem")) {
            found_fs = true;
            try std.testing.expectEqualStrings("npx", s.command);
            try std.testing.expectEqual(@as(usize, 3), s.args.len);
            try std.testing.expectEqualStrings("-y", s.args[0]);
        }
        if (std.mem.eql(u8, s.name, "git")) {
            found_git = true;
            try std.testing.expectEqualStrings("mcp-server-git", s.command);
            try std.testing.expectEqual(@as(usize, 0), s.args.len);
        }
    }
    try std.testing.expect(found_fs);
    try std.testing.expect(found_git);
    // Cleanup
    for (cfg.mcp_servers) |s| {
        allocator.free(s.name);
        allocator.free(s.command);
        for (s.args) |a| allocator.free(a);
        allocator.free(s.args);
    }
    allocator.free(cfg.mcp_servers);
}

test "json parse mcp_servers with env" {
    const allocator = std.testing.allocator;
    const json =
        \\{"mcp_servers": {
        \\  "myserver": {
        \\    "command": "/usr/bin/server",
        \\    "args": ["--verbose"],
        \\    "env": {"NODE_ENV": "production", "DEBUG": "true"}
        \\  }
        \\}}
    ;
    var cfg = Config{ .workspace_dir = "/tmp/yc", .config_path = "/tmp/yc/config.json", .allocator = allocator };
    try cfg.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    const s = cfg.mcp_servers[0];
    try std.testing.expectEqualStrings("myserver", s.name);
    try std.testing.expectEqualStrings("/usr/bin/server", s.command);
    try std.testing.expectEqual(@as(usize, 1), s.args.len);
    try std.testing.expectEqual(@as(usize, 2), s.env.len);
    // Find env entries (order may vary)
    var found_node = false;
    var found_debug = false;
    for (s.env) |e| {
        if (std.mem.eql(u8, e.key, "NODE_ENV")) {
            found_node = true;
            try std.testing.expectEqualStrings("production", e.value);
        }
        if (std.mem.eql(u8, e.key, "DEBUG")) {
            found_debug = true;
            try std.testing.expectEqualStrings("true", e.value);
        }
    }
    try std.testing.expect(found_node);
    try std.testing.expect(found_debug);
    // Cleanup
    allocator.free(s.name);
    allocator.free(s.command);
    for (s.args) |a| allocator.free(a);
    allocator.free(s.args);
    for (s.env) |e| {
        allocator.free(e.key);
        allocator.free(e.value);
    }
    allocator.free(s.env);
    allocator.free(cfg.mcp_servers);
}
