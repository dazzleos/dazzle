//! Wayland for Stardust: the wire protocol, the interfaces Stardust uses,
//! and a small client library. The server side lives in stardust-shell.

pub const wire = @import("wire.zig");
pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");

test {
    _ = wire;
    _ = protocol;
    _ = client;
}
