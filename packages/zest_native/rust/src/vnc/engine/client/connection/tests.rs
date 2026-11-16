use super::*;
use std::time::Duration;
use tokio::io::duplex;

fn rect_header(rect: Rect, encoding: u32) -> Vec<u8> {
    let mut bytes = vec![0, 0, 0, 1];
    for value in [rect.x, rect.y, rect.width, rect.height] {
        bytes.extend(value.to_be_bytes());
    }
    bytes.extend(encoding.to_be_bytes());
    bytes
}

#[tokio::test]
async fn oversized_initialization_is_rejected_before_payload_reads() {
    for (width, height, length) in [
        (u16::MAX, 1, 0),
        (8192, 8192, 0),
        (0, 1, 0),
        (10, 10, u32::MAX),
    ] {
        let (mut client, mut server) = duplex(256);
        server.write_u16(width).await.unwrap();
        server.write_u16(height).await.unwrap();
        server
            .write_all(&Vec::<u8>::from(PixelFormat::rgba()))
            .await
            .unwrap();
        server.write_u32(length).await.unwrap();
        let result = tokio::time::timeout(
            Duration::from_secs(1),
            read_server_init(&mut client, &mut Some(PixelFormat::rgba()), &|_| async {
                Ok(())
            }),
        )
        .await
        .unwrap();
        assert!(result.is_err());
    }
}

#[tokio::test]
async fn invalid_rectangles_and_lengths_are_rejected_before_payload_reads() {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 1,
        height: 1,
    };
    let mut copy = rect_header(rect, VncEncoding::CopyRect.into());
    copy.extend([0, 64, 0, 0]);
    let mut zrle = rect_header(rect, VncEncoding::Zrle.into());
    zrle.extend(u32::MAX.to_be_bytes());
    let mut clipboard = vec![3, 0, 0, 0];
    clipboard.extend(0x7fff_ffffu32.to_be_bytes());
    for payload in [
        rect_header(rect, 12345),
        rect_header(rect, VncEncoding::Tight.into()), // not negotiated
        rect_header(Rect { x: 64, ..rect }, 0),
        rect_header(
            Rect {
                x: u16::MAX,
                ..rect
            },
            0,
        ),
        rect_header(
            Rect {
                width: u16::MAX,
                ..rect
            },
            VncEncoding::DesktopSizePseudo.into(),
        ),
        copy,
        zrle,
        clipboard,
        vec![1],
    ] {
        let (mut client, mut server) = duplex(256);
        server.write_all(&payload).await.unwrap();
        let (_stop, mut stopped) = oneshot::channel();
        let result = tokio::time::timeout(
            Duration::from_secs(1),
            asycn_vnc_read_loop(
                &mut client,
                &PixelFormat::rgba(),
                &|_| async { Ok(()) },
                &mut stopped,
                &[
                    VncEncoding::Raw,
                    VncEncoding::CopyRect,
                    VncEncoding::Zrle,
                    VncEncoding::DesktopSizePseudo,
                ],
                &AtomicU32::new(pack_screen((64, 64))),
                &DesktopState::default(),
            ),
        )
        .await
        .unwrap();
        assert!(result.is_err());
    }
}

#[tokio::test]
async fn raw_is_implicit_and_resize_changes_decoder_bounds() {
    let mut bytes = rect_header(
        Rect {
            x: 0,
            y: 0,
            width: 128,
            height: 96,
        },
        VncEncoding::DesktopSizePseudo.into(),
    );
    bytes.extend(rect_header(
        Rect {
            x: 127,
            y: 95,
            width: 1,
            height: 1,
        },
        0,
    ));
    bytes.extend([1, 2, 3, 255]);
    let output = std::sync::Mutex::new(Vec::new());
    let (_stop, mut stopped) = oneshot::channel();
    let result = asycn_vnc_read_loop(
        &mut bytes.as_slice(),
        &PixelFormat::rgba(),
        &|event| {
            output.lock().unwrap().push(event);
            async { Ok(()) }
        },
        &mut stopped,
        &[VncEncoding::DesktopSizePseudo],
        &AtomicU32::new(pack_screen((64, 64))),
        &DesktopState::default(),
    )
    .await;
    assert!(matches!(result, Err(VncError::IoError(_))));
    let output = output.into_inner().unwrap();
    assert!(
        matches!(&output[0], VncEvent::SetResolution(size) if (size.width, size.height) == (128, 96))
    );
    assert!(
        matches!(&output[1], VncEvent::RawImage(rect, bytes) if (rect.x, rect.y) == (127, 95) && bytes == &[1, 2, 3, 255])
    );
}

#[tokio::test]
async fn shutdown_interrupts_a_full_event_queue() {
    let (events, mut received) = channel(OUTPUT_CHANNEL_SIZE);
    for _ in 0..OUTPUT_CHANNEL_SIZE {
        events.try_send(VncEvent::Bell).unwrap();
    }
    let calls = std::cell::Cell::new(0);
    let output = |event| {
        calls.set(calls.get() + 1);
        events.send(event)
    };
    let (stop, mut stopped) = oneshot::channel();
    let mut input = &[2_u8][..];
    let format = PixelFormat::rgba();
    let deliver = |event| {
        let send = output(event);
        async {
            send.await?;
            Ok(())
        }
    };
    let screen = AtomicU32::new(pack_screen((1, 1)));
    let desktop = DesktopState::default();
    let task = asycn_vnc_read_loop(
        &mut input,
        &format,
        &deliver,
        &mut stopped,
        &[],
        &screen,
        &desktop,
    );
    tokio::pin!(task);
    assert!(crate::vnc::engine::poll_once(task.as_mut()).await.is_pending());
    assert_eq!(calls.get(), 1);
    assert_eq!(events.capacity(), 0);
    stop.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .unwrap()
        .unwrap();
    for _ in 0..OUTPUT_CHANNEL_SIZE {
        assert!(matches!(received.try_recv(), Ok(VncEvent::Bell)));
    }
    assert!(received.try_recv().is_err());
}

#[tokio::test]
async fn full_bridge_resumes_without_unrelated_input_and_cancels_promptly() {
    for cancel in [false, true] {
        let (client, mut server) = duplex(1);
        let (_input, input) = channel(INPUT_CHANNEL_SIZE);
        let (bridge, mut packets) = channel(2);
        for _ in 0..2 {
            bridge.try_send(Ok(vec![0])).unwrap();
        }
        let (stop, stopped) = oneshot::channel();
        server.write_all(&[7]).await.unwrap();
        let task = async_connection_process_loop(client, input, bridge, stopped);
        tokio::pin!(task);
        assert!(crate::vnc::engine::poll_once(task.as_mut()).await.is_pending());
        // The network byte was consumed while every bridge slot remains occupied.
        assert_eq!(packets.len(), 2);
        assert!(crate::vnc::engine::poll_once(Box::pin(server.write_all(&[8]))).await.is_ready());
        if !cancel {
            assert_eq!(packets.recv().await.unwrap().unwrap(), [0]);
            assert!(crate::vnc::engine::poll_once(task.as_mut()).await.is_pending());
            assert_eq!(packets.recv().await.unwrap().unwrap(), [0]);
            assert_eq!(packets.recv().await.unwrap().unwrap(), [7]);
        }
        stop.send(()).unwrap();
        let end = tokio::time::timeout(Duration::from_secs(1), task).await.unwrap();
        assert!(matches!(end, NetworkEnd::Closed), "{end:?}");
        let mut byte = [0];
        assert_eq!(server.read(&mut byte).await.unwrap(), 0);
    }
}

#[tokio::test]
async fn shutdown_interrupts_a_blocked_socket_write() {
    let (client, mut server) = duplex(1);
    let (input, input_rx) = channel(INPUT_CHANNEL_SIZE);
    let (bridge, _packets) = channel(NETWORK_CHANNEL_SIZE);
    let (stop, stopped) = oneshot::channel();
    input
        .send(ClientMsg::ClientCutText("test".into()))
        .await
        .unwrap();
    let task = async_connection_process_loop(client, input_rx, bridge, stopped);
    tokio::pin!(task);
    assert!(crate::vnc::engine::poll_once(task.as_mut()).await.is_pending());
    assert_eq!(input.capacity(), INPUT_CHANNEL_SIZE);
    assert_eq!(server.read_u8().await.unwrap(), 6); // first byte of ClientCutText
    stop.send(()).unwrap();
    let end = tokio::time::timeout(Duration::from_secs(1), task).await.unwrap();
    assert!(matches!(end, NetworkEnd::Closed), "{end:?}");
    assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
}

#[tokio::test]
async fn decoder_exit_releases_an_idle_socket() {
    let (client, mut server) = duplex(1);
    let (_input, input) = channel(INPUT_CHANNEL_SIZE);
    let (bridge, packets) = channel(NETWORK_CHANNEL_SIZE);
    let (_stop, stopped) = oneshot::channel();
    let task = async_connection_process_loop(client, input, bridge, stopped);
    tokio::pin!(task);
    assert!(crate::vnc::engine::poll_once(task.as_mut()).await.is_pending());
    drop(packets);
    let end = tokio::time::timeout(Duration::from_secs(1), task).await.unwrap();
    assert!(matches!(end, NetworkEnd::Closed), "{end:?}");
    assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
}

#[tokio::test]
async fn full_input_queue_does_not_hold_the_client_lock_during_close() {
    let (input_ch, mut input) = channel(INPUT_CHANNEL_SIZE);
    for _ in 0..INPUT_CHANNEL_SIZE {
        input_ch
            .try_send(ClientMsg::ClientCutText(String::new()))
            .unwrap();
    }
    let (_events, output_ch) = channel(OUTPUT_CHANNEL_SIZE);
    let (network_stop, network_stopped) = oneshot::channel();
    let (decoder_stop, decoder_stopped) = oneshot::channel();
    let desktop = Arc::new(DesktopState::default());
    let client = VncClient {
        inner: Arc::new(ClientState {
            name: String::new(),
            shared: Arc::default(),
            screen: Arc::new(AtomicU32::new(pack_screen((1, 1)))),
            desktop,
            input_ch,
            events: Mutex::new(output_ch),
            stops: std::sync::Mutex::new((Some(decoder_stop), Some(network_stop))),
            closed: AtomicBool::new(false),
        }),
    };
    let pending = client.input(X11Event::Refresh);
    tokio::pin!(pending);
    assert!(crate::vnc::engine::poll_once(pending.as_mut()).await.is_pending());
    tokio::time::timeout(Duration::from_secs(1), client.close())
        .await
        .unwrap()
        .unwrap();
    network_stopped.await.unwrap();
    decoder_stopped.await.unwrap();
    // Even if capacity becomes available during close, no stale input is queued.
    input.recv().await.unwrap();
    assert!(matches!(pending.await, Err(VncError::ClientNotRunning)));
    assert_eq!(input.len(), INPUT_CHANNEL_SIZE - 1);
}

/// A client on a duplex stream past ServerInit (1 x 1 screen), with our additions on, and the
/// server's side with ClientInit, SetEncodings and the first request read.
async fn zest_client(encodings: Vec<VncEncoding>) -> (VncClient, tokio::io::DuplexStream) {
    let (stream, mut server) = duplex(1 << 16);
    server.write_u16(1).await.unwrap();
    server.write_u16(1).await.unwrap();
    server.write_all(&Vec::<u8>::from(PixelFormat::rgba())).await.unwrap();
    server.write_u32(0).await.unwrap();
    let n = encodings.len();
    let client = VncClient::start(stream, true, None, encodings, true, None, None).await.unwrap();
    // ClientInit (1), SetEncodings (4 + 4 n), the first request (10).
    let mut head = vec![0u8; 1 + 4 + 4 * n + 10];
    tokio::time::timeout(Duration::from_secs(1), server.read_exact(&mut head)).await.unwrap().unwrap();
    (client, server)
}

async fn read_n(server: &mut tokio::io::DuplexStream, n: usize) -> Vec<u8> {
    let mut b = vec![0u8; n];
    tokio::time::timeout(Duration::from_secs(1), server.read_exact(&mut b)).await.unwrap().unwrap();
    b
}

#[tokio::test]
async fn input_goes_out_while_another_task_waits_for_events() {
    // vnc-rs held the client's lock while recv_event waited: on an idle screen, input from
    // another task waited for the next server event. Now it goes at once.
    let (client, mut server) = zest_client(vec![VncEncoding::Raw]).await;
    let receiver = client.clone();
    let waiting = tokio::spawn(async move {
        // SetResolution (from ServerInit), then nothing until the server speaks.
        loop {
            match receiver.recv_event().await {
                Ok(VncEvent::Bell) => return,
                Ok(_) => {}
                Err(e) => panic!("{e}"),
            }
        }
    });
    tokio::task::yield_now().await;
    tokio::time::timeout(
        Duration::from_millis(500),
        client.input(X11Event::PointerEvent(crate::vnc::engine::ClientMouseEvent { position_x: 3, position_y: 4, bottons: 1 })),
    )
    .await
    .expect("input waited for the receiver")
    .unwrap();
    assert_eq!(read_n(&mut server, 6).await, [5, 1, 0, 3, 0, 4]);
    assert!(!waiting.is_finished());
    server.write_all(&[2]).await.unwrap(); // Bell
    tokio::time::timeout(Duration::from_secs(1), waiting).await.unwrap().unwrap();
    client.close().await.unwrap();
}

#[tokio::test]
async fn continuous_updates_go_on_with_fences_and_stop_and_start_with_pause() {
    let cu = [VncEncoding::Raw, VncEncoding::ContinuousUpdatesPseudo, VncEncoding::FencePseudo];
    let (client, mut server) = zest_client(cu.to_vec()).await;
    assert!(client.wants_requests());
    // The server's fence (a request, BlockBefore, SyncNext, with a payload) and then its
    // EndOfContinuousUpdates, as TigerVNC answers SetEncodings.
    let mut fence = vec![248u8, 0, 0, 0];
    fence.extend((FENCE_REQUEST | FENCE_BLOCK_BEFORE | 4).to_be_bytes());
    fence.extend([3, 7, 8, 9]);
    server.write_all(&fence).await.unwrap();
    // The answer: Request and SyncNext cleared, the payload back.
    let mut answer = vec![248u8, 0, 0, 0];
    answer.extend(FENCE_BLOCK_BEFORE.to_be_bytes());
    answer.extend([3, 7, 8, 9]);
    assert_eq!(read_n(&mut server, answer.len()).await, answer);
    server.write_all(&[150]).await.unwrap();
    // EnableContinuousUpdates for the whole screen, and the event.
    assert_eq!(read_n(&mut server, 10).await, [150, 1, 0, 0, 0, 0, 0, 1, 0, 1]);
    loop {
        match tokio::time::timeout(Duration::from_secs(1), client.recv_event()).await.unwrap().unwrap() {
            VncEvent::ContinuousUpdates(true) => break,
            VncEvent::SetResolution(_) | VncEvent::SetPixelFormat(_) => {}
            e => panic!("{e:?}"),
        }
    }
    assert!(client.continuous_updates() && !client.wants_requests());

    // Pause: off, and no requests; the server's EndOfContinuousUpdates is the answer to it.
    client.input(X11Event::Pause).await.unwrap();
    assert_eq!(read_n(&mut server, 10).await, [150, 0, 0, 0, 0, 0, 0, 1, 0, 1]);
    assert!(!client.continuous_updates() && !client.wants_requests());
    server.write_all(&[150]).await.unwrap();
    // Resume: on again, then the whole screen (a full request).
    client.input(X11Event::Resume).await.unwrap();
    assert_eq!(read_n(&mut server, 20).await, [150, 1, 0, 0, 0, 0, 0, 1, 0, 1, 3, 0, 0, 0, 0, 0, 0, 1, 0, 1]);
    assert!(client.continuous_updates() && !client.wants_requests());
    // The answer to the pause's disable came after the resume: they stay on.
    server.write_all(&[2]).await.unwrap(); // Bell, to know the EndOfContinuousUpdates was read
    loop {
        if let VncEvent::Bell = tokio::time::timeout(Duration::from_secs(1), client.recv_event()).await.unwrap().unwrap() {
            break;
        }
    }
    assert!(client.continuous_updates());
    // The server stops them by itself: off, and the app asks again (an incremental request).
    server.write_all(&[150]).await.unwrap();
    assert_eq!(read_n(&mut server, 10).await, [3, 1, 0, 0, 0, 0, 0, 1, 0, 1]);
    assert!(!client.continuous_updates() && client.wants_requests());
    client.close().await.unwrap();
}

#[tokio::test]
async fn without_fences_or_when_not_offered_updates_stay_one_per_request() {
    // EndOfContinuousUpdates with no fence (TigerVNC refuses continuous updates without fences).
    let cu = [VncEncoding::Raw, VncEncoding::ContinuousUpdatesPseudo, VncEncoding::FencePseudo];
    let (client, mut server) = zest_client(cu.to_vec()).await;
    server.write_all(&[150, 2]).await.unwrap(); // EndOfContinuousUpdates, Bell
    loop {
        if let VncEvent::Bell = tokio::time::timeout(Duration::from_secs(1), client.recv_event()).await.unwrap().unwrap() {
            break;
        }
    }
    assert!(!client.continuous_updates() && client.wants_requests());
    // Pause without continuous updates: nothing to send, no requests while paused.
    client.input(X11Event::Pause).await.unwrap();
    assert!(!client.wants_requests());
    client.input(X11Event::Resume).await.unwrap();
    assert_eq!(read_n(&mut server, 10).await, [3, 0, 0, 0, 0, 0, 0, 1, 0, 1]);
    client.close().await.unwrap();

    // Not offered (the caller turned them off): a fence and EndOfContinuousUpdates change nothing.
    let (client, mut server) = zest_client(vec![VncEncoding::Raw]).await;
    let mut fence = vec![248u8, 0, 0, 0];
    fence.extend(0u32.to_be_bytes());
    fence.push(0);
    server.write_all(&fence).await.unwrap();
    server.write_all(&[150, 2]).await.unwrap();
    loop {
        if let VncEvent::Bell = tokio::time::timeout(Duration::from_secs(1), client.recv_event()).await.unwrap().unwrap() {
            break;
        }
    }
    assert!(!client.continuous_updates() && client.wants_requests());
    client.close().await.unwrap();
}

#[tokio::test]
async fn the_network_end_is_kept() {
    // The server closes the stream: EOF.
    let (client, server) = zest_client(vec![VncEncoding::Raw]).await;
    drop(server);
    loop {
        if tokio::time::timeout(Duration::from_secs(1), client.recv_event()).await.unwrap().is_err() {
            break;
        }
    }
    assert!(matches!(client.network_end(), Some(NetworkEnd::Eof)), "{:?}", client.network_end());

    // A read error reaches the decoder (vnc-rs dropped it) and is kept.
    struct Failing;
    impl AsyncRead for Failing {
        fn poll_read(self: Pin<&mut Self>, _: &mut Context<'_>, _: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::ConnectionAborted, "channel lost")))
        }
    }
    impl AsyncWrite for Failing {
        fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, b: &[u8]) -> Poll<std::io::Result<usize>> {
            Poll::Ready(Ok(b.len()))
        }
        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
        fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }
    let (input_tx, input) = channel(INPUT_CHANNEL_SIZE);
    let (bridge, mut packets) = channel(NETWORK_CHANNEL_SIZE);
    let (_stop, stopped) = oneshot::channel();
    let end = async_connection_process_loop(Failing, input, bridge, stopped).await;
    drop(input_tx);
    assert!(matches!(&end, NetworkEnd::Failed(std::io::ErrorKind::ConnectionAborted, m) if m == "channel lost"), "{end:?}");
    assert!(matches!(packets.recv().await, Some(Err(e)) if e.to_string() == "channel lost"));
}

#[tokio::test]
async fn the_network_task_reads_at_most_a_few_mib_ahead_of_the_decoder() {
    // From a security review: with the decoder busy (nothing taken from the bridge), the network task
    // kept reading the stream into the bridge: 62 MiB held in the probe, 268 MB possible.
    struct Endless {
        given: Arc<std::sync::atomic::AtomicUsize>,
    }
    impl AsyncRead for Endless {
        fn poll_read(self: Pin<&mut Self>, _: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
            // As much as asked for, up to 64 MiB in all; then nothing more comes.
            if self.given.load(Ordering::Relaxed) >= 64 << 20 {
                return Poll::Pending;
            }
            let n = buf.remaining();
            buf.put_slice(&vec![2u8; n]);
            self.given.fetch_add(n, Ordering::Relaxed);
            Poll::Ready(Ok(()))
        }
    }
    impl AsyncWrite for Endless {
        fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, b: &[u8]) -> Poll<std::io::Result<usize>> {
            Poll::Ready(Ok(b.len()))
        }
        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
        fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }
    let given = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let (_input, input) = channel(INPUT_CHANNEL_SIZE);
    let (bridge, _packets) = channel(NETWORK_CHANNEL_SIZE);
    let (_stop, stopped) = oneshot::channel();
    let task = async_connection_process_loop(Endless { given: given.clone() }, input, bridge, stopped);
    tokio::pin!(task);
    // Until it waits (for room in the bridge, or for bytes the stream has no more of): each poll
    // after a yield, with tokio's budget fresh, so a poll that reads nothing is really stuck.
    let mut last = usize::MAX;
    loop {
        tokio::task::yield_now().await;
        assert!(crate::vnc::engine::poll_once(task.as_mut()).await.is_pending());
        let now = given.load(Ordering::Relaxed);
        if now == last {
            break;
        }
        last = now;
    }
    let read = given.load(Ordering::Relaxed);
    assert!(read <= 3 << 20, "the network task read {} KiB ahead of the decoder", read >> 10);
}
