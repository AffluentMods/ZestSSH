use crate::vnc::engine::{Rect, VncError};
use tokio::io::{AsyncRead, AsyncReadExt};

pub(crate) const MAX_PIXELS: usize = 8_294_400;
pub(crate) const MAX_DIMENSION: u16 = 8192;
/// A compressed rectangle's declared length: the largest picture (MAX_PIXELS at 4 bytes) plus
/// zlib's worst-case overhead and room for headers (about 33.7 MB). Buffers sized by a length the
/// server sends are allocated before its bytes come, so the cap is no larger than a real one.
pub(crate) const MAX_COMPRESSED: usize = MAX_PIXELS * 4 + MAX_PIXELS / 64 + 1024;
pub(crate) const MAX_TEXT: usize = 1024 * 1024;
pub(crate) const MAX_NAME: usize = 4096;

pub(crate) fn dimensions(width: u16, height: u16) -> Result<(), VncError> {
    if width == 0
        || height == 0
        || width > MAX_DIMENSION
        || height > MAX_DIMENSION
        || usize::from(width) * usize::from(height) > MAX_PIXELS
    {
        return Err(VncError::InvalidImageData);
    }
    Ok(())
}

pub(crate) fn rectangle(rect: &Rect, screen: (u16, u16)) -> Result<(), VncError> {
    dimensions(rect.width, rect.height)?;
    if u32::from(rect.x) + u32::from(rect.width) > u32::from(screen.0)
        || u32::from(rect.y) + u32::from(rect.height) > u32::from(screen.1)
    {
        return Err(VncError::InvalidImageData);
    }
    Ok(())
}

pub(crate) async fn string<S: AsyncRead + Unpin>(
    reader: &mut S,
    limit: usize,
) -> Result<String, VncError> {
    let length = reader.read_u32().await? as usize;
    if length > limit {
        return Err(VncError::General("VNC string exceeds size limit".into()));
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes).await?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Ours: RRE's and Hextile's subrectangles may cover their rectangle this many times in all.
/// Real encoders never overlap them (each pixel is drawn once, over the background), but a
/// 12-byte RRE subrectangle can repaint a whole 33 MB rectangle: thousands of them were minutes
/// of work for a few KB (from a security review).
pub(crate) const MAX_SUBRECT_COVER: usize = 4;

/// Ours: one framebuffer update may draw this many times the screen's pixels in all (a real
/// server's rectangles do not overlap; CopyRect and the rectangles drawn over it stay far
/// under it).
pub(crate) const MAX_UPDATE_COVER: u64 = 4;

/// The subrectangles of a rectangle of [area] pixels have covered [drawn] pixels: too many?
pub(crate) fn subrects(drawn: usize, area: usize) -> Result<(), VncError> {
    if drawn > area.saturating_mul(MAX_SUBRECT_COVER) {
        return Err(VncError::Excessive(format!(
            "the server's subrectangles cover their rectangle more than {MAX_SUBRECT_COVER} times"
        )));
    }
    Ok(())
}

/// Ours: what one framebuffer update has cost so far (from a security review).
#[derive(Default)]
pub(crate) struct UpdateWork {
    /// Pixels of the rectangles drawn.
    drawn: u64,
    /// The largest screen the update had (it may resize it).
    screen: u64,
    resized: bool,
}

impl UpdateWork {
    /// A rectangle to draw on a screen of [screen]'s size.
    pub(crate) fn draw(&mut self, rect: &Rect, screen: (u16, u16)) -> Result<(), VncError> {
        self.screen = self.screen.max(u64::from(screen.0) * u64::from(screen.1));
        self.drawn += u64::from(rect.width) * u64::from(rect.height);
        if self.drawn > self.screen * MAX_UPDATE_COVER {
            return Err(VncError::Excessive(format!(
                "the server's update draws more than {MAX_UPDATE_COVER} times the screen"
            )));
        }
        Ok(())
    }

    /// A new screen size (DesktopSize): a new picture, so one an update.
    pub(crate) fn resize(&mut self) -> Result<(), VncError> {
        if self.resized {
            return Err(VncError::Excessive("the server changed the screen's size twice in one update".into()));
        }
        self.resized = true;
        Ok(())
    }
}

/// Ours: the largest cursor shape kept, on either side (from a security review). Real cursors are
/// 32 to 64 pixels, 128 or 256 on a large display; a larger one is hidden, not drawn.
pub(crate) const MAX_CURSOR: u16 = 256;
