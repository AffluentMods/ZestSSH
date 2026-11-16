//! RDP for the targets (4.0).
//!
//! The session is driven as Dart drives it (harness::ffi), with one difference only a fuzz build
//! has: the request's `fuzz_as_if_tls` makes the session take the channel as if TLS had come up
//! on it (rdp::Secured::for_fuzzing), so a target's bytes reach the sign-in (CredSSP, the
//! settings, the channels, the licence, the capabilities) and the session after it, which a real
//! TLS handshake would keep any fuzzer out of.
//!
//! A server's side of a whole sign-in is not written out here by hand: IronRDP's own acceptor
//! (ironrdp-acceptor, in this package only, never in the app) answers the same connector the
//! session uses, once a process, and what it sent is kept ([handshake], [nla_handshake]). So the
//! bytes follow the connector when it changes, and [check] fails the run if they stop signing in.

use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};

use ironrdp_acceptor::{Acceptor, BeginResult};
use ironrdp_connector::{ClientConnector, DesktopSize, ServerName};
use ironrdp_pdu::nego::SecurityProtocol;
use ironrdp_pdu::rdp::capability_sets::{
    Bitmap, BitmapDrawingFlags, CapabilitySet, CmdFlags, General, GeneralExtraFlags, Input, InputFlags, LargePointer,
    LargePointerSupportFlags, MultifragmentUpdate, Order, OrderFlags, OrderSupportExFlags, Pointer, SurfaceCommands,
    VirtualChannel, VirtualChannelFlags, server_codecs_capabilities,
};
use ironrdp_tokio::TokioFramed;
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};
use zest_native::rdp::{Graphics, Nla, NoNetwork, Secured, connector_config, hold_credentials};
use zest_native::screen::fuzzing::Clipboard;

pub const USER: &str = "alex";
pub const PASSWORD: &str = "secret";
const WIDTH: u16 = 800;
const HEIGHT: u16 = 600;
/// The public key the fuzz build's stand-in for TLS reports (rdp::Secured::for_fuzzing), which
/// CredSSP binds to on both sides.
const PUBLIC_KEY: [u8; 32] = [7; 32];

/// The session's request: the graphics by `pick`'s low two bits, a domain with its third; with
/// NLA (a host's default: CredSSP alone is asked for) or without it (TLS alone, and no password
/// sent), which decides the Connection Confirm the session takes.
pub fn request(pick: u8, nla: bool) -> String {
    let graphics = ["gfx", "remotefx", "bitmap", "gfx"][usize::from(pick & 3)];
    let mut r = serde_json::json!({
        "kind": "rdp",
        "username": USER,
        "password": PASSWORD,
        "server_name": "rdp.invalid",
        "width": WIDTH,
        "height": HEIGHT,
        "rdp_graphics": graphics,
        "rdp_h264": "off",
        "rdp_nla": nla,
        // Every made sign-in has the clipboard's channel ([record]), so every session asks for
        // it: shared from the start, or not until the app's switch says so.
        "rdp_clipboard": if pick & 8 != 0 { "off" } else { "on" },
        "fuzz_as_if_tls": true,
    });
    if pick & 4 != 0 {
        r["domain"] = "CORP".into();
    }
    r.to_string()
}

/// A server's Connection Confirm that picks `protocol`: 1 TLS, 2 NLA, 8 NLA with the early
/// result (anything else the session refuses).
pub fn confirm(protocol: u32) -> Vec<u8> {
    let mut b = b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x1f\x08\x00".to_vec();
    b.extend(protocol.to_le_bytes());
    b
}

/// One end of a pipe that keeps what is written to it.
struct Recorded {
    stream: DuplexStream,
    written: Arc<Mutex<Vec<u8>>>,
}

impl AsyncRead for Recorded {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.stream).poll_read(cx, buf)
    }
}

impl AsyncWrite for Recorded {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, b: &[u8]) -> Poll<std::io::Result<usize>> {
        let n = match Pin::new(&mut self.stream).poll_write(cx, b) {
            Poll::Ready(Ok(n)) => n,
            other => return other,
        };
        self.written.lock().unwrap().extend_from_slice(&b[..n]);
        Poll::Ready(Ok(n))
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.stream).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(cx)
    }
}

/// What a server of this size tells a client it can do.
fn capabilities() -> Vec<CapabilitySet> {
    vec![
        CapabilitySet::General(General {
            extra_flags: GeneralExtraFlags::FASTPATH_OUTPUT_SUPPORTED,
            ..Default::default()
        }),
        CapabilitySet::Bitmap(Bitmap {
            pref_bits_per_pix: 32,
            desktop_width: WIDTH,
            desktop_height: HEIGHT,
            desktop_resize_flag: true,
            drawing_flags: BitmapDrawingFlags::empty(),
        }),
        CapabilitySet::Order(Order::new(
            OrderFlags::NEGOTIATE_ORDER_SUPPORT | OrderFlags::ZERO_BOUNDS_DELTAS_SUPPORT,
            OrderSupportExFlags::empty(),
            0,
            0,
        )),
        CapabilitySet::Input(Input {
            input_flags: InputFlags::all(),
            keyboard_layout: 0,
            keyboard_type: None,
            keyboard_subtype: 0,
            keyboard_function_key: 0,
            keyboard_ime_filename: String::new(),
        }),
        CapabilitySet::Pointer(Pointer { color_pointer_cache_size: 25, pointer_cache_size: 25 }),
        CapabilitySet::VirtualChannel(VirtualChannel { flags: VirtualChannelFlags::NO_COMPRESSION, chunk_size: Some(1600) }),
        CapabilitySet::LargePointer(LargePointer { flags: LargePointerSupportFlags::UP_TO_96X96_PIXELS }),
        CapabilitySet::SurfaceCommands(SurfaceCommands {
            flags: CmdFlags::SET_SURFACE_BITS | CmdFlags::STREAM_SURFACE_BITS | CmdFlags::FRAME_MARKER,
        }),
        CapabilitySet::BitmapCodecs(server_codecs_capabilities(&[]).unwrap()),
        CapabilitySet::MultiFragmentUpdate(MultifragmentUpdate { max_request_size: 8 << 20 }),
    ]
}

/// One made sign-in.
pub struct Made {
    /// Every byte the server sent, from its Connection Confirm on.
    pub server: Vec<u8>,
    /// The user name the server was given.
    name: String,
    /// The channels and the share the two agreed on: what a server's later PDUs are addressed by.
    io: u16,
    user: u16,
    drdynvc: Option<u16>,
    clipboard: Option<u16>,
    share_id: u32,
}

/// A whole sign-in between the session's connector and IronRDP's acceptor, over a pipe in this
/// process with TLS left out on both sides.
fn record(nla: bool) -> Result<Made, String> {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
    let written = Arc::new(Mutex::new(Vec::new()));
    let (client_end, server_end) = tokio::io::duplex(1 << 20);
    let server_end = Recorded { stream: server_end, written: written.clone() };

    let client = async {
        // As a session asks: NLA alone, or TLS alone for a host that says without.
        let how = if nla { Nla::Required } else { Nla::Without };
        let mut config = connector_config(WIDTH, HEIGHT, USER.into(), PASSWORD.into(), None, Graphics::Gfx, how);
        let credentials = hold_credentials(&mut config);
        let address = std::net::SocketAddr::from(([127, 0, 0, 1], 0));
        let mut connector = ClientConnector::new(config, address)
            .with_static_channel(ironrdp_dvc::DrdynvcClient::new())
            .with_static_channel(Clipboard::new(true));
        let mut framed = TokioFramed::new(client_end);
        let should_upgrade = ironrdp_tokio::connect_begin(&mut framed, &mut connector)
            .await
            .map_err(|e| format!("client, connection request: {e}"))?;
        let (stream, ahead) = framed.into_inner();
        let secured = Secured::for_fuzzing(TokioFramed::new_with_leftover(stream, ahead));
        let signed_in = secured
            .sign_in(should_upgrade, connector, credentials, "rdp.invalid")
            .await
            .map_err(|e| format!("client, sign-in: {e:?}"))?;
        let c = &signed_in.connection;
        let drdynvc = c.static_channels.get_channel_id_by_type::<ironrdp_dvc::DrdynvcClient>();
        let clipboard = c.static_channels.get_channel_id_by_type::<Clipboard>();
        Ok::<_, String>((c.io_channel_id, c.user_channel_id, drdynvc, clipboard, c.share_id))
    };

    let server = async {
        let security = if nla { SecurityProtocol::HYBRID | SecurityProtocol::HYBRID_EX } else { SecurityProtocol::SSL };
        let expected = nla.then(|| ironrdp_acceptor_credentials());
        let mut acceptor = Acceptor::new(security, DesktopSize { width: WIDTH, height: HEIGHT }, capabilities(), expected);
        let framed = TokioFramed::new(server_end);
        let stream = match ironrdp_acceptor::accept_begin(framed, &mut acceptor)
            .await
            .map_err(|e| format!("server, connection request: {e:?}"))?
        {
            BeginResult::ShouldUpgrade(stream) => stream,
            BeginResult::Continue(_) => return Err("the server went on without TLS".to_owned()),
        };
        acceptor.mark_security_upgrade_as_done();
        let mut framed = TokioFramed::new(stream);
        // With NLA the name comes with CredSSP, without it in the Client Info PDU.
        let mut seen = Seen(None);
        if acceptor.should_perform_credssp() {
            ironrdp_acceptor::accept_credssp_with(
                &mut framed,
                &mut acceptor,
                &mut NoNetwork,
                ServerName::new("client"),
                PUBLIC_KEY.to_vec(),
                None,
                &mut seen,
            )
            .await
            .map_err(|e| format!("server, CredSSP: {e:?}"))?;
        }
        ironrdp_acceptor::accept_finalize_with(framed, &mut acceptor, &mut seen)
            .await
            .map_err(|e| format!("server, sign-in: {e:?}"))?;
        Ok(seen.0.unwrap_or_default())
    };

    let (client, server) = runtime.block_on(async { tokio::join!(client, server) });
    let (io, user, drdynvc, clipboard, share_id) = client?;
    let name = server?;
    let server = written.lock().unwrap().clone();
    Ok(Made { server, name, io, user, drdynvc, clipboard, share_id })
}

fn ironrdp_acceptor_credentials() -> ironrdp_pdu::rdp::client_info::Credentials {
    ironrdp_pdu::rdp::client_info::Credentials { username: USER.into(), password: PASSWORD.into(), domain: None }
}

/// The user name the server was signed in with.
struct Seen(Option<String>);

#[async_trait::async_trait(?Send)]
impl ironrdp_acceptor::ConnectionSetupHandler for Seen {
    async fn handle_credentials(
        &mut self,
        credentials: Option<ironrdp_acceptor::ReceivedCredentials>,
    ) -> ironrdp_connector::ConnectorResult<()> {
        if let Some(c) = credentials {
            self.0 = Some(c.credentials.username);
        }
        Ok(())
    }
}

fn made(nla: bool) -> &'static Made {
    static MADE: [OnceLock<Made>; 2] = [OnceLock::new(), OnceLock::new()];
    MADE[usize::from(nla)].get_or_init(|| {
        let made = record(nla).unwrap_or_else(|e| panic!("no sign-in to start from (NLA {nla}): {e}"));
        // The name kept out of the connection request (rdp::hold_credentials) did reach the
        // server afterwards.
        assert_eq!(made.name, USER, "the server was not given the user name (NLA {nla})");
        made
    })
}

/// Everything a server sends for a sign-in without NLA (TLS picked; the session must be one that
/// says without, `request(pick, false)`), from its Connection Confirm to the end of the
/// connection sequence. The session is in its loop when it has read this.
pub fn handshake() -> &'static [u8] {
    &made(false).server
}

/// The same with NLA: the Connection Confirm, CredSSP's messages (answers to another run's
/// nonces, so a session gets as far as checking them), then the rest.
pub fn nla_handshake() -> &'static [u8] {
    &made(true).server
}

fn le16(v: u16) -> [u8; 2] {
    v.to_le_bytes()
}

/// A slow-path frame: TPKT, X.224 data, MCS Send Data Indication on `channel`.
fn mcs(channel: u16, data: &[u8]) -> Vec<u8> {
    let mut body = vec![0x02, 0xf0, 0x80, 0x68];
    body.extend(1u16.to_be_bytes()); // the initiator: user 1002, less 1001
    body.extend(channel.to_be_bytes());
    body.push(0x70);
    body.extend((0x8000 | data.len() as u16).to_be_bytes());
    body.extend_from_slice(data);
    let mut frame = vec![3, 0];
    frame.extend((body.len() as u16 + 4).to_be_bytes());
    frame.extend(body);
    frame
}

/// A fast-path output PDU of `updates` (each a code and its data).
fn fast_path(updates: &[(u8, Vec<u8>)]) -> Vec<u8> {
    let mut body = Vec::new();
    for (code, data) in updates {
        body.push(*code);
        body.extend(le16(data.len() as u16));
        body.extend_from_slice(data);
    }
    let total = body.len() as u16 + 3;
    let mut frame = vec![0x00, 0x80 | (total >> 8) as u8, total as u8];
    frame.extend(body);
    frame
}

impl Made {
    /// A Share Control PDU of `kind` on the I/O channel.
    fn share_control(&self, kind: u16, body: &[u8]) -> Vec<u8> {
        let mut pdu = Vec::new();
        pdu.extend(le16(body.len() as u16 + 6));
        pdu.extend(le16(0x10 | kind));
        pdu.extend(le16(1002));
        pdu.extend_from_slice(body);
        mcs(self.io, &pdu)
    }

    /// A Share Data PDU of `kind`.
    fn share_data(&self, kind: u8, body: &[u8]) -> Vec<u8> {
        let mut pdu = self.share_id.to_le_bytes().to_vec();
        pdu.extend([0, 1]);
        pdu.extend(le16(body.len() as u16));
        pdu.extend([kind, 0, 0, 0]);
        pdu.extend_from_slice(body);
        self.share_control(7, &pdu)
    }

    /// One message on the dynamic channels' static channel (a whole chunk).
    fn dynamic(&self, pdu: &[u8]) -> Vec<u8> {
        let Some(channel) = self.drdynvc else { return Vec::new() };
        let mut chunk = (pdu.len() as u32).to_le_bytes().to_vec();
        chunk.extend(3u32.to_le_bytes()); // first and last
        chunk.extend_from_slice(pdu);
        mcs(channel, &chunk)
    }

    /// One piece of a message on a static channel: the whole is said to be `said` bytes, with
    /// these flags (1 first, 2 last).
    fn piece(channel: Option<u16>, said: u32, flags: u32, bytes: &[u8]) -> Vec<u8> {
        let Some(channel) = channel else { return Vec::new() };
        let mut chunk = said.to_le_bytes().to_vec();
        chunk.extend(flags.to_le_bytes());
        chunk.extend_from_slice(bytes);
        mcs(channel, &chunk)
    }

    /// One message of the clipboard's channel, whole: its type, flags and data.
    fn clip(&self, kind: u16, flags: u16, data: &[u8]) -> Vec<u8> {
        let mut pdu = [le16(kind), le16(flags)].concat();
        pdu.extend((data.len() as u32).to_le_bytes());
        pdu.extend_from_slice(data);
        Self::piece(self.clipboard, pdu.len() as u32, 3, &pdu)
    }

    /// The dynamic channels' start, and channel `id` opened by `name`.
    fn dynamic_open(&self, id: u8, name: &str) -> Vec<u8> {
        let mut create = vec![0x10, id];
        create.extend(name.as_bytes());
        create.push(0);
        [self.dynamic(&[0x50, 0, 1, 0]), self.dynamic(&create)].concat()
    }

    /// The frames of the sign-in from the server's capabilities on (Demand Active and the last
    /// PDUs of the sequence): what follows a Deactivate All too.
    fn from_capabilities(&self) -> &[u8] {
        let mut at = 19;
        while at + 4 <= self.server.len() {
            let frame = &self.server[at..];
            let len = usize::from(u16::from_be_bytes([frame[2], frame[3]]));
            // TPKT 4, X.224 3, MCS 6 with a length of 1 or 2 bytes, then the share control header.
            if frame.len() > 16 && frame[7] == 0x68 {
                let header = 13 + if frame[13] & 0x80 != 0 { 2 } else { 1 };
                if frame.len() > header + 3 && frame[header + 2] & 0x0f == 1 {
                    return frame;
                }
            }
            at += len.max(4);
        }
        &[]
    }

    /// Seeds for rdp_session: the request's pick, the input's, then the server after the sign-in.
    fn session_seeds(&self, gfx_messages: &[u8]) -> Vec<(&'static str, Vec<u8>)> {
        let bitmap = [le16(1), le16(1), le16(0), le16(0), le16(0), le16(0), le16(4), le16(4), le16(32), le16(1), le16(4)]
            .concat()
            .into_iter()
            .chain([0u8; 4])
            .collect::<Vec<u8>>();
        // Set Surface Bits: 4 by 4 pixels at 32 bits into a rectangle `right` wide and 4 high.
        let surface = |right: u16, codec: u8| {
            [le16(1), le16(0), le16(0), le16(right), le16(4)]
                .concat()
                .into_iter()
                .chain([32, 0, 0, codec])
                .chain(le16(4))
                .chain(le16(4))
                .chain(64u32.to_le_bytes())
                .chain([0x40u8; 64])
                .collect::<Vec<u8>>()
        };
        // A 2 by 2 pointer of 32 bits a pixel: its colours, then its mask (a row is 2 bytes).
        let pointer = [le16(32), le16(0), le16(0), le16(0), le16(2), le16(2), le16(4), le16(16)]
            .concat()
            .into_iter()
            .chain([0xffu8; 16])
            .chain([0u8; 4])
            .collect::<Vec<u8>>();
        let deactivate = self.share_control(6, &[&self.share_id.to_le_bytes()[..], &le16(1), &[0]].concat());
        let display = "Microsoft::Windows::RDS::DisplayControl";
        let graphics = "Microsoft::Windows::RDS::Graphics";
        // The display control channel's capabilities: 1 monitor, 8192 by 8192 at most.
        let display_caps: Vec<u8> =
            [5u32, 20, 1, 8192, 8192].iter().flat_map(|v| v.to_le_bytes()).collect();
        let mut gfx = self.dynamic_open(2, graphics);
        let mut rest = gfx_messages;
        while let [a, b, tail @ ..] = rest {
            let len = usize::from(u16::from_be_bytes([*a, *b])).min(tail.len());
            let (message, next) = tail.split_at(len);
            rest = next;
            gfx.extend(self.dynamic(&[&[0x30, 2][..], message].concat()));
        }
        let seed = |pick: u8, input: u8, server: Vec<u8>| [vec![pick, input], server].concat();
        // The clipboard: the server's capabilities (long names), ready, a list with text, the
        // text; then the server asks for this device's.
        let utf16 = |text: &str| text.encode_utf16().chain([0]).flat_map(u16::to_le_bytes).collect::<Vec<u8>>();
        let text_list = [&13u32.to_le_bytes()[..], &[0, 0]].concat();
        let clip_caps = self.clip(7, 0, &[1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0, 2, 0, 0, 0]);
        let clipboard = [
            clip_caps.clone(),
            self.clip(1, 0, &[]),
            self.clip(2, 0, &text_list),
            self.clip(5, 1, &utf16("from the remote")),
            self.clip(4, 0, &13u32.to_le_bytes()),
        ]
        .concat();
        // What the channel guard is for (rdp_channels.rs): a clipboard message said to be far
        // too long is let go by, piece by piece, and the next one is taken; the same on the
        // dynamic channels' carrier, and a dynamic channel message of 4 GiB, end the session.
        let long_clipboard = [
            clip_caps,
            self.clip(1, 0, &[]),
            self.clip(2, 0, &text_list),
            Self::piece(self.clipboard, u32::MAX, 1, &[5, 0, 1, 0, 0xf8, 0xff, 0xff, 0xff]),
            Self::piece(self.clipboard, u32::MAX, 0, &[0x41; 1600]),
            Self::piece(self.clipboard, u32::MAX, 2, &[0x41; 16]),
            self.clip(2, 0, &text_list),
            self.clip(5, 1, &utf16("short")),
        ]
        .concat();
        let long_dynamic = [
            self.dynamic_open(2, graphics),
            self.dynamic(&[&[0x28, 2][..], &u32::MAX.to_le_bytes(), &[0xe0; 64]].concat()),
        ]
        .concat();
        vec![
            ("clipboard", seed(0, 0x44, clipboard.clone())),
            ("clipboard_off_then_on", seed(8, 0x44, clipboard)),
            ("clipboard_too_long", seed(0, 0, long_clipboard)),
            ("carrier_too_long", seed(0, 0, Self::piece(self.drdynvc, u32::MAX, 1, &[0x30, 1, 2, 3]))),
            ("dynamic_too_long", seed(0, 0, long_dynamic)),
            ("bitmap", seed(2, 0, fast_path(&[(1, bitmap.clone()), (3, Vec::new())]))),
            ("surface", seed(1, 0x3f, fast_path(&[(4, surface(4, 0)), (1, bitmap), (3, Vec::new())]))),
            ("surface_remotefx", seed(1, 0, fast_path(&[(4, surface(4, 3))]))),
            // What the first run of this target found: an empty destination (IronRDP took 1 off
            // its right edge unchecked; vendor/ironrdp-session/NOTICE-ZESTSSH).
            ("surface_empty", seed(1, 0, fast_path(&[(4, surface(0, 0))]))),
            (
                "pointers",
                seed(0, 1, fast_path(&[(8, [le16(5), le16(7)].concat()), (5, Vec::new()), (6, Vec::new()), (0x0b, pointer)])),
            ),
            ("resize", seed(0, 0x20, [deactivate, self.from_capabilities().to_vec()].concat())),
            (
                "error_then_end",
                seed(0, 0, [self.share_data(0x2f, &1u32.to_le_bytes()), b"\x03\x00\x00\x09\x02\xf0\x80\x21\x80".to_vec()].concat()),
            ),
            (
                "display_control",
                seed(0, 0x20, [self.dynamic_open(1, display), self.dynamic(&[&[0x30, 1][..], &display_caps].concat())].concat()),
            ),
            ("graphics", seed(0, 0x18, gfx)),
        ]
    }
}

/// Fails the run if [handshake] no longer signs the session in, for each kind of graphics (a
/// target that puts it first would otherwise fuzz nothing past the sign-in without anyone
/// seeing). Once a process.
pub fn check() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        for pick in 0..3u8 {
            let connected = super::ffi::session(request(pick, false).as_bytes(), handshake(), 0);
            assert!(connected, "the made sign-in no longer connects (graphics {pick})");
        }
    });
}

/// With `ZEST_FUZZ_SEEDS` naming the corpus folder: writes the seeds only this code can make
/// (they hold the made sign-ins) and ends the process. `fuzz/run.sh seeds` runs a target so.
pub fn write_seeds_if_asked() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let Ok(corpus) = std::env::var("ZEST_FUZZ_SEEDS") else { return };
        let write = |target: &str, name: &str, data: &[u8]| {
            let dir = std::path::Path::new(&corpus).join(target);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join(name), data).unwrap();
        };
        let with = |first: &[u8], rest: &[u8]| [first, rest].concat();
        let name = |n: &str| format!("seed-{n}");
        let write = |target: &str, n: &str, data: &[u8]| write(target, &name(n), data);
        let (tls, nla) = (handshake(), nla_handshake());
        // rdp_connector: a pick byte (its fifth bit: a host without NLA), then the server from
        // its Connection Confirm.
        write("rdp_connector", "tls_whole", &with(&[16], tls));
        write("rdp_connector", "tls_bitmap_domain", &with(&[22], tls));
        write("rdp_connector", "tls_confirm_only", &with(&[16], &tls[..19]));
        write("rdp_connector", "tls_half", &with(&[17], &tls[..tls.len() / 2]));
        write("rdp_connector", "nla_whole", &with(&[0], nla));
        // What a session refuses: TLS alone picked where NLA was asked for, and the other way.
        write("rdp_connector", "tls_picked_nla_asked", &with(&[0], tls));
        write("rdp_connector", "nla_picked_tls_asked", &with(&[16], nla));
        // rdp_credssp: a pick byte (its fourth bit: the early result), then CredSSP's messages.
        write("rdp_credssp", "whole", &with(&[0], &nla[19..]));
        write("rdp_credssp", "whole_early", &with(&[8], &nla[19..]));
        write("rdp_credssp", "first_message", &with(&[4], &nla[19..(19 + (nla.len() - 19) / 3).min(nla.len())]));
        // rdp_session: what a server sends after the sign-in (the target puts the sign-in first).
        // The graphics pipeline's messages are seeds.py's (corpus/rdp_gfx/seed-frame), sent on
        // the channel as a server would.
        let gfx = std::fs::read(std::path::Path::new(&corpus).join("rdp_gfx").join("seed-frame")).unwrap_or_default();
        if gfx.is_empty() {
            eprintln!("no corpus/rdp_gfx/seed-frame (run seeds.py first): the graphics seed only opens the channel");
        }
        check();
        for (n, seed) in made(false).session_seeds(&gfx) {
            write("rdp_session", n, &seed);
            // How the session took it: a seed it reads to the end closes with the channel's end.
            let server = [handshake(), &seed[2..]].concat();
            let connected = super::ffi::session(request(seed[0], false).as_bytes(), &server, seed[1]);
            eprintln!("rdp_session seed-{n} ({} bytes, connected {connected}): {}", seed.len(), super::ffi::last_closed());
        }
        eprintln!("seeds with the made sign-ins written under {corpus} (TLS {} bytes, NLA {} bytes)", tls.len(), nla.len());
        std::process::exit(0);
    });
}
