const std = @import("std");

pub const Code = enum {
    internal,
    config_not_found,
    config_invalid,
    socket_bind_failed,
    socket_in_use,
    socket_permission_denied,
    internal_auth_failed,
    service_init_failed,
    shutdown_timeout,
    health_not_ready,
    not_found,
    unauthorized,
    invalid_credentials,
    forbidden,
    csrf_invalid,
    bad_request,
    conflict,
    service_not_found,
    service_not_restartable,
    service_operation_in_progress,

    pub fn httpStatus(self: Code) u16 {
        return switch (self) {
            .internal => 500,
            .config_not_found, .not_found, .service_not_found => 404,
            .config_invalid => 422,
            .bad_request => 400,
            .socket_bind_failed, .socket_in_use, .socket_permission_denied => 503,
            .internal_auth_failed, .unauthorized, .invalid_credentials => 401,
            .forbidden, .csrf_invalid, .service_not_restartable => 403,
            .conflict, .service_operation_in_progress => 409,
            .service_init_failed, .shutdown_timeout, .health_not_ready => 503,
        };
    }

    pub fn title(self: Code) []const u8 {
        return switch (self) {
            .internal => "Internal error",
            .config_not_found => "Configuration file not found",
            .config_invalid => "Invalid configuration",
            .socket_bind_failed => "Cannot bind service socket",
            .socket_in_use => "Service socket already in use",
            .socket_permission_denied => "Service socket permission denied",
            .internal_auth_failed => "Internal authentication failed",
            .service_init_failed => "Service initialization failed",
            .shutdown_timeout => "Graceful shutdown timed out",
            .health_not_ready => "Service is not ready",
            .not_found => "Not found",
            .unauthorized => "Authentication required",
            .invalid_credentials => "Invalid credentials",
            .forbidden => "Permission denied",
            .csrf_invalid => "CSRF validation failed",
            .bad_request => "Invalid request",
            .conflict => "Resource conflict",
            .service_not_found => "Service not found",
            .service_not_restartable => "Service cannot be restarted",
            .service_operation_in_progress => "Service operation already in progress",
        };
    }

    pub fn fix(self: Code) []const u8 {
        return switch (self) {
            .internal => "Check the service log and retry",
            .config_not_found => "Run `doctbase init` or pass --config <path>",
            .config_invalid => "Run `doctbase config validate` and fix the reported key",
            .socket_bind_failed => "Check the run directory owner/mode and retry",
            .socket_in_use => "Stop the running service or choose a different socket",
            .socket_permission_denied => "Verify the socket owner/group and mode 0660",
            .internal_auth_failed => "Provide a valid internal bearer token",
            .service_init_failed => "Check dependency readiness and the service log",
            .shutdown_timeout => "Increase the shutdown deadline or inspect hung requests",
            .health_not_ready => "Check /readyz dependency checks",
            .not_found => "Check the request path",
            .unauthorized => "Log in or provide a valid session token",
            .invalid_credentials => "Check the email and password",
            .forbidden => "Action requires admin or owner role",
            .csrf_invalid => "Reload the dashboard and retry with a valid CSRF token",
            .bad_request => "Send a valid JSON request body",
            .conflict => "Retry when conflicting operation finishes",
            .service_not_found => "Specify a valid service name from `doctbase status`",
            .service_not_restartable => "Infrastructure services must be restarted manually via CLI",
            .service_operation_in_progress => "Wait for the current operation to finish",
        };
    }

    pub fn codeString(self: Code) []const u8 {
        return switch (self) {
            .internal => "INTERNAL",
            .config_not_found => "CONFIG_NOT_FOUND",
            .config_invalid => "CONFIG_INVALID",
            .socket_bind_failed => "SOCKET_BIND_FAILED",
            .socket_in_use => "SOCKET_IN_USE",
            .socket_permission_denied => "SOCKET_PERMISSION_DENIED",
            .internal_auth_failed => "INTERNAL_AUTH_FAILED",
            .service_init_failed => "SERVICE_INIT_FAILED",
            .shutdown_timeout => "SHUTDOWN_TIMEOUT",
            .health_not_ready => "HEALTH_NOT_READY",
            .not_found => "NOT_FOUND",
            .unauthorized => "UNAUTHORIZED",
            .invalid_credentials => "INVALID_CREDENTIALS",
            .forbidden => "FORBIDDEN",
            .csrf_invalid => "CSRF_INVALID",
            .bad_request => "BAD_REQUEST",
            .conflict => "CONFLICT",
            .service_not_found => "SERVICE_NOT_FOUND",
            .service_not_restartable => "SERVICE_NOT_RESTARTABLE",
            .service_operation_in_progress => "SERVICE_OPERATION_IN_PROGRESS",
        };
    }

    pub fn docsUrl(self: Code, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "https://doctbase.dev/errors/{s}", .{self.codeString()});
    }
};

pub fn fromError(err: anyerror) Code {
    return switch (err) {
        error.ConfigNotFound => .config_not_found,
        error.ConfigInvalid => .config_invalid,
        error.SocketBindFailed => .socket_bind_failed,
        error.SocketInUse => .socket_in_use,
        error.SocketPermissionDenied => .socket_permission_denied,
        error.InternalAuthFailed => .internal_auth_failed,
        error.InvalidCredentials => .invalid_credentials,
        error.CsrfInvalid => .csrf_invalid,
        error.ServiceInitFailed => .service_init_failed,
        error.ShutdownTimeout => .shutdown_timeout,
        error.HealthNotReady => .health_not_ready,
        error.FileNotFound => .not_found,
        else => .internal,
    };
}

test "error codes have stable HTTP status and docs URL" {
    try std.testing.expectEqual(@as(u16, 401), Code.internal_auth_failed.httpStatus());
    try std.testing.expectEqual(@as(u16, 503), Code.socket_in_use.httpStatus());
    try std.testing.expectEqualStrings("INTERNAL_AUTH_FAILED", Code.internal_auth_failed.codeString());

    var buffer: [128]u8 = undefined;
    const url = try Code.not_found.docsUrl(&buffer);
    try std.testing.expectEqualStrings("https://doctbase.dev/errors/NOT_FOUND", url);
}
