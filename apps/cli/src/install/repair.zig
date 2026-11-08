//! Repair/reinstall policy for an existing native installation.
//!
//! Repair is intentionally the install transaction with `repair = true`, not a
//! second mutating path: every install step is already idempotent, adopts
//! existing users/secrets/cluster/config and only writes generated artifacts
//! when they differ. Running that sequence again without deleting data is the
//! safest way to recover a partially failed install or refresh binaries/units.
//!
//! Differences from install:
//!
//! - the state file must exist (otherwise there is nothing to repair);
//! - domain/email default to the installed instance state so the generated
//!   Caddyfile and configuration keep pointing at the same host;
//! - preflight treats 80/443 as Doctbase-managed while our Caddy unit is active;
//! - rollback still removes only resources created by *this* repair run, never
//!   data that existed before it.
//!
//! `repair` never purges, never rewrites an existing `/etc/doctbase/doctbase.toml`
//! and never deletes projects, databases or backup archives.

const std = @import("std");
const install = @import("install_orchestrator");
const state = @import("install_state");

pub const Error = error{
    /// No `/var/lib/doctbase/state.json`; use `doctbase install` for a fresh host.
    NotInstalled,
};

/// Keeps the parsed state alive because `options.domain`/`options.email` point
/// into it and the install summary borrows the same slices. The CLI must keep
/// this context alive until it has printed the outcome.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: std.json.Parsed(state.State),
    options: install.Options,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        base: install.Options,
    ) !Context {
        const parsed = (try state.load(allocator, io, base.state_path)) orelse return Error.NotInstalled;

        var options = base;
        options.repair = true;
        if (options.domain.len == 0) options.domain = parsed.value.domain;
        if (options.email.len == 0) options.email = parsed.value.email;

        return .{
            .allocator = allocator,
            .io = io,
            .parsed = parsed,
            .options = options,
        };
    }

    pub fn deinit(self: *Context) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Context, executor: install.Executor) !install.Outcome {
        return install.run(self.io, self.allocator, &self.options, executor);
    }
};
