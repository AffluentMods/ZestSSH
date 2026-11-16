//! FTPS (3.4): FTP over TLS with suppaftp and rustls, for the app's file browser.
//!
//! Plain FTP is never spoken: a server that refuses `AUTH TLS` is left before the user name or the
//! password is sent, and data always goes encrypted (`PROT P`), never `PROT C` or `CCC`. The
//! certificate check is [`verify`]'s, on the control connection and on every data connection.
//!
//! Each connection is a handle: a number the app holds, with the control connection behind it.
//! Calls block (FTP is one command at a time on a connection), so the app makes them off its UI
//! thread; calls on one handle wait for each other. A transfer's progress and its cancel are read
//! and set beside a running call, without waiting for it.

pub mod listing;
pub mod verify;

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use rustls::ClientConfig;
use rustls::crypto::ring;
use serde::Serialize;
use serde_json::{Value, json};
use suppaftp::types::FileType;
use suppaftp::{DataStream, FtpError, Mode, RustlsConnector, RustlsFtpStream, Status, TlsConnector, TlsStream};

use verify::{Policy, Seen, ZestVerifier};

/// A connection's control channel and what the server said it can do.
struct Session {
    ftp: RustlsFtpStream,
    features: Features,
}

#[derive(Clone, Copy, Debug, Default, Serialize)]
struct Features {
    mlst: bool,
    epsv: bool,
    rest: bool,
    utf8: bool,
    /// `HASH` with SHA-256, or `XSHA256`: a server that can say a file's SHA-256.
    hash: bool,
    #[serde(skip)]
    hash_cmd: Option<HashCommand>,
}

#[derive(Clone, Copy, Debug)]
enum HashCommand {
    Hash,
    XSha256,
}

/// One connection the app holds.
pub struct Handle {
    session: Mutex<Option<Session>>,
    progress: AtomicU64,
    cancel: AtomicBool,
}

impl Drop for Session {
    fn drop(&mut self) {
        // QUIT, then the TLS close_notify as the stream drops (suppaftp sends it), so the server
        // sees a clean end rather than a reset.
        let _ = self.ftp.quit();
    }
}

fn registry() -> &'static Mutex<HashMap<u64, Arc<Handle>>> {
    static R: OnceLock<Mutex<HashMap<u64, Arc<Handle>>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

fn handle(id: u64) -> Option<Arc<Handle>> {
    registry().lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned()
}

/// A new handle, with no connection yet.
pub fn open() -> u64 {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let h = Arc::new(Handle { session: Mutex::new(None), progress: AtomicU64::new(0), cancel: AtomicBool::new(false) });
    registry().lock().unwrap_or_else(|e| e.into_inner()).insert(id, h);
    id
}

/// Ends the handle: its connection says QUIT and closes, once a call still running on it ends.
pub fn close(id: u64) {
    let h = registry().lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    if let Some(h) = h {
        h.cancel.store(true, Ordering::SeqCst);
        let session = h.session.lock().unwrap_or_else(|e| e.into_inner()).take();
        drop(session);
    }
}

/// Asks the transfer running on the handle to stop (it stops at its next block).
pub fn cancel(id: u64) {
    if let Some(h) = handle(id) {
        h.cancel.store(true, Ordering::SeqCst);
    }
}

/// Bytes moved so far by the transfer running on the handle (or the last one).
pub fn progress(id: u64) -> u64 {
    handle(id).map(|h| h.progress.load(Ordering::Relaxed)).unwrap_or(0)
}

/// Why a call failed, as the app reads it.
#[derive(Debug)]
pub struct OpError {
    kind: &'static str,
    message: String,
    code: Option<u32>,
    certificate: Option<Seen>,
}

impl OpError {
    fn new(kind: &'static str, message: impl Into<String>) -> Self {
        Self { kind, message: message.into(), code: None, certificate: None }
    }

    fn to_json(&self) -> Value {
        let mut e = json!({ "kind": self.kind, "message": self.message });
        if let Some(c) = self.code {
            e["code"] = json!(c);
        }
        if let Some(s) = &self.certificate {
            e["certificate"] = certificate_json(s);
        }
        json!({ "error": e })
    }
}

fn certificate_json(s: &Seen) -> Value {
    json!({ "sha256": hex(&s.sha256), "byAuthority": s.by_authority, "der": hex(&s.der) })
}

fn hex(bytes: &[u8]) -> String {
    const D: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(D[(b >> 4) as usize] as char);
        s.push(D[(b & 15) as usize] as char);
    }
    s
}

fn unhex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = (hi * 16 + lo) as u8;
    }
    Some(out)
}

impl From<FtpError> for OpError {
    fn from(e: FtpError) -> Self {
        match e {
            FtpError::ConnectionError(io) => io_error(&io),
            FtpError::SecureError(m) => OpError::new("tls", m),
            FtpError::UnexpectedResponse(r) => {
                let text = String::from_utf8_lossy(&r.body).trim().to_string();
                let code = r.status.code();
                let kind = match code {
                    530 => "login",
                    _ => "reply",
                };
                OpError { kind, message: text, code: Some(code), certificate: None }
            }
            FtpError::BadResponse => OpError::new("protocol", "the server's reply could not be read"),
            FtpError::InvalidAddress(a) => OpError::new("protocol", a.to_string()),
            FtpError::DataConnectionAlreadyOpen => OpError::new("busy", "a transfer is already running"),
        }
    }
}

fn io_error(io: &std::io::Error) -> OpError {
    use std::io::ErrorKind::*;
    let kind = match io.kind() {
        TimedOut | WouldBlock => "timeout",
        ConnectionRefused => "refused",
        _ => "connection",
    };
    let mut e = OpError::new(kind, io.to_string());
    // A refused certificate fails the handshake inside an I/O error.
    if io.to_string().contains(verify::CERT_REFUSED) {
        e.kind = "certificate";
    }
    e
}

type OpResult = Result<Value, OpError>;

/// Runs one request (JSON, `{"op": ...}`) on handle [id]; the answer is `{"ok": ...}` or
/// `{"error": {"kind", "message", "code"?, "certificate"?}}`.
pub fn call(id: u64, request: &str) -> String {
    let answer = match serde_json::from_str::<Value>(request) {
        Err(e) => OpError::new("request", e.to_string()).to_json(),
        Ok(req) => match handle(id) {
            None => OpError::new("closed", "this connection is closed").to_json(),
            Some(h) => match run(&h, &req) {
                Ok(v) => json!({ "ok": v }),
                Err(e) => e.to_json(),
            },
        },
    };
    answer.to_string()
}

fn str_arg<'a>(req: &'a Value, key: &str) -> Result<&'a str, OpError> {
    req.get(key).and_then(Value::as_str).ok_or_else(|| OpError::new("request", format!("{key} is missing")))
}

fn u64_arg(req: &Value, key: &str) -> u64 {
    req.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn run(h: &Handle, req: &Value) -> OpResult {
    let op = str_arg(req, "op")?;
    let mut guard = h.session.lock().unwrap_or_else(|e| e.into_inner());
    if op == "connect" {
        // A handle connects once; a new connection is a new handle.
        if guard.is_some() {
            return Err(OpError::new("request", "already connected"));
        }
        h.cancel.store(false, Ordering::SeqCst);
        let (session, answer) = connect(req)?;
        *guard = session;
        return Ok(answer);
    }
    let session = guard.as_mut().ok_or_else(|| OpError::new("closed", "not connected"))?;
    let ftp = &mut session.ftp;
    match op {
        "pwd" => Ok(json!(ftp.pwd()?)),
        "noop" => {
            ftp.noop()?;
            Ok(Value::Null)
        }
        "list" => {
            h.cancel.store(false, Ordering::SeqCst);
            list(h, session, str_arg(req, "path")?)
        }
        "stat" => {
            h.cancel.store(false, Ordering::SeqCst);
            stat(h, session, str_arg(req, "path")?)
        }
        "mkdir" => {
            ftp.mkdir(str_arg(req, "path")?)?;
            Ok(Value::Null)
        }
        "rmdir" => {
            ftp.rmdir(str_arg(req, "path")?)?;
            Ok(Value::Null)
        }
        "delete" => {
            ftp.rm(str_arg(req, "path")?)?;
            Ok(Value::Null)
        }
        "rename" => {
            ftp.rename(str_arg(req, "from")?, str_arg(req, "to")?)?;
            Ok(Value::Null)
        }
        "size" => Ok(json!(ftp.size(str_arg(req, "path")?)? as u64)),
        "sha256" => sha256(session, str_arg(req, "path")?),
        "chmod" => {
            let mode = u64_arg(req, "mode");
            if mode > 0o7777 {
                return Err(OpError::new("request", "bad mode"));
            }
            ftp.site(format!("CHMOD {mode:o} {}", str_arg(req, "path")?))?;
            Ok(Value::Null)
        }
        "read" => read(ftp, str_arg(req, "path")?, req.get("maxBytes").and_then(Value::as_u64)),
        "write" => write(ftp, str_arg(req, "path")?, str_arg(req, "data")?),
        "get" => {
            h.cancel.store(false, Ordering::SeqCst);
            h.progress.store(0, Ordering::SeqCst);
            get(h, ftp, str_arg(req, "remote")?, str_arg(req, "local")?, u64_arg(req, "offset"), req.get("maxBytes").and_then(Value::as_u64))
        }
        "put" => {
            h.cancel.store(false, Ordering::SeqCst);
            h.progress.store(0, Ordering::SeqCst);
            put(h, ftp, str_arg(req, "local")?, str_arg(req, "remote")?, u64_arg(req, "offset"))
        }
        "quit" => {
            // Dropping the session says QUIT and sends close_notify.
            *guard = None;
            Ok(Value::Null)
        }
        other => Err(OpError::new("request", format!("unknown op {other}"))),
    }
}

/// The TLS connector of one connection: rustls with our certificate check, and the socket's time
/// limits set before each handshake (the control connection's and every data connection's).
#[derive(Clone, Debug)]
struct Connector {
    config: Arc<ClientConfig>,
    io_timeout: Duration,
    started: Arc<AtomicBool>,
    /// Set when the caller stopped waiting for the TCP connect (implicit TLS): a socket that
    /// connects after that gets no TLS and no greeting read; it is dropped.
    abandoned: Arc<AtomicBool>,
}

impl TlsConnector for Connector {
    type Stream = <RustlsConnector as TlsConnector>::Stream;

    fn connect(&self, domain: &str, stream: TcpStream) -> suppaftp::FtpResult<Self::Stream> {
        if self.abandoned.load(Ordering::SeqCst) {
            return Err(FtpError::SecureError("abandoned: the TCP connect took longer than allowed".to_string()));
        }
        self.started.store(true, Ordering::SeqCst);
        stream.set_read_timeout(Some(self.io_timeout)).map_err(FtpError::ConnectionError)?;
        stream.set_write_timeout(Some(self.io_timeout)).map_err(FtpError::ConnectionError)?;
        let _ = stream.set_nodelay(true);
        RustlsConnector::from(self.config.clone()).connect(domain, stream)
    }
}

/// How often [connect_implicit_within] looks whether the TCP connect is done.
const CONNECT_POLL: Duration = Duration::from_millis(20);

/// suppaftp's implicit TLS connect, with a time limit on its TCP connect, which suppaftp leaves to
/// the system (minutes on some): `connect_secure_implicit` connects the socket itself, with no way
/// to give it one made here, so it runs on a thread of its own, and if TLS has not begun by
/// [limit] (the connector's `started`, set as the handshake starts), the wait ends with a timeout.
/// The thread then finds `abandoned` set if the socket connects later, and drops it with no TLS.
/// Once TLS has begun, the socket's own read and write time limits bound the rest.
fn connect_implicit_within(
    addr: SocketAddr,
    connector: &Connector,
    domain: &str,
    limit: Duration,
) -> Result<RustlsFtpStream, OpError> {
    let mine = Connector {
        config: connector.config.clone(),
        io_timeout: connector.io_timeout,
        started: Arc::new(AtomicBool::new(false)),
        abandoned: Arc::new(AtomicBool::new(false)),
    };
    let started = mine.started.clone();
    let abandoned = mine.abandoned.clone();
    let shared_started = connector.started.clone();
    let domain = domain.to_string();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(RustlsFtpStream::connect_secure_implicit(addr, mine, &domain));
    });
    let began = std::time::Instant::now();
    loop {
        match rx.recv_timeout(CONNECT_POLL) {
            Ok(r) => {
                if started.load(Ordering::SeqCst) {
                    shared_started.store(true, Ordering::SeqCst);
                }
                return r.map_err(OpError::from);
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return Err(OpError::new("connection", "the connect thread ended"));
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if started.load(Ordering::SeqCst) {
                    shared_started.store(true, Ordering::SeqCst);
                    // TLS has begun: the socket's own time limits end it.
                    continue;
                }
                if began.elapsed() >= limit {
                    abandoned.store(true, Ordering::SeqCst);
                    // The handshake may have begun just now; if so, it is the socket's to end.
                    if started.load(Ordering::SeqCst) {
                        continue;
                    }
                    return Err(OpError::new("timeout", format!("no TCP connection to {addr} within {} ms", limit.as_millis())));
                }
            }
        }
    }
}

fn connect(req: &Value) -> Result<(Option<Session>, Value), OpError> {
    let host = str_arg(req, "host")?;
    let port = u64_arg(req, "port");
    let port = u16::try_from(port).ok().filter(|p| *p > 0).ok_or_else(|| OpError::new("request", "bad port"))?;
    let implicit = req.get("implicit").and_then(Value::as_bool).unwrap_or(false);
    let user = str_arg(req, "user")?;
    let password = req.get("password").and_then(Value::as_str).unwrap_or("");
    let timeout = Duration::from_millis(u64_arg(req, "timeoutMs").clamp(1000, 300_000));
    let pinned = match req.get("pinned").and_then(Value::as_str) {
        Some(s) => Some(unhex32(s).ok_or_else(|| OpError::new("request", "pinned is not a SHA-256"))?),
        None => None,
    };
    let allow_authority = req.get("allowAuthority").and_then(Value::as_bool).unwrap_or(true);
    // The host editor's TLS test (3.4, stage 2): TLS and the certificate's check, then QUIT, with
    // no user name and no password sent; the handle stays unconnected.
    let login = req.get("login").and_then(Value::as_bool).unwrap_or(true);

    // A host typed as [::1] is ::1 to the resolver and to the certificate check.
    let domain = host.trim_start_matches('[').trim_end_matches(']').to_string();
    let addrs: Vec<SocketAddr> = (domain.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| OpError::new("resolve", e.to_string()))?
        .collect();
    if addrs.is_empty() {
        return Err(OpError::new("resolve", format!("{domain} has no address")));
    }

    let provider = Arc::new(ring::default_provider());
    let verifier = Arc::new(
        ZestVerifier::new(provider.clone(), Policy { pinned, allow_authority }).map_err(|e| OpError::new("tls", e))?,
    );
    // The default config resumes sessions from an in-memory cache, by server name: what makes
    // each data connection resume the control connection's session (vsftpd, ProFTPD).
    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| OpError::new("tls", e.to_string()))?
        .dangerous()
        .with_custom_certificate_verifier(verifier.clone())
        .with_no_client_auth();
    let started = Arc::new(AtomicBool::new(false));
    let connector = Connector {
        config: Arc::new(config),
        io_timeout: timeout,
        started: started.clone(),
        abandoned: Arc::new(AtomicBool::new(false)),
    };
    let with_cert = |mut e: OpError| {
        if let Some(seen) = verifier.refused() {
            e.kind = "certificate";
            e.message = "the server's certificate is not trusted".to_string();
            e.certificate = Some(seen);
        }
        e
    };

    let mut ftp = if implicit {
        // Implicit TLS (port 990): TLS from the first byte.
        let mut last = None;
        let mut made = None;
        for addr in &addrs {
            match connect_implicit_within(*addr, &connector, &domain, timeout) {
                Ok(f) => {
                    made = Some(f);
                    break;
                }
                Err(e) => {
                    let e = with_cert(OpError::from(e));
                    if e.kind == "certificate" {
                        return Err(e);
                    }
                    last = Some(e);
                }
            }
        }
        let mut ftp = made.ok_or_else(|| last.unwrap_or_else(|| OpError::new("connection", "no address answered")))?;
        ftp.custom_command("PBSZ 0", &[Status::CommandOk]).map_err(|e| with_cert(e.into()))?;
        ftp.custom_command("PROT P", &[Status::CommandOk]).map_err(|e| with_cert(e.into()))?;
        ftp
    } else {
        // Explicit TLS (port 21): the greeting in clear, then AUTH TLS before anything else.
        let mut last = None;
        let mut tcp = None;
        for addr in &addrs {
            match TcpStream::connect_timeout(addr, timeout) {
                Ok(s) => {
                    tcp = Some(s);
                    break;
                }
                Err(e) => last = Some(io_error(&e)),
            }
        }
        let tcp = tcp.ok_or_else(|| last.unwrap_or_else(|| OpError::new("connection", "no address answered")))?;
        tcp.set_read_timeout(Some(timeout)).map_err(|e| io_error(&e))?;
        tcp.set_write_timeout(Some(timeout)).map_err(|e| io_error(&e))?;
        let plain = RustlsFtpStream::connect_with_stream(tcp)?;
        match plain.into_secure(connector, &domain) {
            Ok(f) => f,
            Err(e) => {
                let e = with_cert(OpError::from(e));
                if e.kind == "certificate" || started.load(Ordering::SeqCst) {
                    return Err(e);
                }
                // Refused before TLS began: plain FTP is never spoken, and nothing (no user
                // name, no password) was sent. The connection closes as `plain` drops.
                return Err(OpError { kind: "no-tls", message: e.message, code: e.code, certificate: None });
            }
        }
    };

    if !login {
        let accepted = verifier.accepted().ok_or_else(|| OpError::new("tls", "no certificate was checked"))?;
        let welcome = ftp.get_welcome_msg().unwrap_or("").to_string();
        let _ = ftp.quit();
        let answer = json!({
            "certificate": certificate_json(&accepted),
            "home": "",
            "welcome": welcome,
            "features": Features::default(),
        });
        return Ok((None, answer));
    }

    let passive_timeout = timeout;
    ftp = ftp.passive_stream_builder(move |addr| {
        TcpStream::connect_timeout(&addr, passive_timeout).map_err(FtpError::ConnectionError)
    });
    ftp.login(user, password).map_err(|e| with_cert(e.into()))?;
    ftp.transfer_type(FileType::Binary)?;

    let features = features_of(&mut ftp);
    if features.utf8 {
        let _ = ftp.opts("UTF8", Some("ON"));
    }
    if features.epsv {
        ftp.set_mode(Mode::ExtendedPassive);
    } else {
        // The address in a PASV reply is ignored for the control connection's own: behind NAT a
        // server names a private address, and following one elsewhere is FTP bounce.
        ftp.set_mode(Mode::Passive);
        ftp.set_passive_nat_workaround(true);
    }
    let home = ftp.pwd().unwrap_or_else(|_| "/".to_string());
    let welcome = ftp.get_welcome_msg().unwrap_or("").to_string();
    let accepted = verifier.accepted().ok_or_else(|| OpError::new("tls", "no certificate was checked"))?;
    let answer = json!({
        "certificate": certificate_json(&accepted),
        "home": home,
        "welcome": welcome,
        "features": features,
    });
    Ok((Some(Session { ftp, features }), answer))
}

fn features_of(ftp: &mut RustlsFtpStream) -> Features {
    let mut f = Features::default();
    let Ok(feat) = ftp.feat() else { return f };
    for (name, value) in &feat {
        match name.to_ascii_uppercase().as_str() {
            "MLST" => f.mlst = true,
            "EPSV" => f.epsv = true,
            "REST" => f.rest = true,
            "UTF8" => f.utf8 = true,
            "HASH" if value.as_deref().unwrap_or("").to_ascii_uppercase().contains("SHA-256") => {
                f.hash_cmd = Some(HashCommand::Hash)
            }
            "XSHA256" if f.hash_cmd.is_none() => f.hash_cmd = Some(HashCommand::XSha256),
            _ => {}
        }
    }
    f.hash = f.hash_cmd.is_some();
    f
}

/// What one folder's listing may be: the server decides what it sends, and all of it is held in
/// memory (and then several times more, on its way to the app as text). Past any of these the
/// listing is given up and the call says `too-large`. A line is one entry: its name (255 bytes
/// on most file systems, each of which may be written as more) and its facts. A folder of
/// [LISTING_MAX_LINES] entries is far past what a file browser shows.
const LISTING_MAX_LINE: usize = 16 * 1024;
const LISTING_MAX_LINES: usize = 200_000;
const LISTING_MAX_BYTES: usize = 32 * 1024 * 1024;

/// The lines of a listing read from its data connection, without their line ends, the empty
/// ones left out, as text (a byte that is no UTF-8 becomes the replacement character). Stops
/// with `too-large` past [LISTING_MAX_LINE], [LISTING_MAX_LINES] or [LISTING_MAX_BYTES], and
/// with `cancelled` once [cancel] is set, looked at before each read.
///
/// (suppaftp's own `list` and `mlsd` read the whole answer, whatever its size, with no way to
/// stop them: a server could make the app take memory until the system ended it, and neither
/// Cancel nor closing the tab reached the call. Found in a review before 4.0.)
fn listing_lines<R: Read>(stream: &mut R, cancel: &AtomicBool) -> Result<Vec<String>, OpError> {
    fn too_large() -> OpError {
        OpError::new("too-large", "the folder's listing is larger than allowed here")
    }
    /// Ends the line gathered so far; false where it is longer than a line may be.
    fn end_line(lines: &mut Vec<String>, line: &mut Vec<u8>) -> bool {
        let bytes = line.strip_suffix(b"\r").unwrap_or(line);
        if bytes.len() > LISTING_MAX_LINE {
            return false;
        }
        if !bytes.is_empty() {
            lines.push(String::from_utf8_lossy(bytes).into_owned());
        }
        line.clear();
        true
    }
    let mut lines: Vec<String> = Vec::new();
    let mut line: Vec<u8> = Vec::new();
    let mut total: usize = 0;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        if cancel.load(Ordering::SeqCst) {
            return Err(OpError::new("cancelled", "cancelled"));
        }
        let n = match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => return Err(io_error(&e)),
        };
        total += n;
        if total > LISTING_MAX_BYTES {
            return Err(too_large());
        }
        for &b in &buf[..n] {
            if b == b'\n' {
                if !end_line(&mut lines, &mut line) || lines.len() > LISTING_MAX_LINES {
                    return Err(too_large());
                }
            } else {
                // One more than a line may be: the carriage return of its end.
                if line.len() > LISTING_MAX_LINE {
                    return Err(too_large());
                }
                line.push(b);
            }
        }
    }
    // A last line with no line end.
    if !end_line(&mut lines, &mut line) || lines.len() > LISTING_MAX_LINES {
        return Err(too_large());
    }
    Ok(lines)
}

/// Why a listing command gave no lines: what the server said to the command (which the caller
/// may answer with another command), or what stopped the reading of it.
enum ListingFailure {
    Refused(FtpError),
    Stopped(OpError),
}

impl From<ListingFailure> for OpError {
    fn from(f: ListingFailure) -> Self {
        match f {
            ListingFailure::Refused(e) => e.into(),
            ListingFailure::Stopped(e) => e,
        }
    }
}

/// Sends [command] (MLSD or LIST) and reads its answer from the data connection within the
/// limits of [listing_lines]. A listing given up (too large, cancelled) is aborted, so that the
/// control connection is left in step for the next command.
fn data_lines(h: &Handle, ftp: &mut RustlsFtpStream, command: String) -> Result<Vec<String>, ListingFailure> {
    let (_, mut stream) = ftp
        .custom_data_command(command, &[Status::AboutToSend, Status::AlreadyOpen])
        .map_err(ListingFailure::Refused)?;
    match listing_lines(&mut stream, &h.cancel) {
        Ok(lines) => {
            stream.finish().map_err(ListingFailure::Refused)?;
            Ok(lines)
        }
        Err(e) => {
            if matches!(e.kind, "too-large" | "cancelled") {
                let _ = ftp.abort(stream);
            }
            Err(ListingFailure::Stopped(e))
        }
    }
}

fn list(h: &Handle, session: &mut Session, path: &str) -> OpResult {
    let entries: Vec<listing::Entry> = if session.features.mlst {
        data_lines(h, &mut session.ftp, format!("MLSD {path}"))?.iter().filter_map(|l| listing::parse_mlsd(l)).collect()
    } else {
        // LIST of a path is read by some servers as `ls` options and arguments: go there and list
        // the working folder instead, asking for dot files (`-a`, which vsftpd and Pure-FTPd take)
        // and without it where the server refuses that.
        session.ftp.cwd(path)?;
        let lines = match data_lines(h, &mut session.ftp, "LIST -a".to_string()) {
            Ok(l) => l,
            Err(ListingFailure::Refused(FtpError::UnexpectedResponse(_))) => {
                data_lines(h, &mut session.ftp, "LIST".to_string())?
            }
            Err(e) => return Err(e.into()),
        };
        lines.iter().filter_map(|l| listing::parse_list(l)).collect()
    };
    Ok(json!(entries))
}

fn stat(h: &Handle, session: &mut Session, path: &str) -> OpResult {
    if path == "/" {
        return Ok(json!(listing::Entry {
            name: "/".into(),
            dir: true,
            link: false,
            size: 0,
            mtime: None,
            mode: None,
            target: None,
        }));
    }
    if session.features.mlst {
        return match session.ftp.mlst(Some(path)) {
            Ok(line) => {
                // MLST names the path in full: the entry keeps the last part as its name.
                let mut e = listing::parse_mlsd(&line).ok_or_else(|| OpError::new("protocol", "unreadable MLST"))?;
                e.name = path.trim_end_matches('/').rsplit('/').next().unwrap_or(path).to_string();
                Ok(json!(e))
            }
            Err(FtpError::UnexpectedResponse(r)) if r.status.code() == 550 => Ok(Value::Null),
            Err(e) => Err(e.into()),
        };
    }
    // Without MLST: the entry in its folder's listing.
    let trimmed = path.trim_end_matches('/');
    let (parent, name) = match trimmed.rfind('/') {
        Some(0) => ("/", &trimmed[1..]),
        Some(i) => (&trimmed[..i], &trimmed[i + 1..]),
        None => (".", trimmed),
    };
    let listed = match list(h, session, parent) {
        Ok(v) => v,
        Err(e) if e.code == Some(550) => return Ok(Value::Null),
        Err(e) => return Err(e),
    };
    let found = listed.as_array().and_then(|a| a.iter().find(|e| e["name"] == name)).cloned();
    Ok(found.unwrap_or(Value::Null))
}

fn sha256(session: &mut Session, path: &str) -> OpResult {
    let reply = match session.features.hash_cmd {
        None => return Ok(Value::Null),
        Some(HashCommand::Hash) => {
            session.ftp.custom_command("OPTS HASH SHA-256", &[Status::CommandOk])?;
            session.ftp.custom_command(format!("HASH {path}"), &[Status::File])?
        }
        Some(HashCommand::XSha256) => {
            session.ftp.custom_command(format!("XSHA256 {path}"), &[Status::File, Status::RequestedFileActionOk])?
        }
    };
    let text = String::from_utf8_lossy(&reply.body).to_string();
    Ok(listing::sha256_in_reply(&text).map(Value::String).unwrap_or(Value::Null))
}

/// RETR [path] into memory (a file the editor opens): no more than [max_bytes] of it, held
/// against what comes, not against what the server says the size is. Base64 in the answer, so
/// nothing of it is written to this device's disk.
fn read(ftp: &mut RustlsFtpStream, path: &str, max_bytes: Option<u64>) -> OpResult {
    use base64::Engine as _;
    let mut stream = ftp.retr_as_stream(path)?;
    let mut out = Vec::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => return Err(io_error(&e)),
        };
        if max_bytes.is_some_and(|m| (out.len() + n) as u64 > m) {
            let _ = ftp.abort(stream);
            return Err(OpError::new("too-large", "the file is larger than allowed here"));
        }
        out.extend_from_slice(&buf[..n]);
    }
    stream.finish()?;
    Ok(json!({ "data": base64::engine::general_purpose::STANDARD.encode(&out) }))
}

/// STOR [data] (base64) to [path], from memory.
fn write(ftp: &mut RustlsFtpStream, path: &str, data: &str) -> OpResult {
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| OpError::new("request", e.to_string()))?;
    let mut stream = ftp.put_with_stream(path)?;
    if let Err(e) = stream.write_all(&bytes) {
        return Err(io_error(&e));
    }
    stream.flush().map_err(|e| io_error(&e))?;
    end_upload(&mut stream, UPLOAD_END_WAIT);
    stream.finish()?;
    Ok(json!({ "bytes": bytes.len() }))
}

const BLOCK: usize = 256 * 1024;

/// How long an upload's end waits for the server to close its side.
const UPLOAD_END_WAIT: Duration = Duration::from_secs(5);

/// RETR [remote] into [local], from [offset] on (REST): the bytes past what [local] holds already
/// are appended to it. Stops at [max_bytes] received, if given.
fn get(h: &Handle, ftp: &mut RustlsFtpStream, remote: &str, local: &str, offset: u64, max_bytes: Option<u64>) -> OpResult {
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(offset == 0)
        .open(local)
        .map_err(|e| OpError::new("local", e.to_string()))?;
    if offset > 0 {
        let len = file.metadata().map_err(|e| OpError::new("local", e.to_string()))?.len();
        if len != offset {
            return Err(OpError::new("request", "the offset is not the local file's length"));
        }
        file.seek(SeekFrom::Start(offset)).map_err(|e| OpError::new("local", e.to_string()))?;
        ftp.resume_transfer(offset as usize)?;
    }
    let mut stream = ftp.retr_as_stream(remote)?;
    let mut buf = vec![0u8; BLOCK];
    let mut got: u64 = 0;
    loop {
        if h.cancel.load(Ordering::SeqCst) {
            let _ = ftp.abort(stream);
            return Err(OpError::new("cancelled", "cancelled"));
        }
        let n = match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => return Err(io_error(&e)),
        };
        got += n as u64;
        if max_bytes.is_some_and(|m| offset + got > m) {
            let _ = ftp.abort(stream);
            return Err(OpError::new("too-large", "the file is larger than allowed here"));
        }
        if let Err(e) = file.write_all(&buf[..n]) {
            let _ = ftp.abort(stream);
            return Err(OpError::new("local", e.to_string()));
        }
        h.progress.store(got, Ordering::Relaxed);
    }
    stream.finish()?;
    file.flush().map_err(|e| OpError::new("local", e.to_string()))?;
    file.sync_all().map_err(|e| OpError::new("local", e.to_string()))?;
    Ok(json!({ "bytes": got }))
}

/// STOR [local] to [remote]; from [offset] on, REST then STOR, or APPE where the server does not
/// take REST before STOR (offset is then what [remote] holds already).
fn put(h: &Handle, ftp: &mut RustlsFtpStream, local: &str, remote: &str, offset: u64) -> OpResult {
    let mut file = File::open(local).map_err(|e| OpError::new("local", e.to_string()))?;
    let mut stream = if offset > 0 {
        file.seek(SeekFrom::Start(offset)).map_err(|e| OpError::new("local", e.to_string()))?;
        ftp.resume_transfer(offset as usize)?;
        match ftp.put_with_stream(remote) {
            Ok(s) => s,
            // 500 to 504: REST or STOR from an offset not understood; append instead.
            Err(FtpError::UnexpectedResponse(r)) if (500..=504).contains(&r.status.code()) => {
                ftp.append_with_stream(remote)?
            }
            Err(e) => return Err(e.into()),
        }
    } else {
        ftp.put_with_stream(remote)?
    };
    let mut buf = vec![0u8; BLOCK];
    let mut sent: u64 = 0;
    loop {
        if h.cancel.load(Ordering::SeqCst) {
            let _ = ftp.abort(stream);
            return Err(OpError::new("cancelled", "cancelled"));
        }
        let n = match file.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                let _ = ftp.abort(stream);
                return Err(OpError::new("local", e.to_string()));
            }
        };
        if let Err(e) = stream.write_all(&buf[..n]) {
            return Err(io_error(&e));
        }
        sent += n as u64;
        h.progress.store(sent, Ordering::Relaxed);
    }
    stream.flush().map_err(|e| io_error(&e))?;
    end_upload(&mut stream, UPLOAD_END_WAIT);
    // Closes the data connection with close_notify (vsftpd's strict_ssl_read_eof wants it) and
    // reads the server's 226.
    stream.finish()?;
    Ok(json!({ "bytes": sent }))
}

/// Ends an upload's data connection with a TLS close both ways, before suppaftp closes it.
///
/// The close_notify goes first, then the socket's write side, and what the server sends until it
/// closes its side is read through TLS. That ends the file cleanly for a server that wants a TLS
/// end to an upload (vsftpd's strict_ssl_read_eof: without one it answers "426 Failure reading
/// network stream"), and it takes in the TLS 1.3 session ticket the server gave on this
/// connection, which nothing else reads on an upload: rustls uses each ticket once, so without
/// them a connection ran out after a couple of uploads, and the next data connection could not
/// resume the session ("522 SSL connection failed: session reuse required").
fn end_upload<T>(stream: &mut suppaftp::TransferStream<T>, wait: Duration)
where
    T: TlsStream<InnerStream = rustls::StreamOwned<rustls::ClientConnection, TcpStream>>,
{
    let DataStream::Ssl(tls) = stream.get_mut() else { return };
    let s = tls.mut_ref();
    s.conn.send_close_notify();
    while s.conn.wants_write() {
        if s.conn.write_tls(&mut s.sock).is_err() {
            return;
        }
    }
    let _ = s.sock.flush();
    let _ = s.sock.shutdown(std::net::Shutdown::Write);
    let before = s.sock.read_timeout().ok().flatten();
    if s.sock.set_read_timeout(Some(wait)).is_err() {
        return;
    }
    let mut buf = [0u8; 4096];
    // Until the server's close_notify (0) or its end of the connection (an error).
    while matches!(s.read(&mut buf), Ok(n) if n > 0) {}
    let _ = s.sock.set_read_timeout(before);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trip() {
        let b = [0xabu8; 32];
        assert_eq!(unhex32(&hex(&b)), Some(b));
        assert_eq!(unhex32("zz"), None);
    }

    /// A reader that never ends: [piece] over and over.
    struct Endless(&'static [u8], usize);

    impl Read for Endless {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            for b in buf.iter_mut() {
                *b = self.0[self.1 % self.0.len()];
                self.1 += 1;
            }
            Ok(buf.len())
        }
    }

    #[test]
    fn a_listing_is_read_line_by_line() {
        let cancel = AtomicBool::new(false);
        let mut data: &[u8] = b"type=dir; a\r\ntype=file;size=3; b\n\r\n\ntype=file; caf\xe9\r\nlast";
        let lines = listing_lines(&mut data, &cancel).unwrap();
        assert_eq!(lines, vec!["type=dir; a", "type=file;size=3; b", "type=file; caf\u{fffd}", "last"]);
        let mut none: &[u8] = b"";
        assert!(listing_lines(&mut none, &cancel).unwrap().is_empty());
    }

    #[test]
    fn a_listing_line_that_never_ends_is_given_up() {
        let cancel = AtomicBool::new(false);
        let mut server = Endless(b"a", 0);
        let e = listing_lines(&mut server, &cancel).err().unwrap();
        assert_eq!(e.kind, "too-large");
        assert!(server.1 <= 2 * 64 * 1024, "read {} bytes of one line", server.1);
    }

    #[test]
    fn a_listing_of_lines_without_end_is_given_up() {
        let cancel = AtomicBool::new(false);
        // Short lines: the count of them is what stops it.
        let mut short = Endless(b"x\r\n", 0);
        let e = listing_lines(&mut short, &cancel).err().unwrap();
        assert_eq!(e.kind, "too-large");
        assert!(short.1 <= 3 * (LISTING_MAX_LINES + 1) + 64 * 1024, "read {} bytes", short.1);
        // Long ones: the bytes of them are.
        static LONG: [u8; 8001] = {
            let mut l = [b'n'; 8001];
            l[8000] = b'\n';
            l
        };
        let mut long = Endless(&LONG, 0);
        let e = listing_lines(&mut long, &cancel).err().unwrap();
        assert_eq!(e.kind, "too-large");
        assert!(long.1 <= LISTING_MAX_BYTES + 64 * 1024, "read {} bytes", long.1);
    }

    #[test]
    fn a_listing_at_its_limits_is_whole() {
        let cancel = AtomicBool::new(false);
        let mut line = vec![b'n'; LISTING_MAX_LINE];
        line.extend_from_slice(b"\r\n");
        let lines = listing_lines(&mut line.as_slice(), &cancel).unwrap();
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].len(), LISTING_MAX_LINE);
        let mut longer = vec![b'n'; LISTING_MAX_LINE + 1];
        longer.extend_from_slice(b"\n");
        assert_eq!(listing_lines(&mut longer.as_slice(), &cancel).err().unwrap().kind, "too-large");
        let many = b"e\n".repeat(LISTING_MAX_LINES);
        assert_eq!(listing_lines(&mut many.as_slice(), &cancel).unwrap().len(), LISTING_MAX_LINES);
    }

    #[test]
    fn a_cancelled_listing_stops_reading() {
        let cancel = AtomicBool::new(true);
        let mut server = Endless(b"x\n", 0);
        let e = listing_lines(&mut server, &cancel).err().unwrap();
        assert_eq!(e.kind, "cancelled");
        assert_eq!(server.1, 0, "nothing is read once it is cancelled");
    }

    #[test]
    fn an_unknown_handle_says_closed() {
        let a: Value = serde_json::from_str(&call(u64::MAX, r#"{"op":"pwd"}"#)).unwrap();
        assert_eq!(a["error"]["kind"], "closed");
    }

    #[test]
    fn a_handle_not_connected_says_so() {
        let id = open();
        let a: Value = serde_json::from_str(&call(id, r#"{"op":"list","path":"/"}"#)).unwrap();
        assert_eq!(a["error"]["kind"], "closed");
        close(id);
        let a: Value = serde_json::from_str(&call(id, r#"{"op":"list","path":"/"}"#)).unwrap();
        assert_eq!(a["error"]["kind"], "closed");
    }

    #[test]
    fn a_bad_request_says_so() {
        let id = open();
        let a: Value = serde_json::from_str(&call(id, "not json")).unwrap();
        assert_eq!(a["error"]["kind"], "request");
        let a: Value = serde_json::from_str(&call(id, r#"{"op":"connect","host":"x","port":0,"user":"u"}"#)).unwrap();
        assert_eq!(a["error"]["kind"], "request");
        close(id);
    }

    #[test]
    fn nothing_listening_is_refused_or_times_out() {
        // A port on this computer nobody listens on (bound, then let go).
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let id = open();
        let req = json!({"op":"connect","host":"127.0.0.1","port":port,"user":"u","password":"p","timeoutMs":2000});
        let a: Value = serde_json::from_str(&call(id, &req.to_string())).unwrap();
        let kind = a["error"]["kind"].as_str().unwrap().to_string();
        assert!(kind == "refused" || kind == "timeout" || kind == "connection", "{a}");
        close(id);
    }

    /// Implicit TLS's TCP connect is held to the time limit (suppaftp connects that socket itself,
    /// with the system's limit, minutes on some): an address that does not answer (TEST-NET-1,
    /// RFC 5737, routed nowhere) is given up at the limit, or refused sooner where the network
    /// says it is unreachable.
    #[test]
    fn implicit_tls_tcp_connect_is_held_to_the_time_limit() {
        let id = open();
        let req = json!({"op":"connect","host":"192.0.2.1","port":990,"implicit":true,"user":"u","password":"p","timeoutMs":1500});
        let began = std::time::Instant::now();
        let a: Value = serde_json::from_str(&call(id, &req.to_string())).unwrap();
        let took = began.elapsed();
        close(id);
        assert!(a.get("error").is_some(), "{a}");
        assert!(took < Duration::from_millis(1500 + 1000), "took {took:?}: {a}");
        if a["error"]["kind"] == "timeout" {
            assert!(a["error"]["message"].as_str().unwrap().contains("no TCP connection"), "{a}");
        }
    }

    /// A server that answers AUTH TLS with 502 (plain FTP only) is left before USER is sent.
    #[test]
    fn a_server_without_tls_gets_no_user_name() {
        use std::io::{BufRead, BufReader};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            s.write_all(b"220 plain FTP here\r\n").unwrap();
            let mut seen = Vec::new();
            let mut r = BufReader::new(s.try_clone().unwrap());
            loop {
                let mut line = String::new();
                if r.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                }
                seen.push(line.trim().to_string());
                if line.starts_with("AUTH") {
                    s.write_all(b"502 AUTH not implemented\r\n").unwrap();
                }
            }
            seen
        });
        let id = open();
        let req = json!({"op":"connect","host":"127.0.0.1","port":port,"user":"someone","password":"secret","timeoutMs":5000});
        let a: Value = serde_json::from_str(&call(id, &req.to_string())).unwrap();
        close(id);
        assert_eq!(a["error"]["kind"], "no-tls", "{a}");
        assert_eq!(a["error"]["code"], 502);
        let seen = server.join().unwrap();
        assert_eq!(seen, vec!["AUTH TLS".to_string()]);
    }
}
