//! The remote picture in Rust memory, RGBA and opaque, with dirty tiles, and the packets Dart
//! takes them in.
//!
//! The session's own reader takes the whole picture ([Framebuffer::take], told by FRAME), or the
//! part of it that it shows ([Framebuffer::show]: one of the remote's displays). Others
//! read a part of it through a view (4.0): a rectangle of the picture with dirty tiles of
//! its own, for a window that shows one of the remote's displays or a small picture of one. A
//! view is never told anything: its reader asks ([Framebuffer::view_take]) when it draws, so
//! nothing is called in an engine that may be gone.

/// One tile in a [FramePacket]: where it goes on the screen, and where its pixels start in the
/// packet's buffer (`width * height * 4` bytes, rows one after the other).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameTile {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub offset: u64,
}

/// What `zest_screen_take_frame` returns (Dart reads it through a matching `Struct`). Times are
/// [super::now_us].
#[repr(C)]
#[derive(Debug)]
pub struct FramePacket {
    /// The frame's number (the FRAME event's `a` of the last update in it).
    pub seq: u64,
    /// The whole screen's size.
    pub width: u32,
    pub height: u32,
    pub tile_count: u32,
    /// Server updates merged into this packet.
    pub updates: u32,
    pub tiles: *const FrameTile,
    pub pixels: *const u8,
    pub pixels_len: u64,
    /// The first rectangle of the oldest update in it reached the engine.
    pub first_change_us: i64,
    /// The newest update in it ended.
    pub last_done_us: i64,
    /// Packed for Dart.
    pub taken_us: i64,
}

/// The packet and what it points at, freed together.
#[repr(C)]
struct Owned {
    packet: FramePacket,
    tiles: Vec<FrameTile>,
    pixels: Vec<u8>,
}

/// Frees a packet `zest_screen_take_frame` returned.
///
/// # Safety
/// [packet] must be null or a packet [Framebuffer::take] made, freed once.
pub unsafe fn free_packet(packet: *mut FramePacket) {
    if !packet.is_null() {
        // SAFETY: `packet` is the first field of a boxed, repr(C) Owned.
        drop(unsafe { Box::from_raw(packet.cast::<Owned>()) });
    }
}

/// Sets every pixel's fourth byte to 255, a word at a time (the compiler makes it a few wide
/// instructions a row; byte by byte it was a pass of its own over every rectangle).
fn opaque(row: &mut [u8]) {
    // SAFETY: any bytes are a valid u32; align_to_mut gives the aligned middle as words.
    let (head, words, tail) = unsafe { row.align_to_mut::<u32>() };
    if head.is_empty() && tail.is_empty() {
        let alpha = u32::from_ne_bytes([0, 0, 0, 255]);
        for w in words {
            *w |= alpha;
        }
    } else {
        for px in row.chunks_exact_mut(4) {
            px[3] = 255;
        }
    }
}

/// Ours: the views a session may have open at once (a window and a small picture for each of
/// four displays, twice over).
pub const MAX_VIEWS: usize = 16;

/// Ours: a view's picture is at most this many times smaller a side than what it shows.
pub const MAX_VIEW_DIVIDE: u32 = 16;

/// A rectangle of the picture with dirty tiles of its own.
struct View {
    /// As asked for, in the picture's pixels (it may reach past the picture, or lie outside it).
    asked: (u32, u32, u32, u32),
    /// What of it is inside the picture now: x, y, width, height (width or height 0: nothing).
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    /// Its picture is this many times smaller a side (1: as it is, in tiles).
    divide: u32,
    cols: u32,
    rows: u32,
    dirty: Vec<bool>,
    any_dirty: bool,
    first_change_us: i64,
}

impl View {
    /// Fits the view into a picture of this size: all of it to send.
    fn fit(&mut self, picture_width: u32, picture_height: u32, side: u32) {
        let (x, y, w, h) = self.asked;
        self.x = x.min(picture_width);
        self.y = y.min(picture_height);
        self.width = w.min(picture_width - self.x);
        self.height = h.min(picture_height - self.y);
        self.cols = self.width.div_ceil(side);
        self.rows = self.height.div_ceil(side);
        self.dirty = vec![true; (self.cols * self.rows) as usize];
        self.any_dirty = self.width > 0 && self.height > 0;
    }

    /// A changed rectangle of the picture (inside it): the view's tiles it touches.
    fn mark(&mut self, x: u32, y: u32, w: u32, h: u32, side: u32, now: i64) {
        let left = x.max(self.x);
        let top = y.max(self.y);
        let right = (x + w).min(self.x + self.width);
        let bottom = (y + h).min(self.y + self.height);
        if left >= right || top >= bottom {
            return;
        }
        for row in (top - self.y) / side..=(bottom - 1 - self.y) / side {
            for col in (left - self.x) / side..=(right - 1 - self.x) / side {
                self.dirty[(row * self.cols + col) as usize] = true;
            }
        }
        self.any_dirty = true;
        if self.first_change_us == 0 {
            self.first_change_us = now;
        }
    }
}

pub struct Framebuffer {
    pub width: u32,
    pub height: u32,
    rgba: Vec<u8>,
    /// Tiles' side (0: one tile, the whole screen).
    tile: u32,
    cols: u32,
    rows: u32,
    dirty: Vec<bool>,
    any_dirty: bool,
    seq: u64,
    updates: u32,
    first_change_us: i64,
    last_done_us: i64,
    /// Dart was told and has not taken the frame yet.
    notified: bool,
    /// The views open, by their number less one (a closed one's place is free again).
    views: Vec<Option<View>>,
    /// What the session's own reader shows, as asked for ([Self::show]); None: all of it.
    shown: Option<(u32, u32, u32, u32)>,
}

impl Framebuffer {
    pub fn new(tile: u32) -> Self {
        let mut f = Self {
            width: 0,
            height: 0,
            rgba: Vec::new(),
            tile,
            cols: 0,
            rows: 0,
            dirty: Vec::new(),
            any_dirty: false,
            seq: 0,
            updates: 0,
            first_change_us: 0,
            last_done_us: 0,
            notified: false,
            views: Vec::new(),
            shown: None,
        };
        f.resize(0, 0);
        f
    }

    /// A new size: black, all of it to send.
    pub fn resize(&mut self, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        let mut rgba = vec![0u8; width as usize * height as usize * 4];
        for px in rgba.chunks_exact_mut(4) {
            px[3] = 255;
        }
        self.rgba = rgba;
        let side = if self.tile == 0 { width.max(height).max(1) } else { self.tile };
        self.cols = width.div_ceil(side);
        self.rows = height.div_ceil(side);
        self.dirty = vec![true; (self.cols * self.rows) as usize];
        self.any_dirty = width > 0 && height > 0;
        // Every view shows what of it is inside the new picture, from the start.
        for view in self.views.iter_mut().flatten() {
            view.fit(width, height, side);
        }
    }

    fn side(&self) -> u32 {
        if self.tile == 0 { self.width.max(self.height).max(1) } else { self.tile }
    }

    /// Clips a rectangle to the screen: (x, y, w, h), or None when nothing is left.
    fn clip(&self, x: u32, y: u32, w: u32, h: u32) -> Option<(u32, u32, u32, u32)> {
        if x >= self.width || y >= self.height || w == 0 || h == 0 {
            return None;
        }
        Some((x, y, w.min(self.width - x), h.min(self.height - y)))
    }

    fn mark(&mut self, x: u32, y: u32, w: u32, h: u32, now: i64) {
        let side = self.side();
        for row in y / side..=(y + h - 1) / side {
            for col in x / side..=(x + w - 1) / side {
                self.dirty[(row * self.cols + col) as usize] = true;
            }
        }
        if !self.any_dirty {
            self.any_dirty = true;
        }
        if self.first_change_us == 0 {
            self.first_change_us = now;
        }
        for view in self.views.iter_mut().flatten() {
            view.mark(x, y, w, h, side, now);
        }
    }

    /// A rectangle's pixels (RGBA in the engine's order, `w * h * 4` bytes; its fourth byte may be
    /// padding from the server, so the picture is made opaque here).
    pub fn put(&mut self, x: u32, y: u32, w: u32, h: u32, pixels: &[u8], now: i64) {
        let Some((x, y, cw, ch)) = self.clip(x, y, w, h) else { return };
        let stride = self.width as usize * 4;
        let src_stride = w as usize * 4;
        for row in 0..ch as usize {
            let Some(src) = pixels.get(row * src_stride..row * src_stride + cw as usize * 4) else { break };
            let at = (y as usize + row) * stride + x as usize * 4;
            let dst = &mut self.rgba[at..at + cw as usize * 4];
            dst.copy_from_slice(src);
            opaque(dst);
        }
        self.mark(x, y, cw, ch, now);
    }

    /// A rectangle of one colour (RGBA; made opaque): each row written whole, no picture of it.
    pub fn fill(&mut self, x: u32, y: u32, w: u32, h: u32, pixel: [u8; 4], now: i64) {
        let Some((x, y, cw, ch)) = self.clip(x, y, w, h) else { return };
        let stride = self.width as usize * 4;
        let row: Vec<u8> = [pixel[0], pixel[1], pixel[2], 255].repeat(cw as usize);
        for r in 0..ch as usize {
            let at = (y as usize + r) * stride + x as usize * 4;
            self.rgba[at..at + row.len()].copy_from_slice(&row);
        }
        self.mark(x, y, cw, ch, now);
    }

    /// A region of a whole picture the engine keeps itself (RDP's decoded image: RGBA, the
    /// screen's size, rows of `image_width * 4` bytes), copied at the same place.
    pub fn put_from_image(&mut self, image: &[u8], image_width: u32, x: u32, y: u32, w: u32, h: u32, now: i64) {
        let Some((x, y, cw, ch)) = self.clip(x, y, w, h) else { return };
        if x + cw > image_width {
            return;
        }
        let stride = self.width as usize * 4;
        let src_stride = image_width as usize * 4;
        for row in 0..ch as usize {
            let from = (y as usize + row) * src_stride + x as usize * 4;
            let Some(src) = image.get(from..from + cw as usize * 4) else { break };
            let at = (y as usize + row) * stride + x as usize * 4;
            let dst = &mut self.rgba[at..at + cw as usize * 4];
            dst.copy_from_slice(src);
            opaque(dst);
        }
        self.mark(x, y, cw, ch, now);
    }

    /// CopyRect: the source rectangle's pixels to the destination (they may overlap).
    pub fn copy(&mut self, dx: u32, dy: u32, sx: u32, sy: u32, w: u32, h: u32, now: i64) {
        let (Some(_), Some(_)) = (self.clip(dx, dy, w, h), self.clip(sx, sy, w, h)) else { return };
        let w = w.min(self.width - dx).min(self.width - sx) as usize;
        let h = h.min(self.height - dy).min(self.height - sy) as usize;
        let stride = self.width as usize * 4;
        let mut block = Vec::with_capacity(w * h * 4);
        for row in 0..h {
            let at = (sy as usize + row) * stride + sx as usize * 4;
            block.extend_from_slice(&self.rgba[at..at + w * 4]);
        }
        for row in 0..h {
            let at = (dy as usize + row) * stride + dx as usize * 4;
            self.rgba[at..at + w * 4].copy_from_slice(&block[row * w * 4..(row + 1) * w * 4]);
        }
        self.mark(dx, dy, w as u32, h as u32, now);
    }

    /// The end of one server update. True when Dart should be told (something changed and it was
    /// not told already); the new frame number is [Self::seq].
    pub fn update_done(&mut self, now: i64) -> bool {
        self.seq += 1;
        self.updates += 1;
        self.last_done_us = now;
        if self.any_dirty && !self.notified {
            self.notified = true;
            return true;
        }
        false
    }

    pub fn seq(&self) -> u64 {
        self.seq
    }

    /// The part of the picture its own reader shows, inside the picture: x, y, width, height
    /// (all of it unless [Self::show] named a part that is inside it).
    fn shown_now(&self) -> (u32, u32, u32, u32) {
        match self.shown {
            Some((x, y, w, h)) if x < self.width && y < self.height => (x, y, w.min(self.width - x), h.min(self.height - y)),
            _ => (0, 0, self.width, self.height),
        }
    }

    /// What the session's own reader takes from now on: the rectangle x, y, width, height of
    /// the picture (one of the remote's displays), or all of it (a width or height of 0, or a
    /// rectangle that lies outside the picture). [Self::take] then gives that part only, its
    /// tiles' places counted from the part's corner and the packet's size the part's, starting
    /// with all of it. Changes outside it are kept for when it is shown.
    pub fn show(&mut self, x: u32, y: u32, width: u32, height: u32) {
        self.shown = (width > 0 && height > 0).then_some((x, y, width, height));
        // Its reader starts again: what it holds is of another part.
        self.dirty.iter_mut().for_each(|d| *d = true);
        self.any_dirty = self.width > 0 && self.height > 0;
    }

    /// The dirty tiles of what its reader shows ([Self::show]: all of the picture, or a part),
    /// packed, or None when nothing in it changed. Clears them.
    pub fn take(&mut self, now: i64) -> Option<*mut FramePacket> {
        self.notified = false;
        if !self.any_dirty || self.width == 0 || self.height == 0 {
            return None;
        }
        let side = self.side();
        let stride = self.width as usize * 4;
        let (sx, sy, sw, sh) = self.shown_now();
        // The tiles the shown part touches.
        let (col0, col1) = (sx / side, (sx + sw - 1) / side);
        let (row0, row1) = (sy / side, (sy + sh - 1) / side);
        let in_part = ((col1 - col0 + 1) * (row1 - row0 + 1)) as usize;
        let mut dirty = 0usize;
        for row in row0..=row1 {
            for col in col0..=col1 {
                dirty += usize::from(self.dirty[(row * self.cols + col) as usize]);
            }
        }
        if dirty == 0 {
            // Something changed, outside what is shown: it waits there.
            self.any_dirty = self.dirty.iter().any(|d| *d);
            return None;
        }
        let mut tiles = Vec::new();
        let mut size = 0usize;
        // Most of it changed: one image of all of it is cheaper for Dart than many tiles
        // (each tile is a round trip through the engine's image decoder).
        if in_part > 1 && dirty * 2 > in_part {
            tiles.push(FrameTile { x: 0, y: 0, width: sw, height: sh, offset: 0 });
            size = sw as usize * sh as usize * 4;
        }
        for row in if tiles.is_empty() { row0..=row1 } else { 1..=0 } {
            for col in col0..=col1 {
                if self.dirty[(row * self.cols + col) as usize] {
                    // The tile, cut to the shown part, and its place from the part's corner.
                    let (left, top) = ((col * side).max(sx), (row * side).max(sy));
                    let right = ((col + 1) * side).min(sx + sw);
                    let bottom = ((row + 1) * side).min(sy + sh);
                    let (w, h) = (right - left, bottom - top);
                    tiles.push(FrameTile { x: left - sx, y: top - sy, width: w, height: h, offset: size as u64 });
                    size += w as usize * h as usize * 4;
                }
            }
        }
        let mut pixels = Vec::with_capacity(size);
        for t in &tiles {
            for row in 0..t.height as usize {
                let at = ((sy + t.y) as usize + row) * stride + (sx + t.x) as usize * 4;
                pixels.extend_from_slice(&self.rgba[at..at + t.width as usize * 4]);
            }
        }
        let owned = Box::new(Owned {
            packet: FramePacket {
                seq: self.seq,
                width: sw,
                height: sh,
                tile_count: tiles.len() as u32,
                updates: self.updates,
                tiles: tiles.as_ptr(),
                pixels: pixels.as_ptr(),
                pixels_len: pixels.len() as u64,
                first_change_us: self.first_change_us,
                last_done_us: self.last_done_us,
                taken_us: now,
            },
            tiles,
            pixels,
        });
        // What was taken is clean; what changed outside the shown part waits.
        for row in row0..=row1 {
            for col in col0..=col1 {
                self.dirty[(row * self.cols + col) as usize] = false;
            }
        }
        self.any_dirty = self.dirty.iter().any(|d| *d);
        self.updates = 0;
        self.first_change_us = 0;
        Some(Box::into_raw(owned).cast::<FramePacket>())
    }

    /// Opens a view on the rectangle x, y, width, height of the picture, its own picture
    /// [divide] times smaller a side (1 to [MAX_VIEW_DIVIDE]): its number (from 1), or None
    /// where [MAX_VIEWS] are open, the rectangle is empty or [divide] is not such a number. The
    /// rectangle may reach past the picture: the view shows what of it is inside, and more when
    /// the picture grows.
    pub fn view_open(&mut self, x: u32, y: u32, width: u32, height: u32, divide: u32) -> Option<u32> {
        if width == 0 || height == 0 || divide == 0 || divide > MAX_VIEW_DIVIDE {
            return None;
        }
        // No side past what a picture can have: the sums below stay in 32 bits.
        let (width, height) = (width.min(1 << 16), height.min(1 << 16));
        let (x, y) = (x.min(1 << 16), y.min(1 << 16));
        let place = match self.views.iter().position(Option::is_none) {
            Some(free) => free,
            None if self.views.len() < MAX_VIEWS => {
                self.views.push(None);
                self.views.len() - 1
            }
            None => return None,
        };
        let mut view = View {
            asked: (x, y, width, height),
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            divide,
            cols: 0,
            rows: 0,
            dirty: Vec::new(),
            any_dirty: false,
            first_change_us: 0,
        };
        view.fit(self.width, self.height, self.side());
        self.views[place] = Some(view);
        Some(place as u32 + 1)
    }

    /// Closes a view; nothing where there is none of that number.
    pub fn view_close(&mut self, view: u32) {
        if let Some(place) = (view as usize).checked_sub(1).and_then(|i| self.views.get_mut(i)) {
            *place = None;
        }
    }

    /// Whether there is an open view of that number.
    pub fn view_is_open(&self, view: u32) -> bool {
        (view as usize).checked_sub(1).and_then(|i| self.views.get(i)).is_some_and(Option::is_some)
    }

    /// How many views are open.
    pub fn views_open(&self) -> usize {
        self.views.iter().flatten().count()
    }

    /// A view's changed tiles, packed as [Self::take] packs the picture's, their places counted
    /// from the view's own corner and the packet's size the view's; or None when nothing in it
    /// changed, it is outside the picture, or there is no such view. Clears them. A view whose
    /// picture is smaller than what it shows gives all of it as one tile, each of its pixels
    /// the mean of the pixels it stands for.
    pub fn view_take(&mut self, view: u32, now: i64) -> Option<*mut FramePacket> {
        let side = self.side();
        let stride = self.width as usize * 4;
        let (seq, last_done_us) = (self.seq, self.last_done_us);
        let rgba = &self.rgba;
        let v = (view as usize).checked_sub(1).and_then(|i| self.views.get_mut(i))?.as_mut()?;
        if !v.any_dirty || v.width == 0 || v.height == 0 {
            return None;
        }
        let mut tiles = Vec::new();
        let mut pixels: Vec<u8>;
        let (width, height);
        if v.divide > 1 {
            let d = v.divide;
            (width, height) = ((v.width / d).max(1), (v.height / d).max(1));
            pixels = Vec::with_capacity(width as usize * height as usize * 4);
            for oy in 0..height {
                for ox in 0..width {
                    // The block this pixel stands for, cut at the view's edge.
                    let (bx, by) = (ox * d, oy * d);
                    let (bw, bh) = (d.min(v.width - bx), d.min(v.height - by));
                    let mut sum = [0u32; 3];
                    for row in 0..bh {
                        let at = (v.y + by + row) as usize * stride + (v.x + bx) as usize * 4;
                        for px in rgba[at..at + bw as usize * 4].chunks_exact(4) {
                            sum[0] += u32::from(px[0]);
                            sum[1] += u32::from(px[1]);
                            sum[2] += u32::from(px[2]);
                        }
                    }
                    let n = bw * bh;
                    pixels.extend_from_slice(&[(sum[0] / n) as u8, (sum[1] / n) as u8, (sum[2] / n) as u8, 255]);
                }
            }
            tiles.push(FrameTile { x: 0, y: 0, width, height, offset: 0 });
        } else {
            (width, height) = (v.width, v.height);
            let mut size = 0usize;
            // Most of it changed: one image of all of it, as for the picture.
            let dirty = v.dirty.iter().filter(|d| **d).count();
            if v.dirty.len() > 1 && dirty * 2 > v.dirty.len() {
                tiles.push(FrameTile { x: 0, y: 0, width, height, offset: 0 });
                size = width as usize * height as usize * 4;
            }
            for row in 0..if tiles.is_empty() { v.rows } else { 0 } {
                for col in 0..v.cols {
                    if v.dirty[(row * v.cols + col) as usize] {
                        let (x, y) = (col * side, row * side);
                        let (w, h) = (side.min(width - x), side.min(height - y));
                        tiles.push(FrameTile { x, y, width: w, height: h, offset: size as u64 });
                        size += w as usize * h as usize * 4;
                    }
                }
            }
            pixels = Vec::with_capacity(size);
            for t in &tiles {
                for row in 0..t.height as usize {
                    let at = (v.y + t.y) as usize * stride + row * stride + (v.x + t.x) as usize * 4;
                    pixels.extend_from_slice(&rgba[at..at + t.width as usize * 4]);
                }
            }
        }
        let owned = Box::new(Owned {
            packet: FramePacket {
                seq,
                width,
                height,
                tile_count: tiles.len() as u32,
                updates: 0,
                tiles: tiles.as_ptr(),
                pixels: pixels.as_ptr(),
                pixels_len: pixels.len() as u64,
                first_change_us: v.first_change_us,
                last_done_us,
                taken_us: now,
            },
            tiles,
            pixels,
        });
        v.dirty.iter_mut().for_each(|d| *d = false);
        v.any_dirty = false;
        v.first_change_us = 0;
        Some(Box::into_raw(owned).cast::<FramePacket>())
    }

    /// The whole picture (tests).
    #[cfg(test)]
    pub fn rgba(&self) -> &[u8] {
        &self.rgba
    }
}
