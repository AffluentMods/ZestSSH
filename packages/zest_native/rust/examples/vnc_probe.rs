//! VNC probe (4.0): connects headless to a VNC server through our engine (src/vnc/engine, the
//! fork of vnc-rs), authenticates (None, VNC auth, Apple Remote Desktop, or VeNCrypt X509 with a
//! pinned certificate), waits for the first framebuffer update and prints what it got. With
//! ZS_VNC_OUT, also writes the picture as a binary PPM (P6) file.
//!
//! The servers: tool/remote_screens_test_servers.sh (TigerVNC Xvnc in WSL on TCP 15931 and the
//! Unix socket /run/zestscreens/vnc.sock, VNC auth; with `start-tls`, also an Xvnc with VeNCrypt
//! X509Vnc and X509Plain on TCP 15932). From the app's checkout, in Git Bash:
//!
//!   MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh start
//!   export ZS_VNC_HOST=$(wsl -d Ubuntu hostname -I | awk '{print $1}')
//!   export ZS_VNC_PASSWORD="$(MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u root sed -n 's/^ZS_VNC_PASSWORD=//p' /etc/zestscreens/env | tr -d '\r')"
//!   cd packages/zest_native/rust
//!   cargo run --locked --release --features vnc,probes --example vnc_probe
//!
//! The Unix socket through SSH: forward a local port to it (`ssh -p 2240 -L
//! <port>:/run/zestscreens/vnc.sock alex@<wsl-ip>`, a direct-streamlocal channel) and point
//! ZS_VNC_HOST and ZS_VNC_PORT at the forward. On macOS and Linux, ZS_VNC_UNIX connects to a
//! socket directly.
//!
//! Optional: ZS_VNC_PORT (15931), ZS_VNC_UNIX, ZS_VNC_USER (Apple Remote Desktop, X509Plain),
//! ZS_VNC_TLS_PIN (the certificate's SHA-256 in hex; without it a VeNCrypt server's certificate is
//! printed and the probe stops, as the app will ask the person), ZS_VNC_REQUIRE_TLS=1,
//! ZS_VNC_ENCODINGS (comma separated, in order of preference: Tight, ZRLE, TRLE, Hextile, Zlib,
//! RRE, CopyRect, Raw, the pseudo encodings Cursor, ExtendedDesktopSize, DesktopSize, LastRect,
//! QemuExtendedKeyEvent, ExtendedClipboard, and JpegQuality0 to 9, CompressionLevel0 to 9; the
//! engine's defaults otherwise), ZS_VNC_CLIPBOARD (text put on the server's clipboard),
//! ZS_VNC_TIMEOUT_MS (20000), ZS_VNC_SETTLE_MS (1500), ZS_VNC_OUT. Exit status 0 when a screen
//! update came, 1 when not, 2 for a missing setting.

#![allow(dead_code, unused_imports)]

#[path = "../src/secret.rs"]
mod secret;
#[path = "../src/vnc/mod.rs"]
mod vnc;

use std::env;
use std::io::Write as _;
use std::process::ExitCode;

fn setting(name: &str) -> Option<String> {
    env::var(name).ok().filter(|v| !v.is_empty())
}

fn main() -> ExitCode {
    let unix_path = setting("ZS_VNC_UNIX");
    let host = setting("ZS_VNC_HOST");
    if host.is_none() && unix_path.is_none() {
        eprintln!("set ZS_VNC_HOST (or ZS_VNC_UNIX), and ZS_VNC_PASSWORD when the server asks for one");
        return ExitCode::from(2);
    }
    let request = vnc::ProbeRequest {
        host: host.unwrap_or_default(),
        port: setting("ZS_VNC_PORT").and_then(|p| p.parse().ok()).unwrap_or(15931),
        unix_path,
        username: setting("ZS_VNC_USER"),
        password: setting("ZS_VNC_PASSWORD"),
        tls_pin: setting("ZS_VNC_TLS_PIN"),
        require_tls: setting("ZS_VNC_REQUIRE_TLS").is_some_and(|v| v == "1"),
        encodings: setting("ZS_VNC_ENCODINGS").map(|s| s.split(',').map(|e| e.trim().to_string()).collect()),
        clipboard: setting("ZS_VNC_CLIPBOARD"),
        timeout_ms: setting("ZS_VNC_TIMEOUT_MS").and_then(|t| t.parse().ok()).unwrap_or(20_000),
        settle_ms: setting("ZS_VNC_SETTLE_MS").and_then(|t| t.parse().ok()).unwrap_or(1_500),
    };
    match &request.unix_path {
        Some(p) => println!("connecting to {p}"),
        None => println!("connecting to {}:{}", request.host, request.port),
    }
    match vnc::probe(&request) {
        Ok(r) => {
            println!(
                "server: {}, security types offered {:?}, used {}",
                r.rfb_version, r.security_types_offered, r.security_type
            );
            if let Some([subtype, protocol, suite, sha]) = &r.tls {
                println!("VeNCrypt {subtype}: {protocol}, {suite}, certificate SHA-256 {sha} (pinned)");
            }
            println!("desktop: \"{}\", {} x {}", r.desktop_name, r.desktop_width, r.desktop_height);
            println!("encodings offered: {}", r.encodings_offered.join(", "));
            for (i, list) in r.update_encodings.iter().take(4).enumerate() {
                println!("update {}'s rectangles: {}", i + 1, list.join(", "));
            }
            println!(
                "{} updates; rectangles by encoding: {}; layout-only updates before the first pixels: {}",
                r.updates,
                r.rectangles_by_encoding.iter().map(|(k, v)| format!("{k} {v}")).collect::<Vec<_>>().join(", "),
                r.layout_only_updates_first
            );
            let [x, y, w, h] = r.first_update;
            println!("first rectangle drawn: {w} x {h} at ({x}, {y})");
            println!(
                "times (ms from start): socket open {}, RFB handshake and auth done {}, first rectangle {}, whole screen {}",
                r.connect_ms,
                r.connected_ms,
                r.first_update_ms,
                r.full_screen_ms.map_or("not within the settle time".to_string(), |t| t.to_string())
            );
            let total = u64::from(r.desktop_width) * u64::from(r.desktop_height);
            println!(
                "after {} ms more: {} pixel rectangles, {} copies, {} cursors, {} other events; QEMU key events {}; {} bytes received, {} sent; {} of {} pixels painted",
                request.settle_ms,
                r.pixel_rectangles,
                r.copies,
                r.cursors,
                r.other_events,
                if r.qemu_key_events { "confirmed" } else { "not confirmed" },
                r.bytes_received,
                r.bytes_sent,
                r.painted_pixels,
                total
            );
            for text in &r.clipboard_received {
                println!("server clipboard: {text:?}");
            }
            if let Some(out) = setting("ZS_VNC_OUT") {
                match write_ppm(&out, r.desktop_width, r.desktop_height, &r.rgba) {
                    Ok(()) => println!("picture written to {out}"),
                    Err(e) => eprintln!("could not write {out}: {e}"),
                }
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("probe failed: {error}");
            ExitCode::from(1)
        }
    }
}

fn write_ppm(path: &str, width: u16, height: u16, rgba: &[u8]) -> std::io::Result<()> {
    let mut file = std::io::BufWriter::new(std::fs::File::create(path)?);
    write!(file, "P6\n{width} {height}\n255\n")?;
    for pixel in rgba.chunks_exact(4) {
        file.write_all(&pixel[..3])?;
    }
    file.flush()
}
