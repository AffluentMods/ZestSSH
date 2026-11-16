use crate::vnc::engine::{PixelFormat, Rect, VncEncoding, VncError};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

#[derive(Debug)]
pub(super) enum ClientMsg {
    SetPixelFormat(PixelFormat),
    SetEncodings(Vec<VncEncoding>),
    FramebufferUpdateRequest(Rect, u8),
    KeyEvent(u32, bool),
    PointerEvent(u16, u16, u8),
    ClientCutText(String),
    /// The extended clipboard's form of ClientCutText: flags and what follows them.
    ExtendedCutText(Vec<u8>),
    /// QEMU extended key event: down, keysym, XT scancode.
    QemuKey(bool, u32, u32),
    #[cfg(not(target_arch = "wasm32"))]
    SetDesktopSize(crate::vnc::engine::DesktopLayout),
    /// EnableContinuousUpdates (150, rfbproto): on or off, for this area.
    EnableContinuousUpdates(bool, Rect),
    /// Fence (248, rfbproto): flags and up to 64 bytes the other side sends back.
    Fence(u32, Vec<u8>),
}

/// Fence flags (rfbproto): what the fence asks of the side that answers it.
pub(crate) const FENCE_BLOCK_BEFORE: u32 = 1;
pub(crate) const FENCE_BLOCK_AFTER: u32 = 1 << 1;
#[allow(dead_code)]
pub(crate) const FENCE_SYNC_NEXT: u32 = 1 << 2;
pub(crate) const FENCE_REQUEST: u32 = 1 << 31;

impl ClientMsg {
    pub(super) async fn write<S>(self, writer: &mut S) -> Result<(), VncError>
    where
        S: AsyncWrite + Unpin,
    {
        match self {
            ClientMsg::SetPixelFormat(pf) => {
                // +--------------+--------------+--------------+
                // | No. of bytes | Type [Value] | Description  |
                // +--------------+--------------+--------------+
                // | 1            | U8 [0]       | message-type |
                // | 3            |              | padding      |
                // | 16           | PIXEL_FORMAT | pixel-format |
                // +--------------+--------------+--------------+
                let mut payload = vec![0_u8, 0, 0, 0];
                payload.extend(<PixelFormat as Into<Vec<u8>>>::into(pf));
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::SetEncodings(encodings) => {
                //  +--------------+--------------+---------------------+
                // | No. of bytes | Type [Value] | Description         |
                // +--------------+--------------+---------------------+
                // | 1            | U8 [2]       | message-type        |
                // | 1            |              | padding             |
                // | 2            | U16          | number-of-encodings |
                // +--------------+--------------+---------------------+

                // This is followed by number-of-encodings repetitions of the following:
                // +--------------+--------------+---------------+
                // | No. of bytes | Type [Value] | Description   |
                // +--------------+--------------+---------------+
                // | 4            | S32          | encoding-type |
                // +--------------+--------------+---------------+
                let mut payload = vec![2, 0];
                payload.extend_from_slice(&(encodings.len() as u16).to_be_bytes());
                for e in encodings {
                    payload.write_u32(e.into()).await?;
                }
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::FramebufferUpdateRequest(rect, incremental) => {
                // +--------------+--------------+--------------+
                // | No. of bytes | Type [Value] | Description  |
                // +--------------+--------------+--------------+
                // | 1            | U8 [3]       | message-type |
                // | 1            | U8           | incremental  |
                // | 2            | U16          | x-position   |
                // | 2            | U16          | y-position   |
                // | 2            | U16          | width        |
                // | 2            | U16          | height       |
                // +--------------+--------------+--------------+
                let mut payload = vec![3, incremental];
                payload.extend_from_slice(&rect.x.to_be_bytes());
                payload.extend_from_slice(&rect.y.to_be_bytes());
                payload.extend_from_slice(&rect.width.to_be_bytes());
                payload.extend_from_slice(&rect.height.to_be_bytes());
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::KeyEvent(keycode, down) => {
                // +--------------+--------------+--------------+
                // | No. of bytes | Type [Value] | Description  |
                // +--------------+--------------+--------------+
                // | 1            | U8 [4]       | message-type |
                // | 1            | U8           | down-flag    |
                // | 2            |              | padding      |
                // | 4            | U32          | key          |
                // +--------------+--------------+--------------+
                let mut payload = vec![4, down as u8, 0, 0];
                payload.write_u32(keycode).await?;
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::PointerEvent(x, y, mask) => {
                // +--------------+--------------+--------------+
                // | No. of bytes | Type [Value] | Description  |
                // +--------------+--------------+--------------+
                // | 1            | U8 [5]       | message-type |
                // | 1            | U8           | button-mask  |
                // | 2            | U16          | x-position   |
                // | 2            | U16          | y-position   |
                // +--------------+--------------+--------------+
                let mut payload = vec![5, mask];
                payload.write_u16(x).await?;
                payload.write_u16(y).await?;
                writer.write_all(&payload).await?;
                Ok(())
            }
            #[cfg(not(target_arch = "wasm32"))]
            ClientMsg::SetDesktopSize(layout) => {
                layout.validate()?;
                let mut payload = vec![251, 0];
                payload.extend_from_slice(&layout.width.to_be_bytes());
                payload.extend_from_slice(&layout.height.to_be_bytes());
                payload.extend_from_slice(&[layout.screens.len() as u8, 0]);
                for screen in layout.screens {
                    payload.extend_from_slice(&screen.id.to_be_bytes());
                    payload.extend_from_slice(&screen.x.to_be_bytes());
                    payload.extend_from_slice(&screen.y.to_be_bytes());
                    payload.extend_from_slice(&screen.width.to_be_bytes());
                    payload.extend_from_slice(&screen.height.to_be_bytes());
                    payload.extend_from_slice(&screen.flags.to_be_bytes());
                }
                // Some servers release resize confirmations only with an outstanding
                // update request. Keep it ordered with the resize and bounded to one pixel.
                payload.extend_from_slice(&[3, 1, 0, 0, 0, 0, 0, 1, 0, 1]);
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::ClientCutText(s) => {
                //   +--------------+--------------+--------------+
                //   | No. of bytes | Type [Value] | Description  |
                //   +--------------+--------------+--------------+
                //   | 1            | U8 [6]       | message-type |
                //   | 3            |              | padding      |
                //   | 4            | U32          | length       |
                //   | length       | U8 array     | text         |
                //   +--------------+--------------+--------------+
                // Latin-1 (RFC 6143, 7.5.6): a character beyond it becomes '?'.
                let text: Vec<u8> = s.chars().map(|c| u8::try_from(u32::from(c)).unwrap_or(b'?')).collect();
                let mut payload = vec![6_u8, 0, 0, 0];
                payload.write_u32(text.len() as u32).await?;
                payload.write_all(&text).await?;
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::ExtendedCutText(body) => {
                // The length is negative: the extended clipboard's form (rfbproto).
                let mut payload = vec![6_u8, 0, 0, 0];
                payload.extend_from_slice(&(-(body.len() as i32)).to_be_bytes());
                payload.extend_from_slice(&body);
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::EnableContinuousUpdates(on, rect) => {
                // 150, enable-flag, then the area: x, y, width, height (U16 each).
                let mut payload = vec![150_u8, u8::from(on)];
                for v in [rect.x, rect.y, rect.width, rect.height] {
                    payload.extend_from_slice(&v.to_be_bytes());
                }
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::Fence(flags, data) => {
                // 248, 3 padding, flags (U32), length (U8), payload (at most 64 bytes).
                let data = &data[..data.len().min(64)];
                let mut payload = vec![248_u8, 0, 0, 0];
                payload.extend_from_slice(&flags.to_be_bytes());
                payload.push(data.len() as u8);
                payload.extend_from_slice(data);
                writer.write_all(&payload).await?;
                Ok(())
            }
            ClientMsg::QemuKey(down, keysym, scancode) => {
                // QEMU client message (255), submessage 0: down flag (U16), keysym, keycode.
                let mut payload = vec![255_u8, 0];
                payload.extend_from_slice(&u16::from(down).to_be_bytes());
                payload.extend_from_slice(&keysym.to_be_bytes());
                payload.extend_from_slice(&scancode.to_be_bytes());
                writer.write_all(&payload).await?;
                Ok(())
            }
        }
    }
}

#[derive(Debug)]
pub(super) enum ServerMsg {
    FramebufferUpdate(u16),
    // SetColorMapEntries,
    Bell,
    ServerCutText(String),
    /// The extended clipboard's form: flags and what follows them.
    ExtendedCutText(Vec<u8>),
    /// EndOfContinuousUpdates (150): the server has continuous updates (its answer to
    /// SetEncodings with the pseudo encoding), or it stopped them (its answer to a disable).
    EndOfContinuousUpdates,
    /// Fence (248): flags and the payload to send back.
    Fence(u32, Vec<u8>),
}

impl ServerMsg {
    pub(super) async fn read<S>(reader: &mut S) -> Result<Self, VncError>
    where
        S: AsyncRead + Unpin,
    {
        let server_msg = reader.read_u8().await?;

        match server_msg {
            0 => {
                // FramebufferUpdate
                //   +--------------+--------------+----------------------+
                //   | No. of bytes | Type [Value] | Description          |
                //   +--------------+--------------+----------------------+
                //   | 1            | U8 [0]       | message-type         |
                //   | 1            |              | padding              |
                //   | 2            | U16          | number-of-rectangles |
                //   +--------------+--------------+----------------------+
                let _padding = reader.read_u8().await?;
                let rects = reader.read_u16().await?;
                Ok(ServerMsg::FramebufferUpdate(rects))
            }
            1 => {
                // SetColorMapEntries
                // +--------------+--------------+------------------+
                // | No. of bytes | Type [Value] | Description      |
                // +--------------+--------------+------------------+
                // | 1            | U8 [1]       | message-type     |
                // | 1            |              | padding          |
                // | 2            | U16          | first-color      |
                // | 2            | U16          | number-of-colors |
                // +--------------+--------------+------------------+
                Err(VncError::WrongServerMessage)
            }
            2 => {
                // Bell
                //   +--------------+--------------+--------------+
                //   | No. of bytes | Type [Value] | Description  |
                //   +--------------+--------------+--------------+
                //   | 1            | U8 [2]       | message-type |
                //   +--------------+--------------+--------------+
                Ok(ServerMsg::Bell)
            }
            3 => {
                // ServerCutText
                // +--------------+--------------+--------------+
                // | No. of bytes | Type [Value] | Description  |
                // +--------------+--------------+--------------+
                // | 1            | U8 [3]       | message-type |
                // | 3            |              | padding      |
                // | 4            | U32          | length       |
                // | length       | U8 array     | text         |
                // +--------------+--------------+--------------+
                let mut padding = [0; 3];
                reader.read_exact(&mut padding).await?;
                let length = reader.read_i32().await?;
                let size = length.unsigned_abs() as usize;
                if size > crate::vnc::engine::limits::MAX_TEXT {
                    return Err(VncError::General("VNC string exceeds size limit".into()));
                }
                let mut bytes = vec![0; size];
                reader.read_exact(&mut bytes).await?;
                if length < 0 {
                    Ok(Self::ExtendedCutText(bytes))
                } else {
                    // Latin-1: each byte is the character of the same number.
                    Ok(Self::ServerCutText(bytes.iter().map(|&b| char::from(b)).collect()))
                }
            }
            150 => Ok(ServerMsg::EndOfContinuousUpdates),
            248 => {
                let mut padding = [0; 3];
                reader.read_exact(&mut padding).await?;
                let flags = reader.read_u32().await?;
                let len = reader.read_u8().await? as usize;
                if len > 64 {
                    return Err(VncError::WrongServerMessage);
                }
                let mut payload = vec![0; len];
                reader.read_exact(&mut payload).await?;
                Ok(ServerMsg::Fence(flags, payload))
            }
            _ => Err(VncError::WrongServerMessage),
        }
    }
}
