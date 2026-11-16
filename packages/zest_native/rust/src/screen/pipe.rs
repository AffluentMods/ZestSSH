//! The byte pipe between Dart's SSH channel and a screen engine, and a small mailbox for input.
//! std only (a mutex and a waker), so it needs no tokio feature beyond the io traits.

use crate::screen::LockAnyway as _;
use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use super::{CloseReason, FEED_HIGH_MARK, FEED_LOW_MARK, Notifier, event};

/// How the channel under a session ended, as Dart said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportEnd {
    /// The channel's end came with no error: the other side closed it.
    Eof,
    /// The channel or the SSH connection failed: [CloseReason::Ssh] or [CloseReason::Network].
    Failed { reason: CloseReason, message: String },
}

#[derive(Default)]
struct Inbound {
    chunks: VecDeque<Vec<u8>>,
    /// Bytes of the first chunk already read.
    offset: usize,
    queued: usize,
    ended: Option<TransportEnd>,
    /// Dart was told to pause (a feed went over the high mark): tell it when it may resume.
    paused: bool,
    waker: Option<Waker>,
}

/// Bytes from Dart (what the SSH channel received), waiting for the engine.
pub struct Pipe {
    inbound: Mutex<Inbound>,
    notifier: Notifier,
}

impl Pipe {
    pub fn new(notifier: Notifier) -> Self {
        Self { inbound: Mutex::default(), notifier }
    }

    /// Adds bytes; returns how many wait now (Dart pauses its channel above [FEED_HIGH_MARK]
    /// and resumes on [event::DRAINED]).
    pub fn feed(&self, bytes: &[u8]) -> usize {
        let mut i = self.inbound.held();
        if !bytes.is_empty() && i.ended.is_none() {
            i.chunks.push_back(bytes.to_vec());
            i.queued += bytes.len();
        }
        if i.queued > FEED_HIGH_MARK {
            i.paused = true;
        }
        if let Some(w) = i.waker.take() {
            w.wake();
        }
        i.queued
    }

    /// The channel ended: the engine reads the end of the stream after what is queued.
    pub fn end(&self) {
        self.end_with(TransportEnd::Eof);
    }

    /// The channel ended this way: after what is queued, the engine reads the end of the stream
    /// ([TransportEnd::Eof]) or an error with the reason (the first end given counts).
    pub fn end_with(&self, end: TransportEnd) {
        let mut i = self.inbound.held();
        if i.ended.is_none() {
            i.ended = Some(end);
        }
        if let Some(w) = i.waker.take() {
            w.wake();
        }
    }

    pub fn transport_end(&self) -> Option<TransportEnd> {
        self.inbound.held().ended.clone()
    }

    pub fn queued(&self) -> usize {
        self.inbound.held().queued
    }

    fn poll_read(&self, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        let mut i = self.inbound.held();
        if i.chunks.is_empty() {
            match &i.ended {
                Some(TransportEnd::Eof) => return Poll::Ready(Ok(())),
                Some(TransportEnd::Failed { message, .. }) => {
                    return Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::ConnectionAborted, message.clone())));
                }
                None => {}
            }
            i.waker = Some(cx.waker().clone());
            return Poll::Pending;
        }
        while buf.remaining() > 0 {
            let offset = i.offset;
            let Some(front) = i.chunks.front() else { break };
            let n = (front.len() - offset).min(buf.remaining());
            buf.put_slice(&front[offset..offset + n]);
            let done = offset + n == front.len();
            i.queued -= n;
            if done {
                i.chunks.pop_front();
                i.offset = 0;
            } else {
                i.offset += n;
            }
        }
        if i.paused && i.queued < FEED_LOW_MARK {
            i.paused = false;
            let queued = i.queued as i64;
            drop(i);
            self.notifier.signal(event::DRAINED, queued);
        }
        Poll::Ready(Ok(()))
    }
}

/// The stream an engine runs on: reads what Dart fed, writes through the callback.
pub struct DartStream {
    pub pipe: Arc<Pipe>,
    pub notifier: Notifier,
}

impl DartStream {
    pub fn new(pipe: Arc<Pipe>, notifier: Notifier) -> Self {
        Self { pipe, notifier }
    }
}

impl AsyncRead for DartStream {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        self.pipe.poll_read(cx, buf)
    }
}

impl AsyncWrite for DartStream {
    fn poll_write(self: Pin<&mut Self>, _cx: &mut Context<'_>, data: &[u8]) -> Poll<std::io::Result<usize>> {
        if !data.is_empty() {
            self.notifier.bytes(event::SEND, 0, data.to_vec());
        }
        Poll::Ready(Ok(data.len()))
    }
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// Messages from any thread to the session's async loop.
pub struct Mailbox<T> {
    inner: Mutex<(VecDeque<T>, Option<Waker>)>,
}

impl<T> Default for Mailbox<T> {
    fn default() -> Self {
        Self { inner: Mutex::new((VecDeque::new(), None)) }
    }
}

impl<T> Mailbox<T> {
    pub fn push(&self, item: T) {
        let mut g = self.inner.held();
        g.0.push_back(item);
        if let Some(w) = g.1.take() {
            w.wake();
        }
    }

    /// The next message (cancel-safe: nothing is taken until it is returned).
    pub async fn recv(&self) -> T {
        std::future::poll_fn(|cx| {
            let mut g = self.inner.held();
            match g.0.pop_front() {
                Some(item) => Poll::Ready(item),
                None => {
                    g.1 = Some(cx.waker().clone());
                    Poll::Pending
                }
            }
        })
        .await
    }
}
