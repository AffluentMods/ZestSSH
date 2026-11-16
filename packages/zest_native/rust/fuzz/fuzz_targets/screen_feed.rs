//! A whole session through the bridge, as Dart drives it (harness::ffi::session): the request
//! the first byte picks (VNC with or without a password, user, TLS required, continuous updates,
//! tiles, encodings; or RDP), the input the second byte picks, the rest as the channel's bytes.
//! With the first byte's top bit a complete VNC handshake goes first.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let [pick, input, rest @ ..] = data else { return };
    let request = if pick & 0b11 == 3 {
        let graphics = ["gfx", "remotefx", "bitmap", "gfx"][usize::from(pick >> 2 & 3)];
        serde_json::json!({
            "kind": "rdp",
            "username": "alex",
            "password": "secret",
            "server_name": "rdp.invalid",
            "width": 800,
            "height": 600,
            "rdp_graphics": graphics,
            "rdp_h264": "off",
            "tls_pin": if pick & 16 != 0 { Some("07".repeat(32)) } else { None },
        })
    } else {
        let tile = [256, 0, 16, 64][usize::from(pick >> 2 & 3)];
        let mut r = serde_json::json!({
            "kind": "vnc",
            "tile_size": tile,
            "require_tls": pick & 16 != 0,
            "continuous_updates": pick & 32 == 0,
            "shared": pick & 64 == 0,
        });
        if pick & 1 != 0 {
            r["password"] = "secret".into();
        }
        if pick & 2 != 0 {
            r["username"] = "alex".into();
            r["encodings"] = serde_json::json!(["Tight", "ZRLE", "TRLE", "Hextile", "Zlib", "RRE", "CopyRect",
                "JpegQuality5", "CompressionLevel1", "Cursor", "DesktopSize", "ExtendedDesktopSize", "LastRect",
                "QemuExtendedKeyEvent", "ExtendedClipboard"]);
        }
        r
    };
    let mut server = Vec::new();
    if pick & 128 != 0 && pick & 0b11 != 3 {
        server = harness::handshake(320, 200);
    }
    server.extend_from_slice(rest);
    let _ = harness::ffi::session(request.to_string().as_bytes(), &server, *input);
});
