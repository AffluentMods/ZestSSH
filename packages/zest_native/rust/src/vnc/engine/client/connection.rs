use std::{
    future::Future,
    pin::Pin,
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        Arc,
    },
    task::{Context, Poll},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf},
    sync::{
        mpsc::{channel, error::TryRecvError, Receiver, Sender},
        oneshot, Mutex,
    },
};

use crate::vnc::engine::{codec, DrawTarget, PixelFormat, Rect, VncEncoding, VncError, VncEvent, X11Event};
/// Chunks (each up to 64 KiB) the network task may read ahead of the decoder. Ours: vnc-rs had
/// 4096, so up to 268 MB of a fast server's bytes could pile up here, behind the app's own
/// back-pressure (the pipe asks Dart to pause its SSH channel over 4 MiB, but this task kept
/// emptying the pipe; from a security review). 32 chunks are 2 MiB at most, plus the one being read
/// and the one being decoded; more of them only waits in the pipe, where the pause counts it.
const NETWORK_CHANNEL_SIZE: usize = 32;
const INPUT_CHANNEL_SIZE: usize = 4096;
const OUTPUT_CHANNEL_SIZE: usize = 2;

mod output;

use tokio::spawn;

use super::clipboard;
use super::messages::{ClientMsg, ServerMsg, FENCE_BLOCK_AFTER, FENCE_BLOCK_BEFORE, FENCE_REQUEST};
use super::resize::DesktopState;

/// The network task's chunks, read as one stream by the decoder (vnc-rs bridged them through
/// futures, tokio-stream and tokio-util; this is the same in a few lines).
struct ChannelReader {
    rx: Receiver<std::io::Result<Vec<u8>>>,
    chunk: Vec<u8>,
    at: usize,
}

impl AsyncRead for ChannelReader {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        let this = &mut *self;
        while this.at >= this.chunk.len() {
            match this.rx.poll_recv(cx) {
                Poll::Pending => return Poll::Pending,
                // The network task ended: the end of the stream.
                Poll::Ready(None) => return Poll::Ready(Ok(())),
                Poll::Ready(Some(Err(e))) => return Poll::Ready(Err(e)),
                Poll::Ready(Some(Ok(chunk))) => {
                    this.chunk = chunk;
                    this.at = 0;
                }
            }
        }
        let n = buf.remaining().min(this.chunk.len() - this.at);
        buf.put_slice(&this.chunk[this.at..this.at + n]);
        this.at += n;
        Poll::Ready(Ok(()))
    }
}

/// What the input side and the decoder share (ours, beyond vnc-rs).
#[derive(Default)]
pub(super) struct Shared {
    /// The server confirmed QEMU extended key events.
    qemu_keys: AtomicBool,
    /// The server's extended clipboard caps (None: it has no extended clipboard).
    clipboard_caps: std::sync::Mutex<Option<u32>>,
    /// The text the app last copied, for the server's requests.
    clipboard_text: std::sync::Mutex<Option<String>>,
    /// Continuous updates were offered (the caller wants them, with Fence).
    cu_wanted: AtomicBool,
    /// The server sent a Fence (it takes fences, which TigerVNC needs for continuous updates).
    fence: AtomicBool,
    /// The server has continuous updates (its first EndOfContinuousUpdates).
    cu_supported: AtomicBool,
    /// Continuous updates are on (we enabled them and did not disable them since).
    cu_on: AtomicBool,
    /// Disables sent whose EndOfContinuousUpdates has not come yet.
    cu_disables: AtomicU32,
    /// The app paused updates (it is hidden).
    paused: AtomicBool,
    /// How the network side ended.
    ended: std::sync::Mutex<Option<NetworkEnd>>,
    /// Set by the caller (its [crate::vnc::engine::ConnectOptions::stop]) or by close: the
    /// decoder stops at the next message, rectangle, RRE subrectangle or Hextile tile.
    pub(super) stop: Arc<AtomicBool>,
}

impl Shared {
    fn stopped(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }

    /// Continuous updates can go on: wanted, and the server has them and fences.
    fn cu_ready(&self) -> bool {
        self.cu_wanted.load(Ordering::Acquire)
            && self.fence.load(Ordering::Acquire)
            && self.cu_supported.load(Ordering::Acquire)
    }
}

/// How the decoder behaves beyond vnc-rs: off for vnc-rs's own connector and tests, on through
/// [crate::vnc::engine::connect].
#[derive(Default)]
pub(super) struct LoopCtx {
    /// Where the decoder sends its own requests (the re-request, clipboard answers).
    pub(super) requests: Option<Sender<ClientMsg>>,
    pub(super) shared: Arc<Shared>,
    /// Report [VncEvent::Rectangle] and [VncEvent::UpdateDone].
    pub(super) report_updates: bool,
    /// Ask again for the whole screen when an update before the first pixels carried no pixels
    /// (TigerVNC answers the first request with the layout alone when ExtendedDesktopSize is
    /// offered, and waits for another request).
    pub(super) rerequest_after_layout: bool,
    /// Where pixels go when the app gave a picture (instead of pixel events).
    pub(super) draw: Option<Arc<dyn DrawTarget>>,
}

struct ImageRect {
    rect: Rect,
    encoding: VncEncoding,
}

impl TryFrom<[u8; 12]> for ImageRect {
    type Error = VncError;
    fn try_from(buf: [u8; 12]) -> Result<Self, VncError> {
        Ok(Self {
            rect: Rect {
                x: ((buf[0] as u16) << 8) | buf[1] as u16,
                y: ((buf[2] as u16) << 8) | buf[3] as u16,
                width: ((buf[4] as u16) << 8) | buf[5] as u16,
                height: ((buf[6] as u16) << 8) | buf[7] as u16,
            },
            encoding: VncEncoding::from_wire(
                ((buf[8] as u32) << 24)
                    | ((buf[9] as u32) << 16)
                    | ((buf[10] as u32) << 8)
                    | (buf[11] as u32),
            )?,
        })
    }
}

impl ImageRect {
    async fn read<S>(reader: &mut S) -> Result<Self, VncError>
    where
        S: AsyncRead + Unpin,
    {
        let mut rect_buf = [0_u8; 12];
        reader.read_exact(&mut rect_buf).await?;
        rect_buf.try_into()
    }
}

/// The framebuffer size is shared between the decoder, which learns of resizes,
/// and the input path, which sizes refresh requests; pack it into one atomic.
fn pack_screen((width, height): (u16, u16)) -> u32 {
    (u32::from(width) << 16) | u32::from(height)
}

fn unpack_screen(packed: u32) -> (u16, u16) {
    ((packed >> 16) as u16, packed as u16)
}

/// One connected client's state. Ours (beyond vnc-rs): nothing here is behind one lock any more.
/// vnc-rs kept everything in a mutex that `recv_event` held while it waited, so input from
/// another task stalled until the next server event (seconds on an idle screen). Now the event
/// receiver has a lock of its own, which only receiving takes; input and close take none.
struct ClientState {
    name: String,
    shared: Arc<Shared>,
    screen: Arc<AtomicU32>,
    desktop: Arc<DesktopState>,
    input_ch: Sender<ClientMsg>,
    /// Only [VncClient::recv_event] and [VncClient::poll_event] take it.
    events: Mutex<Receiver<VncEvent>>,
    /// The decoder's and the network task's stop signals, taken by close.
    stops: std::sync::Mutex<(Option<oneshot::Sender<()>>, Option<oneshot::Sender<()>>)>,
    closed: AtomicBool,
}

impl ClientState {
    async fn new<S>(
        mut stream: S,
        shared: bool,
        mut pixel_format: Option<PixelFormat>,
        encodings: Vec<VncEncoding>,
        zest: bool,
        draw: Option<Arc<dyn DrawTarget>>,
        stop: Option<Arc<AtomicBool>>,
    ) -> Result<Self, VncError>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let (conn_ch_tx, conn_ch_rx) = channel(NETWORK_CHANNEL_SIZE);
        let (input_ch_tx, input_ch_rx) = channel(INPUT_CHANNEL_SIZE);
        let (output_ch_tx, output_ch_rx) = channel(OUTPUT_CHANNEL_SIZE);
        let (decoding_stop_tx, mut decoding_stop_rx) = oneshot::channel();
        let (net_conn_stop_tx, net_conn_stop_rx) = oneshot::channel();

        trace!("client init msg");
        send_client_init(&mut stream, shared).await?;

        trace!("server init msg");
        let (name, (width, height)) =
            read_server_init(&mut stream, &mut pixel_format, &|e| async {
                output_ch_tx.send(e).await?;
                Ok(())
            })
            .await?;
        if let Some(draw) = &draw {
            draw.resize(width, height);
        }

        let screen = Arc::new(AtomicU32::new(pack_screen((width, height))));
        let decoder_screen = Arc::clone(&screen);
        let desktop = Arc::new(DesktopState::default());
        let session = Arc::new(Shared { stop: stop.unwrap_or_default(), ..Default::default() });
        session.cu_wanted.store(
            zest && encodings.contains(&VncEncoding::ContinuousUpdatesPseudo)
                && encodings.contains(&VncEncoding::FencePseudo),
            Ordering::Release,
        );
        let ctx = LoopCtx {
            requests: zest.then(|| input_ch_tx.clone()),
            shared: Arc::clone(&session),
            report_updates: zest,
            rerequest_after_layout: zest,
            draw,
        };
        let network_shared = Arc::clone(&session);
        let decoder_desktop = Arc::clone(&desktop);
        let network_desktop = Arc::clone(&desktop);
        trace!("client encodings: {:?}", encodings);
        send_client_encoding(&mut stream, encodings.clone()).await?;

        trace!("Require the first frame");
        input_ch_tx
            .send(ClientMsg::FramebufferUpdateRequest(
                Rect {
                    x: 0,
                    y: 0,
                    width,
                    height,
                },
                0,
            ))
            .await?;

        // start the decoding thread
        spawn(async move {
            trace!("Decoding thread starts");
            let mut conn_ch_rx = ChannelReader { rx: conn_ch_rx, chunk: Vec::new(), at: 0 };

            let output_func = |e| async {
                output_ch_tx.send(e).await?;
                Ok(())
            };

            let pf = pixel_format.as_ref().unwrap();
            let result = vnc_read_loop(
                &mut conn_ch_rx,
                pf,
                &output_func,
                &mut decoding_stop_rx,
                &encodings,
                &decoder_screen,
                &decoder_desktop,
                &ctx,
            )
            .await;
            // Release the network worker and fail any pending resize before waiting
            // for output capacity.
            drop(conn_ch_rx);
            decoder_desktop.close();
            if let Err(error) = result {
                output::report_error(error, &output_ch_tx, &mut decoding_stop_rx).await;
            }
            trace!("Decoding thread stops");
        });

        // start the traffic process thread
        spawn(async move {
            trace!("Net Connection thread starts");
            let end = async_connection_process_loop(stream, input_ch_rx, conn_ch_tx, net_conn_stop_rx).await;
            network_shared.ended.lock().unwrap().get_or_insert(end);
            network_desktop.close();
            trace!("Net Connection thread stops");
        });

        info!("VNC Client {name} starts");
        Ok(Self {
            name,
            shared: session,
            screen,
            desktop,
            input_ch: input_ch_tx,
            events: Mutex::new(output_ch_rx),
            stops: std::sync::Mutex::new((Some(decoding_stop_tx), Some(net_conn_stop_tx))),
            closed: AtomicBool::new(false),
        })
    }

    fn full_area(&self) -> Rect {
        let (width, height) = unpack_screen(self.screen.load(Ordering::Acquire));
        Rect { x: 0, y: 0, width, height }
    }

    /// The messages one input becomes (most one; Pause none or one, Resume one or two).
    fn input_messages(&self, event: X11Event) -> Result<Vec<ClientMsg>, VncError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(VncError::ClientNotRunning);
        }
        let area = self.full_area();
        let msg = match event {
            X11Event::Refresh => ClientMsg::FramebufferUpdateRequest(area, 1),
            // Non-incremental: the server sends the entire framebuffer.
            X11Event::FullRefresh => ClientMsg::FramebufferUpdateRequest(area, 0),
            X11Event::KeyEvent(key) => ClientMsg::KeyEvent(key.keycode, key.down),
            X11Event::PointerEvent(mouse) => {
                ClientMsg::PointerEvent(mouse.position_x, mouse.position_y, mouse.bottons)
            }
            X11Event::CopyText(mut text) => {
                // Our side's text is cut at the limit (at a character's boundary), never a
                // reason to end the session.
                if text.len() > crate::vnc::engine::limits::MAX_TEXT {
                    let mut end = crate::vnc::engine::limits::MAX_TEXT;
                    while !text.is_char_boundary(end) {
                        end -= 1;
                    }
                    text.truncate(end);
                }
                let caps = *self.shared.clipboard_caps.lock().unwrap();
                match caps {
                    // The server takes notify: announce, and provide when it asks.
                    Some(caps) if caps & clipboard::NOTIFY != 0 => {
                        *self.shared.clipboard_text.lock().unwrap() = Some(text);
                        ClientMsg::ExtendedCutText(clipboard::notify(true))
                    }
                    Some(caps) if caps & clipboard::PROVIDE != 0 => {
                        let body = clipboard::provide(Some(&text));
                        *self.shared.clipboard_text.lock().unwrap() = Some(text);
                        ClientMsg::ExtendedCutText(body)
                    }
                    _ => {
                        *self.shared.clipboard_text.lock().unwrap() = Some(text.clone());
                        ClientMsg::ClientCutText(text)
                    }
                }
            }
            X11Event::ScancodeKey { keysym, scancode, down } => {
                if self.shared.qemu_keys.load(Ordering::Acquire) {
                    ClientMsg::QemuKey(down, keysym, scancode)
                } else {
                    ClientMsg::KeyEvent(keysym, down)
                }
            }
            X11Event::Pause => {
                self.shared.paused.store(true, Ordering::Release);
                if self.shared.cu_on.swap(false, Ordering::AcqRel) {
                    // The server answers with EndOfContinuousUpdates once it stopped.
                    self.shared.cu_disables.fetch_add(1, Ordering::AcqRel);
                    return Ok(vec![ClientMsg::EnableContinuousUpdates(false, area)]);
                }
                return Ok(Vec::new());
            }
            X11Event::Resume => {
                self.shared.paused.store(false, Ordering::Release);
                let mut out = Vec::new();
                if self.shared.cu_ready() && !self.shared.cu_on.swap(true, Ordering::AcqRel) {
                    out.push(ClientMsg::EnableContinuousUpdates(true, area));
                }
                out.push(ClientMsg::FramebufferUpdateRequest(area, 0));
                return Ok(out);
            }
        };
        Ok(vec![msg])
    }

    /// Stop the VNC engine and release resources
    fn close(&self) {
        self.desktop.close();
        self.closed.store(true, Ordering::Release);
        // Ours: a decoder in the middle of a long update stops at its next piece of work.
        self.shared.stop.store(true, Ordering::Release);
        let (decoding_stop, net_conn_stop) = {
            let mut stops = self.stops.lock().unwrap();
            (stops.0.take(), stops.1.take())
        };
        if let Some(stop) = net_conn_stop {
            let _ = stop.send(());
        }
        if let Some(stop) = decoding_stop {
            let _ = stop.send(());
        }
    }
}

impl Drop for ClientState {
    fn drop(&mut self) {
        info!("VNC Client {} stops", self.name);
        self.close();
    }
}

/// How the connection's network side ended (ours: the reason a session closed).
#[derive(Debug, Clone)]
pub enum NetworkEnd {
    /// The stream ended (the server, or whatever carries the stream, closed it).
    Eof,
    /// Reading or writing failed.
    Failed(std::io::ErrorKind, String),
    /// The client closed it (or the decoder stopped reading).
    Closed,
}

pub struct VncClient {
    inner: Arc<ClientState>,
}

impl VncClient {
    pub(super) async fn new<S>(
        stream: S,
        shared: bool,
        pixel_format: Option<PixelFormat>,
        encodings: Vec<VncEncoding>,
    ) -> Result<Self, VncError>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        Self::start(stream, shared, pixel_format, encodings, false, None, None).await
    }

    /// [VncClient::new], with our additions on (the re-request after a layout-only update, the
    /// rectangle and end-of-update events, the clipboard's answers, continuous updates and
    /// fences when offered) when [zest] is set, pixels drawn into [draw] when given, and the
    /// decoder stopped as soon as [stop] is set.
    pub(crate) async fn start<S>(
        stream: S,
        shared: bool,
        pixel_format: Option<PixelFormat>,
        encodings: Vec<VncEncoding>,
        zest: bool,
        draw: Option<Arc<dyn DrawTarget>>,
        stop: Option<Arc<AtomicBool>>,
    ) -> Result<Self, VncError>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let inner = ClientState::new(stream, shared, pixel_format, encodings, zest, draw, stop).await?;
        Ok(Self { inner: Arc::new(inner) })
    }

    /// The desktop's name, from ServerInit.
    pub async fn desktop_name(&self) -> String {
        self.inner.name.clone()
    }

    /// The framebuffer's size now (it follows resizes).
    pub async fn screen_size(&self) -> (u16, u16) {
        unpack_screen(self.inner.screen.load(Ordering::Acquire))
    }

    /// Last validated ExtendedDesktopSize layout; None means support is unconfirmed.
    pub fn desktop_layout(&self) -> Option<crate::vnc::engine::DesktopLayout> {
        self.inner.desktop.layout()
    }

    /// Whether the app should ask for the next update after each one: false while continuous
    /// updates are on (the server sends changes by itself) and while paused.
    pub fn wants_requests(&self) -> bool {
        !self.inner.shared.paused.load(Ordering::Acquire) && !self.inner.shared.cu_on.load(Ordering::Acquire)
    }

    /// Continuous updates are on now.
    pub fn continuous_updates(&self) -> bool {
        self.inner.shared.cu_on.load(Ordering::Acquire)
    }

    /// How the network side ended, once it did (None while it runs).
    pub fn network_end(&self) -> Option<NetworkEnd> {
        self.inner.shared.ended.lock().unwrap().clone()
    }

    /// Request a negotiated single-screen resize and wait for the server result.
    /// Available on native targets with a Tokio time driver; wasm supports observation only.
    /// Continue draining events concurrently. Each queue/confirmation wait is bounded
    /// to five seconds. Cancellation after dispatch makes later requests uncertain;
    /// reconnect and observe before retrying. Dispatch includes one incremental one-pixel
    /// update request so servers can deliver the confirmation.
    #[cfg(not(target_arch = "wasm32"))]
    pub async fn resize_desktop(
        &self,
        width: u16,
        height: u16,
    ) -> Result<crate::vnc::engine::DesktopLayout, crate::vnc::engine::ResizeError> {
        self.inner.desktop.request(&self.inner.input_ch, width, height).await
    }

    /// Input a `X11Event` from the frontend. Takes no lock: it never waits for an event to come.
    pub async fn input(&self, event: X11Event) -> Result<(), VncError> {
        if self.inner.closed.load(Ordering::Acquire) {
            return Err(VncError::ClientNotRunning);
        }
        let need = match event {
            X11Event::Resume => 2,
            _ => 1,
        };
        // Wait for room first: a message is built (and Pause and Resume change the state) only
        // once it can go, and none goes after close.
        let permits = self.inner.input_ch.reserve_many(need).await?;
        let messages = self.inner.input_messages(event)?;
        for (permit, message) in permits.zip(messages) {
            permit.send(message);
        }
        Ok(())
    }

    /// Receive a `VncEvent` from the engine
    /// This function will block until a `VncEvent` is received. Only receivers wait for each
    /// other (cancel safe: a dropped call takes nothing).
    pub async fn recv_event(&self) -> Result<VncEvent, VncError> {
        if self.inner.closed.load(Ordering::Acquire) {
            return Err(VncError::ClientNotRunning);
        }
        match self.inner.events.lock().await.recv().await {
            Some(e) => Ok(e),
            None => {
                self.inner.closed.store(true, Ordering::Release);
                Err(VncError::ClientNotRunning)
            }
        }
    }

    /// polling `VncEvent` from the engine and give it to the client
    pub async fn poll_event(&self) -> Result<Option<VncEvent>, VncError> {
        if self.inner.closed.load(Ordering::Acquire) {
            return Err(VncError::ClientNotRunning);
        }
        match self.inner.events.lock().await.try_recv() {
            Err(TryRecvError::Disconnected) => {
                self.inner.closed.store(true, Ordering::Release);
                Err(VncError::ClientNotRunning)
            }
            Err(TryRecvError::Empty) => Ok(None),
            Ok(e) => Ok(Some(e)),
        }
    }

    /// Stop the VNC engine and release resources
    pub async fn close(&self) -> Result<(), VncError> {
        self.inner.close();
        Ok(())
    }
}

impl Clone for VncClient {
    fn clone(&self) -> Self {
        Self { inner: Arc::clone(&self.inner) }
    }
}

async fn send_client_init<S>(stream: &mut S, shared: bool) -> Result<(), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    trace!("Send shared flag: {}", shared);
    stream.write_u8(shared as u8).await?;
    Ok(())
}

async fn read_server_init<S, F, Fut>(
    stream: &mut S,
    pf: &mut Option<PixelFormat>,
    output_func: &F,
) -> Result<(String, (u16, u16)), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    // +--------------+--------------+------------------------------+
    // | No. of bytes | Type [Value] | Description                  |
    // +--------------+--------------+------------------------------+
    // | 2            | U16          | framebuffer-width in pixels  |
    // | 2            | U16          | framebuffer-height in pixels |
    // | 16           | PIXEL_FORMAT | server-pixel-format          |
    // | 4            | U32          | name-length                  |
    // | name-length  | U8 array     | name-string                  |
    // +--------------+--------------+------------------------------+

    let screen_width = stream.read_u16().await?;
    let screen_height = stream.read_u16().await?;
    crate::vnc::engine::limits::dimensions(screen_width, screen_height)?;
    let mut send_our_pf = false;

    output_func(VncEvent::SetResolution(
        (screen_width, screen_height).into(),
    ))
    .await?;

    let pixel_format = PixelFormat::read(stream).await?;
    if pf.is_none() {
        output_func(VncEvent::SetPixelFormat(pixel_format)).await?;
        let _ = pf.insert(pixel_format);
    } else {
        send_our_pf = true;
    }

    let name = crate::vnc::engine::limits::string(stream, crate::vnc::engine::limits::MAX_NAME).await?;

    if send_our_pf {
        trace!("Send customized pixel format {:#?}", pf);
        ClientMsg::SetPixelFormat(*pf.as_ref().unwrap())
            .write(stream)
            .await?;
    }
    Ok((name, (screen_width, screen_height)))
}

async fn send_client_encoding<S>(
    stream: &mut S,
    encodings: Vec<VncEncoding>,
) -> Result<(), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    ClientMsg::SetEncodings(encodings).write(stream).await?;
    Ok(())
}

/// vnc-rs's read loop, as its tests call it: none of our additions.
#[cfg(test)]
async fn asycn_vnc_read_loop<S, F, Fut>(
    stream: &mut S,
    pf: &PixelFormat,
    output_func: &F,
    stop_ch: &mut oneshot::Receiver<()>,
    encodings: &[VncEncoding],
    screen: &AtomicU32,
    desktop: &DesktopState,
) -> Result<(), VncError>
where
    S: AsyncRead + Unpin,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    vnc_read_loop(stream, pf, output_func, stop_ch, encodings, screen, desktop, &LoopCtx::default()).await
}

#[allow(clippy::too_many_arguments)]
async fn vnc_read_loop<S, F, Fut>(
    stream: &mut S,
    pf: &PixelFormat,
    output_func: &F,
    stop_ch: &mut oneshot::Receiver<()>,
    encodings: &[VncEncoding],
    screen: &AtomicU32,
    desktop: &DesktopState,
    ctx: &LoopCtx,
) -> Result<(), VncError>
where
    S: AsyncRead + Unpin,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    tokio::select! {
        biased;
        _ = stop_ch => Ok(()),
        result = read_vnc_messages(stream, pf, output_func, encodings, screen, desktop, ctx) => result,
    }
}

/// Sends one of the decoder's own requests (none when the loop has no request channel).
async fn send_request(ctx: &LoopCtx, msg: ClientMsg) -> Result<(), VncError> {
    if let Some(requests) = &ctx.requests {
        requests.send(msg).await?;
    }
    Ok(())
}

/// Answers one extended clipboard message; returns the server's text when it provided some.
async fn handle_clipboard(ctx: &LoopCtx, body: &[u8]) -> Result<Option<String>, VncError> {
    match clipboard::parse(body)? {
        clipboard::Message::Caps { flags, .. } => {
            *ctx.shared.clipboard_caps.lock().unwrap() = Some(flags);
            send_request(ctx, ClientMsg::ExtendedCutText(clipboard::caps())).await?;
            // Text the app copied before the caps came went as Latin-1: announce it again.
            if flags & clipboard::NOTIFY != 0 && ctx.shared.clipboard_text.lock().unwrap().is_some() {
                send_request(ctx, ClientMsg::ExtendedCutText(clipboard::notify(true))).await?;
            }
        }
        clipboard::Message::Notify { text: true } => {
            send_request(ctx, ClientMsg::ExtendedCutText(clipboard::request_text())).await?;
        }
        clipboard::Message::Notify { text: false } => {}
        clipboard::Message::Request { .. } => {
            let text = ctx.shared.clipboard_text.lock().unwrap().clone();
            send_request(ctx, ClientMsg::ExtendedCutText(clipboard::provide(text.as_deref()))).await?;
        }
        clipboard::Message::Peek => {
            let has = ctx.shared.clipboard_text.lock().unwrap().is_some();
            send_request(ctx, ClientMsg::ExtendedCutText(clipboard::notify(has))).await?;
        }
        clipboard::Message::Provide { text } => return Ok(text),
    }
    Ok(None)
}

async fn read_vnc_messages<S, F, Fut>(
    stream: &mut S,
    pf: &PixelFormat,
    output_func: &F,
    encodings: &[VncEncoding],
    shared_screen: &AtomicU32,
    desktop: &DesktopState,
    ctx: &LoopCtx,
) -> Result<(), VncError>
where
    S: AsyncRead + Unpin,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    let mut raw_decoder = codec::RawDecoder::new();
    let mut zrle_decoder = codec::ZrleDecoder::new();
    let mut tight_decoder = codec::TightDecoder::new();
    // Ours: a solid fill as one colour, not a picture of it (only where the caller reads Fill).
    tight_decoder.fill_events = ctx.report_updates;
    let mut trle_decoder = codec::TrleDecoder::new();
    let mut cursor = codec::CursorDecoder::new();
    // Ours: both stop between subrectangles and tiles when the caller stops the engine.
    let mut rre_decoder = codec::RreDecoder::stopping(Arc::clone(&ctx.shared.stop));
    let mut hextile_decoder = codec::HextileDecoder::stopping(Arc::clone(&ctx.shared.stop));
    let mut zlib_decoder = codec::ZlibRawDecoder::new();
    let mut screen = unpack_screen(shared_screen.load(Ordering::Acquire));
    // Ours: whether pixels came yet, and how often the whole screen was asked for again.
    let mut got_pixels = false;
    let mut rerequests = 0u8;

    // Ours: with a picture to draw into, pixels go there from here (no event, no queue);
    // everything else goes out as before.
    let draw = ctx.draw.as_deref();
    let out = move |e: VncEvent| async move {
        if let Some(d) = draw {
            match e {
                VncEvent::RawImage(rect, pixels) => {
                    d.put(&rect, &pixels);
                    return Ok(());
                }
                VncEvent::Fill(rect, pixel) => {
                    d.fill(&rect, pixel);
                    return Ok(());
                }
                VncEvent::Copy(dst, src) => {
                    d.copy(&dst, &src);
                    return Ok(());
                }
                e => return output_func(e).await,
            }
        }
        output_func(e).await
    };
    let output_func = &out;

    // main decoding loop
    loop {
        // Ours: the session runs this decoder, its network task and the app's loop on one thread.
        // A flood of cheap messages must neither keep the others from running (each message and
        // rectangle uses up some of tokio's budget, so the decoder yields now and then) nor
        // delay a close (the stop flag, looked at before each piece of work).
        stopped(ctx)?;
        tokio::task::consume_budget().await;
        let server_msg = ServerMsg::read(stream).await?;
        trace!("Server message got: {:?}", server_msg);
        match server_msg {
            ServerMsg::FramebufferUpdate(rect_num) => {
                let mut updates = crate::vnc::engine::desktop::UpdateBatch::default();
                let mut framebuffer_changed = false;
                let mut work = crate::vnc::engine::limits::UpdateWork::default();
                for _ in 0..rect_num {
                    stopped(ctx)?;
                    tokio::task::consume_budget().await;
                    let rect = ImageRect::read(stream).await?;
                    if (rect.encoding != VncEncoding::Raw && !encodings.contains(&rect.encoding))
                        || rect.encoding.is_level()
                    {
                        return Err(VncError::InvalidImageData);
                    }
                    if ctx.report_updates {
                        output_func(VncEvent::Rectangle(rect.rect, rect.encoding)).await?;
                    }
                    if !matches!(
                        rect.encoding,
                        VncEncoding::DesktopSizePseudo
                            | VncEncoding::ExtendedDesktopSizePseudo
                            | VncEncoding::LastRectPseudo
                            | VncEncoding::CursorPseudo
                            | VncEncoding::QemuExtendedKeyEventPseudo
                    ) {
                        crate::vnc::engine::limits::rectangle(&rect.rect, screen)?;
                        // Ours: what one update may draw in all.
                        work.draw(&rect.rect, screen)?;
                    }
                    if !matches!(
                        rect.encoding,
                        VncEncoding::CursorPseudo
                            | VncEncoding::ExtendedDesktopSizePseudo
                            | VncEncoding::LastRectPseudo
                            | VncEncoding::QemuExtendedKeyEventPseudo
                    ) {
                        if !updates.is_empty() {
                            return Err(VncError::InvalidImageData);
                        }
                        framebuffer_changed = true;
                    }

                    match rect.encoding {
                        VncEncoding::Raw => {
                            raw_decoder
                                .decode(pf, &rect.rect, stream, output_func)
                                .await?;
                        }
                        VncEncoding::CopyRect => {
                            let source_x = stream.read_u16().await?;
                            let source_y = stream.read_u16().await?;
                            let mut src_rect = rect.rect;
                            src_rect.x = source_x;
                            src_rect.y = source_y;
                            crate::vnc::engine::limits::rectangle(&src_rect, screen)?;
                            output_func(VncEvent::Copy(rect.rect, src_rect)).await?;
                        }
                        VncEncoding::Tight => {
                            tight_decoder
                                .decode(pf, &rect.rect, stream, output_func)
                                .await?;
                        }
                        VncEncoding::Trle => {
                            trle_decoder
                                .decode(pf, &rect.rect, stream, output_func)
                                .await?;
                        }
                        VncEncoding::Zrle => {
                            zrle_decoder
                                .decode(pf, &rect.rect, stream, output_func)
                                .await?;
                        }
                        VncEncoding::CursorPseudo => {
                            cursor.decode(pf, &rect.rect, stream, output_func).await?;
                        }
                        VncEncoding::ExtendedDesktopSizePseudo => {
                            // Confirm only after the entire message excludes framebuffer changes.
                            // Cursor metadata may accompany desktop layout updates.
                            if framebuffer_changed {
                                return Err(VncError::InvalidImageData);
                            }
                            updates.push(crate::vnc::engine::DesktopUpdate::read(stream, rect.rect).await?)?;
                        }
                        VncEncoding::DesktopSizePseudo => {
                            crate::vnc::engine::limits::dimensions(rect.rect.width, rect.rect.height)?;
                            if rect.rect.x != 0 || rect.rect.y != 0 {
                                return Err(VncError::InvalidImageData);
                            }
                            // Ours: each new size makes a new picture; one an update.
                            work.resize()?;
                            screen = (rect.rect.width, rect.rect.height);
                            shared_screen.store(pack_screen(screen), Ordering::Release);
                            desktop.legacy_resize();
                            if let Some(d) = draw {
                                d.resize(screen.0, screen.1);
                            }
                            output_func(VncEvent::SetResolution(
                                (rect.rect.width, rect.rect.height).into(),
                            ))
                            .await?;
                            follow_resize(ctx, screen).await?;
                        }
                        VncEncoding::LastRectPseudo => {
                            break;
                        }
                        VncEncoding::Rre => {
                            rre_decoder.decode(pf, &rect.rect, stream, output_func).await?;
                        }
                        VncEncoding::Hextile => {
                            hextile_decoder.decode(pf, &rect.rect, stream, output_func).await?;
                        }
                        VncEncoding::Zlib => {
                            zlib_decoder.decode(pf, &rect.rect, stream, output_func).await?;
                        }
                        VncEncoding::QemuExtendedKeyEventPseudo => {
                            // An empty rectangle: the server takes QEMU extended key events.
                            ctx.shared.qemu_keys.store(true, Ordering::Release);
                            output_func(VncEvent::QemuKeyEvents).await?;
                        }
                        VncEncoding::JpegQuality(_)
                        | VncEncoding::CompressionLevel(_)
                        | VncEncoding::ExtendedClipboardPseudo
                        | VncEncoding::ContinuousUpdatesPseudo
                        | VncEncoding::FencePseudo => {
                            unreachable!("refused above")
                        }
                    }
                }

                // Ours: a new size by ExtendedDesktopSize is a resize too (vnc-rs only reported
                // the layout, so the picture kept its old size). An update may carry several
                // layouts (TigerVNC queues its answers): the picture is resized once, at the last
                // one, to the size the update ends with.
                let updates = updates.into_updates();
                let last_layout = updates.iter().rposition(|u| u.layout.is_some());
                let before = screen;
                for (i, update) in updates.into_iter().enumerate() {
                    if let Some(layout) = &update.layout {
                        screen = (layout.width, layout.height);
                        shared_screen.store(pack_screen(screen), Ordering::Release);
                        if Some(i) == last_layout && screen != before && ctx.report_updates {
                            if let Some(d) = draw {
                                d.resize(screen.0, screen.1);
                            }
                            output_func(VncEvent::SetResolution(screen.into())).await?;
                            follow_resize(ctx, screen).await?;
                        }
                    }
                    desktop.observe(&update);
                    output_func(VncEvent::DesktopUpdate(update)).await?;
                }
                if framebuffer_changed {
                    got_pixels = true;
                } else if ctx.rerequest_after_layout && !got_pixels && rerequests < 3 {
                    // A layout-only answer to the first request: ask for the pixels. Incremental:
                    // the first (full) request already marked the whole screen as owed, and
                    // TigerVNC answers each full request with the layout first, again.
                    rerequests += 1;
                    send_request(
                        ctx,
                        ClientMsg::FramebufferUpdateRequest(
                            Rect { x: 0, y: 0, width: screen.0, height: screen.1 },
                            1,
                        ),
                    )
                    .await?;
                }
                if ctx.report_updates {
                    output_func(VncEvent::UpdateDone).await?;
                }
            }
            // SetColorMapEntries,
            ServerMsg::Bell => {
                output_func(VncEvent::Bell).await?;
            }
            ServerMsg::ServerCutText(text) => {
                output_func(VncEvent::Text(text)).await?;
            }
            ServerMsg::ExtendedCutText(body) => {
                if let Some(text) = handle_clipboard(ctx, &body).await? {
                    output_func(VncEvent::Text(text)).await?;
                }
            }
            ServerMsg::EndOfContinuousUpdates => {
                let shared = &ctx.shared;
                if !shared.cu_supported.swap(true, Ordering::AcqRel) {
                    // The first: the server has continuous updates (its answer to SetEncodings).
                    enable_continuous_updates(ctx, screen, output_func).await?;
                } else if shared
                    .cu_disables
                    .try_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_sub(1))
                    .is_err()
                    && shared.cu_on.swap(false, Ordering::AcqRel)
                {
                    // Not the answer to a disable of ours: the server stopped them by itself;
                    // the app asks for updates again.
                    output_func(VncEvent::ContinuousUpdates(false)).await?;
                    send_request(ctx, ClientMsg::FramebufferUpdateRequest(
                        Rect { x: 0, y: 0, width: screen.0, height: screen.1 },
                        1,
                    ))
                    .await?;
                }
            }
            ServerMsg::Fence(flags, payload) => {
                let first = !ctx.shared.fence.swap(true, Ordering::AcqRel);
                if flags & FENCE_REQUEST != 0 {
                    // We handle every message in order, so BlockBefore and BlockAfter hold
                    // already; SyncNext is not supported, so it is left out of the answer.
                    send_request(ctx, ClientMsg::Fence(flags & (FENCE_BLOCK_BEFORE | FENCE_BLOCK_AFTER), payload))
                        .await?;
                }
                if first {
                    enable_continuous_updates(ctx, screen, output_func).await?;
                }
            }
        }
    }
}

/// Ours: [VncError::Stopped] once the caller stopped the engine.
fn stopped(ctx: &LoopCtx) -> Result<(), VncError> {
    if ctx.shared.stopped() {
        return Err(VncError::Stopped);
    }
    Ok(())
}

/// Turns continuous updates on for the whole screen once they can go on (wanted, the server has
/// them and fences, not paused, not on already).
async fn enable_continuous_updates<F, Fut>(ctx: &LoopCtx, screen: (u16, u16), output_func: &F) -> Result<(), VncError>
where
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    let shared = &ctx.shared;
    if ctx.requests.is_none() || !shared.cu_ready() || shared.paused.load(Ordering::Acquire) {
        return Ok(());
    }
    if shared.cu_on.swap(true, Ordering::AcqRel) {
        return Ok(());
    }
    send_request(
        ctx,
        ClientMsg::EnableContinuousUpdates(true, Rect { x: 0, y: 0, width: screen.0, height: screen.1 }),
    )
    .await?;
    output_func(VncEvent::ContinuousUpdates(true)).await
}

/// After a resize: continuous updates cover the new screen.
async fn follow_resize(ctx: &LoopCtx, screen: (u16, u16)) -> Result<(), VncError> {
    if ctx.shared.cu_on.load(Ordering::Acquire) {
        send_request(
            ctx,
            ClientMsg::EnableContinuousUpdates(true, Rect { x: 0, y: 0, width: screen.0, height: screen.1 }),
        )
        .await?;
    }
    Ok(())
}

async fn async_connection_process_loop<S>(
    mut stream: S,
    mut input_ch: Receiver<ClientMsg>,
    conn_ch: Sender<std::io::Result<Vec<u8>>>,
    mut stop_ch: oneshot::Receiver<()>,
) -> NetworkEnd
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let mut buffer = [0; 65535];
    let mut pending = 0;

    loop {
        tokio::select! {
            _ = &mut stop_ch => break NetworkEnd::Closed,
            _ = conn_ch.closed() => break NetworkEnd::Closed,
            permit = conn_ch.reserve(), if pending > 0 => {
                match permit {
                    Ok(permit) => {
                        permit.send(Ok(buffer[..pending].to_vec()));
                        pending = 0;
                    }
                    Err(_) => break NetworkEnd::Closed,
                }
            }
            result = stream.read(&mut buffer), if pending == 0 => {
                match result {
                    Ok(0) => break NetworkEnd::Eof,
                    Err(e) => {
                        // Ours: the decoder reads the error (vnc-rs dropped it, so the reason
                        // a session ended was lost).
                        let end = NetworkEnd::Failed(e.kind(), e.to_string());
                        let _ = conn_ch.try_send(Err(e));
                        break end;
                    }
                    Ok(length) => pending = length,
                }
            }
            message = input_ch.recv() => {
                let Some(message) = message else { break NetworkEnd::Closed; };
                tokio::select! {
                    biased;
                    _ = &mut stop_ch => break NetworkEnd::Closed,
                    result = message.write(&mut stream) => {
                        if let Err(e) = result {
                            break match e {
                                VncError::IoError(e) => NetworkEnd::Failed(e.kind(), e.to_string()),
                                e => NetworkEnd::Failed(std::io::ErrorKind::Other, e.to_string()),
                            };
                        }
                    }
                }
            }
        }
    }
    // Dropping the bridge signals EOF without blocking shutdown on a full queue.
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod queue_tests;

#[cfg(test)]
mod resize_tests;
