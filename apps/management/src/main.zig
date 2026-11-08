const std = @import("std");
const runtime = @import("runtime");
const lifecycle = @import("service_lifecycle");
const app_mod = @import("management_app");

pub fn main(init: std.process.Init) !void {
    const environment = init.environ_map;
    const mode = environment.get("DOCTBASE_MODE") orelse "dev";

    var compose: lifecycle.compose.ComposeDriver = undefined;
    var systemd: lifecycle.systemd.SystemdDriver = undefined;
    var driver: lifecycle.driver.LifecycleDriver = undefined;
    if (std.mem.eql(u8, mode, "docker")) {
        compose = lifecycle.compose.ComposeDriver.init(init.gpa, init.io, .{
            .docker_path = environment.get("DOCTBASE_DOCKER_PATH") orelse "docker",
            .compose_file = environment.get("DOCTBASE_COMPOSE_FILE"),
        });
        driver = compose.driver();
    } else {
        systemd = lifecycle.systemd.SystemdDriver.init(init.gpa, init.io, .{
            .systemctl_path = environment.get("DOCTBASE_SYSTEMCTL_PATH") orelse "systemctl",
        });
        driver = systemd.driver();
    }
    defer driver.deinit();

    var app = try app_mod.ManagementApp.init(init.gpa, init.io, .{
        .environ = environment,
        .driver = driver,
        .admin_path = environment.get("DOCTBASE_ADMIN_DB") orelse "/var/lib/doctbase/control/admin.json",
        .cookie_secure = !std.mem.eql(u8, environment.get("DOCTBASE_INSECURE_COOKIES") orelse "0", "1"),
    });
    defer app.deinit();

    try runtime.runServiceWithFallback(init, "management", app.handler());
}
