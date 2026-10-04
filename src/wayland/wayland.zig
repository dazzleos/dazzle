//! Wayland for Dazzle: the wire protocol, the interfaces Dazzle uses,
//! and a small client library. The server side lives in dazzle-shell.

pub const wire = @import("wire.zig");
pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");

test {
    _ = wire;
    _ = protocol;
    _ = client;
}
