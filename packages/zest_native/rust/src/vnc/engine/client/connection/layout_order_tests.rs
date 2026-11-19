// A server's own new layout (ExtendedDesktopSize, reason "server") before pixels in that size in
// the same update, as wayvnc sends it: the new size is taken at once and the pixels after it are
// drawn, in the order they came (it ended the session with invalid image data). vnc-rs
// bfd802b19b, ported to this engine.
use super::resize_tests::{event, extended, handshake, rect_header, single};
use super::*;
use crate::vnc::engine::DesktopReason;
use tokio::io::duplex;

#[tokio::test]
async fn a_servers_layout_before_its_pixels_takes_the_new_size_in_wire_order() {
    let (stream, mut server) = duplex(8192);
    let task = tokio::spawn(async move {
        handshake(&mut server, (80, 60)).await;
        for (width, height) in [(160, 100), (40, 30)] {
            // One update: the server's layout (reason 0), then one pixel at its far corner.
            let mut packet = vec![0, 0, 0, 2];
            packet.extend(&single(0, 0, width, height)[4..]);
            let mut raw = rect_header(Rect { x: width - 1, y: height - 1, width: 1, height: 1 }, 0);
            raw.extend([10, 20, 30, 255]);
            packet.extend(&raw[4..]);
            server.write_all(&packet).await.unwrap();
        }
        server.write_all(&[2]).await.unwrap(); // A Bell: the decoder stayed in step.
        let mut byte = [0];
        let _ = server.read(&mut byte).await;
    });
    let client = extended(stream).await;
    let mut seen = Vec::new();
    loop {
        match event(&client).await {
            VncEvent::Bell => break,
            VncEvent::DesktopUpdate(update) => {
                assert_eq!(update.reason, DesktopReason::Server);
                let layout = update.layout.expect("a layout");
                seen.push(format!("layout {}x{}", layout.width, layout.height));
            }
            VncEvent::RawImage(rect, bytes) => {
                assert_eq!(bytes, [10, 20, 30, 255]);
                seen.push(format!("pixel {},{}", rect.x, rect.y));
            }
            _ => {}
        }
    }
    assert_eq!(seen, ["layout 160x100", "pixel 159,99", "layout 40x30", "pixel 39,29"]);
    assert_eq!(client.desktop_layout().unwrap().width, 40);
    client.close().await.unwrap();
    task.await.unwrap();
}
