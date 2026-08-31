//! Header redaction applied before anything reaches disk.

const std = @import("std");

/// Replacement value written in place of a secret.
pub const redacted = "<REDACTED>";

const secret_headers = [_][]const u8{
    "authorization",
    "x-api-key",
    "api-key",
    "openai-organization",
    "openai-project",
    "cookie",
};

/// Whether a header carries a credential. Comparison is case-insensitive
/// because HTTP header names are, and SDKs disagree on casing.
pub fn isSecret(name: []const u8) bool {
    for (secret_headers) |h| {
        if (std.ascii.eqlIgnoreCase(name, h)) return true;
    }
    return false;
}

/// The value to store for a header: either the original, or the placeholder.
pub fn value(name: []const u8, original: []const u8) []const u8 {
    return if (isSecret(name)) redacted else original;
}

const testing = std.testing;

test "api key headers are secret regardless of case" {
    try testing.expect(isSecret("X-Api-Key"));
    try testing.expect(isSecret("AUTHORIZATION"));
    try testing.expect(isSecret("api-key"));
    try testing.expect(isSecret("Cookie"));
}

test "ordinary headers are not secret" {
    try testing.expect(!isSecret("content-type"));
    try testing.expect(!isSecret("anthropic-version"));
}

test "secret values are replaced and ordinary ones are not" {
    try testing.expectEqualStrings(redacted, value("x-api-key", "sk-ant-secret"));
    try testing.expectEqualStrings("application/json", value("content-type", "application/json"));
}
