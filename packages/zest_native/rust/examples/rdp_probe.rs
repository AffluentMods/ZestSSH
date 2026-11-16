//! RDP probe (4.0, developer builds only): connects headless to an RDP server through IronRDP (rustls with ring),
//! logs in, waits for the first screen update and prints what it got. With ZS_RDP_OUT, also
//! writes the picture as a binary PPM (P6) file.
//!
//! The servers: tool/remote_screens_test_servers.sh (xrdp in WSL, TCP 13389, TLS only). From the
//! app's checkout, in Git Bash on Windows:
//!
//!   wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh start
//!   export ZS_RDP_HOST=$(wsl -d Ubuntu hostname -I | awk '{print $1}')
//!   export ZS_USER=alex
//!   export ZS_PASSWORD="$(wsl -d Ubuntu -u root sed -n 's/^ZS_PASSWORD=//p' /etc/zestscreens/env)"
//!   cd packages/zest_native/rust
//!   cargo run --locked --release --features rdp,probes --example rdp_probe
//!
//! Optional: ZS_RDP_PORT (13389), ZS_RDP_SERVER_NAME (the name the certificate is checked
//! against), ZS_RDP_DOMAIN, ZS_RDP_CERT_SHA256 (pin: any other certificate is refused),
//! ZS_RDP_SIZE (1280x800), ZS_RDP_TIMEOUT_MS (20000), ZS_RDP_SETTLE_MS (1500), ZS_RDP_OUT,
//! ZS_RDP_NLA ("required" as a session asks by default, "without" as a host that signs in without
//! NLA: no password is sent then; not set: whatever the server picks).
//! Exit status 0 when a screen update came, 1 when not, 2 for a missing setting.

#![allow(dead_code, unused_imports)]

#[path = "../src/rdp/mod.rs"]
mod rdp;

use std::env;
use std::io::Write as _;
use std::process::ExitCode;

fn setting(name: &str) -> Option<String> {
    env::var(name).ok().filter(|v| !v.is_empty())
}

fn main() -> ExitCode {
    let (Some(host), Some(username), Some(password)) =
        (setting("ZS_RDP_HOST"), setting("ZS_USER"), setting("ZS_PASSWORD"))
    else {
        eprintln!("set ZS_RDP_HOST, ZS_USER and ZS_PASSWORD (see the header of examples/rdp_probe.rs)");
        return ExitCode::from(2);
    };
    let (width, height) = setting("ZS_RDP_SIZE")
        .and_then(|s| {
            let (w, h) = s.split_once('x')?;
            Some((w.parse().ok()?, h.parse().ok()?))
        })
        .unwrap_or((1280, 800));
    let request = rdp::ProbeRequest {
        host,
        port: setting("ZS_RDP_PORT").and_then(|p| p.parse().ok()).unwrap_or(13389),
        server_name: setting("ZS_RDP_SERVER_NAME"),
        username,
        password,
        domain: setting("ZS_RDP_DOMAIN"),
        width,
        height,
        cert_sha256: setting("ZS_RDP_CERT_SHA256"),
        timeout_ms: setting("ZS_RDP_TIMEOUT_MS").and_then(|t| t.parse().ok()).unwrap_or(20_000),
        settle_ms: setting("ZS_RDP_SETTLE_MS").and_then(|t| t.parse().ok()).unwrap_or(1_500),
        nla: setting("ZS_RDP_NLA"),
    };
    println!("connecting to {}:{} as {}", request.host, request.port, request.username);
    match rdp::probe(&request) {
        Ok(report) => {
            println!("TLS: {} {}", report.tls_version.as_deref().unwrap_or("?"), report.tls_cipher.as_deref().unwrap_or("?"));
            println!("certificate SHA-256: {} ({})", report.cert_sha256, report.cert_check);
            println!("NLA (CredSSP): {}", if report.nla { "yes" } else { "no, the server did not ask" });
            println!("desktop: {} x {}", report.desktop_width, report.desktop_height);
            let [l, t, r, b] = report.first_update;
            println!(
                "first update: {} x {} at ({l}, {t}), {} ms after start",
                r - l + 1,
                b - t + 1,
                report.first_update_ms
            );
            println!(
                "times (ms from start): TCP {}, TLS {}, logged in {}, first update {}",
                report.tcp_ms, report.tls_ms, report.connected_ms, report.first_update_ms
            );
            let total = u64::from(report.desktop_width) * u64::from(report.desktop_height);
            println!(
                "after {} ms more: {} updates, {} bytes received, {} of {} pixels painted",
                request.settle_ms, report.updates, report.bytes_received, report.painted_pixels, total
            );
            if let Some(out) = setting("ZS_RDP_OUT") {
                match write_ppm(&out, report.desktop_width, report.desktop_height, &report.rgba) {
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
