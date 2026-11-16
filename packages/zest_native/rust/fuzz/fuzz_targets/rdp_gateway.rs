//! The RD Gateway's side (screen::rdp_gateway): what a gateway can send, past TLS.
//!
//! The first byte picks:
//!
//!   even: the parsers alone, on the rest: an HTTP answer's head, WebSocket frames read in a
//!         loop (as the reader does, pieces kept between them), each whole message as an MS-TSGU
//!         packet read by every reader of a packet's body, and the sign-in offers and challenge
//!         of a head's WWW-Authenticate lines;
//!   odd:  the whole way (the upgrade with its NTLM sign-in, sspi reading the gateway's
//!         challenge, the tunnel, the channel, the session's bytes carried), the rest being all
//!         the gateway sends, then its end. What the client sends is read and dropped.
//!
//! Time is tokio's paused clock: a gateway that stops answering costs no wall time.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use zest_native::screen::GatewayRequest;
use zest_native::screen::fuzzing::{
    GatewayFrame, gateway_challenge, gateway_frame, gateway_head, gateway_packet, gateway_scheme, gateway_through, read_channel_response,
    read_data, read_handshake_response, read_tunnel_auth_response, read_tunnel_response,
};

fn parsers(data: &[u8]) {
    let mut frames = data;
    if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
        if let Ok(head) = gateway_head(&data[..end]) {
            if let Some(scheme) = gateway_scheme(&head.authenticate) {
                let _ = gateway_challenge(&head.authenticate, scheme);
            }
        }
        // The frames after the head, as after a 101.
        frames = &data[end + 4..];
    }
    let mut buf = frames.to_vec();
    let mut pieces = None;
    while let Ok(Some(frame)) = gateway_frame(&mut buf, &mut pieces) {
        if let GatewayFrame::Message(m) = frame {
            if let Ok((_, body)) = gateway_packet(&m) {
                let _ = read_handshake_response(body);
                let _ = read_tunnel_response(body);
                let _ = read_tunnel_auth_response(body);
                let _ = read_channel_response(body);
                let _ = read_data(body);
            }
        }
    }
}

fn whole(data: &[u8]) {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().start_paused(true).build().unwrap();
    let feed = data.to_vec();
    runtime.block_on(async move {
        let (client, mut server) = tokio::io::duplex(1 << 16);
        let gateway = tokio::spawn(async move {
            let _ = server.write_all(&feed).await;
            let _ = server.shutdown().await;
            let mut sink = [0u8; 4096];
            while let Ok(n) = server.read(&mut sink).await {
                if n == 0 {
                    break;
                }
            }
        });
        let request = GatewayRequest {
            host: "rdg.example.test".into(),
            username: Some("alex".into()),
            password: Some("made-up-password".into()),
            domain: Some("EXAMPLE".into()),
            target: "pc1.example.test".into(),
            ..GatewayRequest::default()
        };
        if let Ok((mut stream, _end)) = gateway_through(client, &request, Some(b"tls-server-end-point:0".to_vec())).await {
            let _ = stream.write_all(&[3, 0, 0, 11, 6, 0xe0, 0, 0, 0, 0, 0]).await;
            let mut back = Vec::new();
            let _ = stream.read_to_end(&mut back).await;
        }
        gateway.abort();
    });
}

fuzz_target!(|data: &[u8]| {
    harness::init();
    let Some((&mode, rest)) = data.split_first() else { return };
    if mode % 2 == 0 { parsers(rest) } else { whole(rest) }
});
