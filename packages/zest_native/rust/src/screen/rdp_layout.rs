//! The remote's displays (4.0): what the app asks an RDP server for, checked and turned
//! into the three shapes the protocol wants it in (the monitor data of the connection, its
//! extended part, and the display control channel's layout), and the ceilings that follow from
//! what was asked.
//!
//! One display is what a session had before: its size is brought into what the server takes
//! ([asked_size]) and no monitor data is sent. Several are taken only as given: a size that would
//! have to be changed would move its neighbours, so it is refused and the app asks again.

use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};

use ironrdp_displaycontrol::pdu::{DeviceScaleFactor, DisplayControlMonitorLayout, MonitorLayoutEntry};
use ironrdp_pdu::gcc;

use super::rdp_session::{MAX_DIMENSION, MAX_PIXELS, asked_size};

/// Ours: the displays a session may ask for.
pub(crate) const MAX_DISPLAYS: usize = 4;

/// Ours: the pixels of the whole remote desktop (the rectangle around every display), which the
/// app holds as one picture: four of the largest display. Displays set corner to corner have a
/// rectangle around them larger than their own pixels; it is that rectangle that is counted.
pub(crate) const MAX_DESKTOP_PIXELS: usize = MAX_DISPLAYS * MAX_PIXELS;

/// The longest side of the whole desktop: the protocol's own (a desktop's width and height are
/// at most 32,766).
pub(crate) const MAX_DESKTOP_SIDE: u32 = 32_766;

/// One display as the app asks for it (JSON from Dart). [x] and [y] are where it is among the
/// others, in pixels, from any origin; [scale] is the desktop scale factor in percent (0: none
/// said).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize)]
pub struct DisplaySpec {
    #[serde(default)]
    pub x: i32,
    #[serde(default)]
    pub y: i32,
    pub width: u32,
    pub height: u32,
    #[serde(default)]
    pub scale: u32,
    #[serde(default)]
    pub primary: bool,
}

/// One display of a [Layout]: its place from the primary one's corner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Display {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
    scale: u32,
    primary: bool,
}

/// What a session asks the server for: its displays, the first of them the primary one's place
/// being (0, 0), and the rectangle around them all, which is the remote desktop and the app's
/// picture.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Layout {
    displays: Vec<Display>,
    /// The desktop's corner from the primary display's (never more than 0).
    min_left: i32,
    min_top: i32,
    width: u32,
    height: u32,
}

impl Layout {
    /// One display of about this size, as a session without displays asked ([asked_size]).
    pub(crate) fn single(width: u32, height: u32, scale: u32) -> Self {
        let (width, height) = asked_size(width, height);
        Self {
            displays: vec![Display { left: 0, top: 0, width, height, scale: checked_scale(scale), primary: true }],
            min_left: 0,
            min_top: 0,
            width,
            height,
        }
    }

    /// The layout [specs] ask for, or why it is not one to ask a server for.
    pub(crate) fn of(specs: &[DisplaySpec]) -> Result<Self, String> {
        match specs {
            [] => return Err("no display was asked for".to_owned()),
            [one] => return Ok(Self::single(one.width, one.height, one.scale)),
            _ => {}
        }
        if specs.len() > MAX_DISPLAYS {
            return Err(format!("{} displays were asked for (at most {MAX_DISPLAYS})", specs.len()));
        }
        // The primary one: the one that says so, the first where none or several do.
        let primaries: Vec<usize> = specs.iter().enumerate().filter(|(_, s)| s.primary).map(|(i, _)| i).collect();
        let primary = if primaries.len() == 1 { primaries[0] } else { 0 };
        let origin = specs[primary];
        let mut displays = Vec::with_capacity(specs.len());
        for (i, s) in specs.iter().enumerate() {
            if asked_size(s.width, s.height) != (s.width, s.height) {
                return Err(format!(
                    "display {} of {} by {} is not a size a server takes (200 to {MAX_DIMENSION} a side, the width even, at most {MAX_PIXELS} pixels)",
                    i + 1,
                    s.width,
                    s.height
                ));
            }
            let (Some(left), Some(top)) = (s.x.checked_sub(origin.x), s.y.checked_sub(origin.y)) else {
                return Err(format!("display {} is too far from the first", i + 1));
            };
            displays.push(Display { left, top, width: s.width, height: s.height, scale: checked_scale(s.scale), primary: i == primary });
        }
        // The rectangle around them all, in 64 bits: the places are any numbers at all.
        let min_left = displays.iter().map(|d| i64::from(d.left)).min().unwrap_or(0);
        let min_top = displays.iter().map(|d| i64::from(d.top)).min().unwrap_or(0);
        let right = displays.iter().map(|d| i64::from(d.left) + i64::from(d.width)).max().unwrap_or(0);
        let bottom = displays.iter().map(|d| i64::from(d.top) + i64::from(d.height)).max().unwrap_or(0);
        let (width, height) = (right - min_left, bottom - min_top);
        if width > i64::from(MAX_DESKTOP_SIDE) || height > i64::from(MAX_DESKTOP_SIDE) {
            return Err(format!("the displays span {width} by {height} (at most {MAX_DESKTOP_SIDE} a side)"));
        }
        if width * height > MAX_DESKTOP_PIXELS as i64 {
            return Err(format!(
                "the rectangle around the displays is {width} by {height}, more than {MAX_DESKTOP_PIXELS} pixels"
            ));
        }
        let layout = Self {
            displays,
            min_left: min_left as i32,
            min_top: min_top as i32,
            width: width as u32,
            height: height as u32,
        };
        // One primary at (0, 0), none over another, each touching another: the channel's own
        // rules, checked by the type that is sent.
        layout.display_control().map_err(|e| format!("the displays are not a layout a server takes: {e}"))?;
        Ok(layout)
    }

    pub(crate) fn count(&self) -> usize {
        self.displays.len()
    }

    /// The whole desktop's size: the app's picture.
    pub(crate) fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    pub(crate) fn pixels(&self) -> usize {
        self.width as usize * self.height as usize
    }

    /// Each display as x, y, width and height in the picture's pixels, in the order asked.
    pub(crate) fn rects(&self) -> Vec<[u32; 4]> {
        self.displays
            .iter()
            .map(|d| [(d.left - self.min_left) as u32, (d.top - self.min_top) as u32, d.width, d.height])
            .collect()
    }

    /// The first display's scale factor, as the connection's own setting takes it (0: none).
    pub(crate) fn scale(&self) -> u32 {
        self.displays.iter().find(|d| d.primary).map_or(0, |d| d.scale)
    }

    /// The connection's monitor data; none for one display, as before.
    pub(crate) fn monitor_data(&self) -> Option<gcc::ClientMonitorData> {
        if self.displays.len() < 2 {
            return None;
        }
        Some(gcc::ClientMonitorData {
            monitors: self
                .displays
                .iter()
                .map(|d| gcc::Monitor {
                    left: d.left,
                    top: d.top,
                    // The last pixel's place, not the one after it.
                    right: d.left + d.width as i32 - 1,
                    bottom: d.top + d.height as i32 - 1,
                    flags: if d.primary { gcc::MonitorFlags::PRIMARY } else { gcc::MonitorFlags::empty() },
                })
                .collect(),
        })
    }

    /// The monitor data's extended part (each display's scale factor); none for one display, or
    /// where no display said a scale.
    pub(crate) fn monitor_extended(&self) -> Option<gcc::ClientMonitorExtendedData> {
        if self.displays.len() < 2 || self.displays.iter().all(|d| d.scale == 0) {
            return None;
        }
        Some(gcc::ClientMonitorExtendedData {
            extended_monitors_info: self
                .displays
                .iter()
                .map(|d| {
                    let scale = if d.scale == 0 { 100 } else { d.scale };
                    gcc::ExtendedMonitorInfo {
                        physical_width: 0,
                        physical_height: 0,
                        orientation: if d.width >= d.height {
                            gcc::MonitorOrientation::Landscape
                        } else {
                            gcc::MonitorOrientation::Portrait
                        },
                        desktop_scale_factor: scale,
                        device_scale_factor: device_scale(scale).value(),
                    }
                })
                .collect(),
        })
    }

    /// The layout as the display control channel sends it.
    pub(crate) fn display_control(&self) -> ironrdp_pdu::ironrdp_core::EncodeResult<DisplayControlMonitorLayout> {
        let mut entries = Vec::with_capacity(self.displays.len());
        for d in &self.displays {
            let mut entry = if d.primary {
                MonitorLayoutEntry::new_primary(d.width, d.height)?
            } else {
                MonitorLayoutEntry::new_secondary(d.width, d.height)?.with_position(d.left, d.top)?
            };
            if d.scale != 0 {
                entry = entry.with_desktop_scale_factor(d.scale)?.with_device_scale_factor(device_scale(d.scale));
            }
            entries.push(entry);
        }
        DisplayControlMonitorLayout::new(&entries)
    }
}

/// A scale factor as a server takes it: 0 (none said), or 100 to 500 percent.
fn checked_scale(scale: u32) -> u32 {
    if scale == 0 { 0 } else { MonitorLayoutEntry::adjust_desktop_scale_factor(scale) }
}

/// The device scale factor that goes with a desktop scale factor (one of the three there are).
fn device_scale(desktop_scale: u32) -> DeviceScaleFactor {
    match desktop_scale {
        0..=129 => DeviceScaleFactor::Scale100Percent,
        130..=169 => DeviceScaleFactor::Scale140Percent,
        _ => DeviceScaleFactor::Scale180Percent,
    }
}

/// The largest picture a session holds, which follows from what it asked for: one display's
/// ceilings ([MAX_PIXELS], [MAX_DIMENSION]) until it asks for several, then the rectangle around
/// them. Read wherever the server names a size (the session's own, a reactivation's, the graphics
/// pipeline's reset and its surfaces), before anything of that size is allocated.
#[derive(Debug)]
pub struct Limits {
    pixels: AtomicUsize,
    side: AtomicU32,
}

impl Default for Limits {
    fn default() -> Self {
        Self { pixels: AtomicUsize::new(MAX_PIXELS), side: AtomicU32::new(MAX_DIMENSION.into()) }
    }
}

impl Limits {
    pub(crate) fn for_layout(layout: &Layout) -> Self {
        let limits = Self::default();
        limits.allow(layout);
        limits
    }

    /// The most pixels a picture or a surface may have.
    pub(crate) fn pixels(&self) -> usize {
        self.pixels.load(Ordering::Acquire)
    }

    /// The longest side.
    pub(crate) fn side(&self) -> u32 {
        self.side.load(Ordering::Acquire)
    }

    /// [layout] was asked for: its desktop is allowed from now on, with what was allowed before
    /// (the server still has the old one until it answers).
    pub(crate) fn allow(&self, layout: &Layout) {
        let (w, h) = layout.size();
        self.pixels.fetch_max(layout.pixels().max(MAX_PIXELS), Ordering::AcqRel);
        self.side.fetch_max(w.max(h).max(MAX_DIMENSION.into()), Ordering::AcqRel);
    }

    /// The server took [layout]: no more than it from now on.
    pub(crate) fn settle(&self, layout: &Layout) {
        let (w, h) = layout.size();
        self.pixels.store(layout.pixels().max(MAX_PIXELS), Ordering::Release);
        self.side.store(w.max(h).max(MAX_DIMENSION.into()), Ordering::Release);
    }

    /// Whether a picture of this size is within the ceilings.
    pub(crate) fn takes(&self, width: u32, height: u32) -> bool {
        width != 0
            && height != 0
            && width <= self.side()
            && height <= self.side()
            && u64::from(width) * u64::from(height) <= self.pixels() as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(x: i32, y: i32, width: u32, height: u32) -> DisplaySpec {
        DisplaySpec { x, y, width, height, scale: 0, primary: false }
    }

    #[test]
    fn one_display_is_what_a_session_asked_before_and_sends_no_monitor_data() {
        let layout = Layout::of(&[spec(500, 500, 1281, 801)]).unwrap();
        // Brought into what a server takes: the width even.
        assert_eq!(layout.size(), (1280, 801));
        assert_eq!(layout.rects(), vec![[0, 0, 1280, 801]]);
        assert_eq!(layout.count(), 1);
        assert!(layout.monitor_data().is_none());
        assert!(layout.monitor_extended().is_none());
        assert_eq!(layout, Layout::single(1281, 801, 0));
        // Too large a display is scaled down, as before.
        let large = Layout::single(8000, 8000, 0);
        assert!(large.pixels() <= MAX_PIXELS);
    }

    #[test]
    fn displays_side_by_side_are_one_desktop_with_the_first_as_primary() {
        let layout = Layout::of(&[spec(0, 0, 1920, 1080), spec(1920, 0, 1920, 1080), spec(3840, 0, 1280, 1024)]).unwrap();
        assert_eq!(layout.size(), (5120, 1080));
        assert_eq!(layout.rects(), vec![[0, 0, 1920, 1080], [1920, 0, 1920, 1080], [3840, 0, 1280, 1024]]);
        let data = layout.monitor_data().unwrap();
        assert_eq!(data.monitors.len(), 3);
        assert_eq!((data.monitors[0].left, data.monitors[0].top), (0, 0));
        assert_eq!((data.monitors[0].right, data.monitors[0].bottom), (1919, 1079), "the last pixel, not the one after");
        assert_eq!(data.monitors[0].flags, gcc::MonitorFlags::PRIMARY);
        assert_eq!(data.monitors[1].flags, gcc::MonitorFlags::empty());
        assert_eq!((data.monitors[2].left, data.monitors[2].right), (3840, 5119));
        assert_eq!(layout.display_control().unwrap().monitors().len(), 3);
        assert!(layout.monitor_extended().is_none(), "no scale was said");
    }

    #[test]
    fn a_display_left_of_or_above_the_primary_has_a_place_below_zero_and_the_picture_starts_at_it() {
        // The primary in the middle, one to its left and lower, one above it.
        let specs = [
            spec(-1280, 200, 1280, 1024),
            DisplaySpec { primary: true, ..spec(0, 0, 1920, 1080) },
            spec(0, -1080, 1920, 1080),
        ];
        let layout = Layout::of(&specs).unwrap();
        assert_eq!(layout.size(), (3200, 2304));
        // In the picture's pixels: nothing below zero.
        assert_eq!(layout.rects(), vec![[0, 1280, 1280, 1024], [1280, 1080, 1920, 1080], [1280, 0, 1920, 1080]]);
        let data = layout.monitor_data().unwrap();
        assert_eq!((data.monitors[0].left, data.monitors[0].top), (-1280, 200));
        assert_eq!((data.monitors[1].left, data.monitors[1].top), (0, 0));
        assert_eq!(data.monitors[1].flags, gcc::MonitorFlags::PRIMARY);
        assert_eq!((data.monitors[2].left, data.monitors[2].top), (0, -1080));
        // From any origin: the same layout moved is the same layout.
        let moved: Vec<DisplaySpec> = specs.iter().map(|s| DisplaySpec { x: s.x + 7000, y: s.y - 3000, ..*s }).collect();
        assert_eq!(Layout::of(&moved).unwrap(), layout);
    }

    #[test]
    fn where_none_or_several_say_primary_the_first_is() {
        let none = Layout::of(&[spec(0, 0, 800, 600), spec(800, 0, 800, 600)]).unwrap();
        assert_eq!(none.monitor_data().unwrap().monitors[0].flags, gcc::MonitorFlags::PRIMARY);
        let both = [DisplaySpec { primary: true, ..spec(0, 0, 800, 600) }, DisplaySpec { primary: true, ..spec(800, 0, 800, 600) }];
        let layout = Layout::of(&both).unwrap();
        let flags: Vec<_> = layout.monitor_data().unwrap().monitors.iter().map(|m| m.flags).collect();
        assert_eq!(flags, vec![gcc::MonitorFlags::PRIMARY, gcc::MonitorFlags::empty()]);
    }

    #[test]
    fn layouts_a_server_does_not_take_are_refused_with_why() {
        let refused = |specs: &[DisplaySpec]| Layout::of(specs).unwrap_err();
        assert!(refused(&[]).contains("no display"));
        let five: Vec<DisplaySpec> = (0..5).map(|i| spec(i * 800, 0, 800, 600)).collect();
        assert!(refused(&five).contains("at most 4"), "{}", refused(&five));
        // One over another.
        assert!(refused(&[spec(0, 0, 800, 600), spec(400, 0, 800, 600)]).contains("not a layout"));
        // One that touches no other.
        assert!(refused(&[spec(0, 0, 800, 600), spec(900, 0, 800, 600)]).contains("not a layout"));
        // A size that would have to be changed (an odd width, too small, too large): its
        // neighbours would no longer touch it.
        assert!(refused(&[spec(0, 0, 801, 600), spec(801, 0, 800, 600)]).contains("display 1"));
        assert!(refused(&[spec(0, 0, 800, 600), spec(800, 0, 100, 600)]).contains("display 2"));
        assert!(refused(&[spec(0, 0, 800, 600), spec(800, 0, 8192, 8192)]).contains("display 2"));
        // Places that cannot be told apart from the first.
        assert!(refused(&[spec(i32::MIN, 0, 800, 600), spec(i32::MAX, 0, 800, 600)]).contains("too far"));
    }

    #[test]
    fn the_rectangle_around_the_displays_is_what_is_counted_and_four_of_the_largest_is_the_most() {
        // Four displays of the largest size in a row: exactly the ceiling.
        let row: Vec<DisplaySpec> = (0..4).map(|i| spec(i * 3840, 0, 3840, 2160)).collect();
        let layout = Layout::of(&row).unwrap();
        assert_eq!(layout.pixels(), MAX_DESKTOP_PIXELS);
        // Three set corner to corner hold fewer pixels than that, but the rectangle around them
        // (which the app holds as one picture) is nine displays' worth.
        let stairs = [spec(0, 0, 3840, 2160), spec(3840, 2160, 3840, 2160), spec(7680, 4320, 3840, 2160)];
        let why = Layout::of(&stairs).unwrap_err();
        assert!(why.contains("11520 by 6480"), "{why}");
        // A row longer than the protocol's desktop.
        let wide: Vec<DisplaySpec> = (0..4).map(|i| spec(i * 8192, 0, 8192, 200)).collect();
        assert!(Layout::of(&wide).unwrap_err().contains("at most 32766"));
    }

    #[test]
    fn a_scale_goes_out_with_each_display_between_100_and_500() {
        let specs = [DisplaySpec { scale: 150, ..spec(0, 0, 2560, 1440) }, DisplaySpec { scale: 900, ..spec(2560, 0, 1920, 1080) }];
        let layout = Layout::of(&specs).unwrap();
        assert_eq!(layout.scale(), 150);
        let extended = layout.monitor_extended().unwrap();
        let scales: Vec<(u32, u32)> =
            extended.extended_monitors_info.iter().map(|m| (m.desktop_scale_factor, m.device_scale_factor)).collect();
        assert_eq!(scales, vec![(150, 140), (500, 180)]);
        let entries = layout.display_control().unwrap();
        assert_eq!(entries.monitors()[0].desktop_scale_factor(), Some(150));
        assert_eq!(entries.monitors()[1].desktop_scale_factor(), Some(500));
        // One said and one not: the one that did not is at 100.
        let mixed = Layout::of(&[DisplaySpec { scale: 200, ..spec(0, 0, 800, 600) }, spec(800, 0, 800, 600)]).unwrap();
        assert_eq!(mixed.monitor_extended().unwrap().extended_monitors_info[1].desktop_scale_factor, 100);
        assert_eq!(Layout::single(1280, 800, 50).scale(), 100);
        assert_eq!(Layout::single(1280, 800, 0).scale(), 0);
    }

    #[test]
    fn the_ceilings_are_one_displays_until_several_are_asked_for() {
        let limits = Limits::default();
        assert_eq!((limits.pixels(), limits.side()), (MAX_PIXELS, u32::from(MAX_DIMENSION)));
        assert!(limits.takes(3840, 2160));
        assert!(!limits.takes(3842, 2160));
        assert!(!limits.takes(0, 600));
        assert!(!limits.takes(8194, 200));

        // Two displays side by side: their desktop is allowed, and no more than it.
        let two = Layout::of(&[spec(0, 0, 3840, 2160), spec(3840, 0, 3840, 2160)]).unwrap();
        let limits = Limits::for_layout(&two);
        assert!(limits.takes(7680, 2160));
        assert!(!limits.takes(7682, 2160));
        assert!(!limits.takes(11520, 2160));

        // A smaller layout asked for while the larger one is still the server's: both hold
        // until the server has answered, then the new one alone.
        let one = Layout::single(1920, 1080, 0);
        limits.allow(&one);
        assert!(limits.takes(7680, 2160));
        limits.settle(&one);
        assert!(!limits.takes(7680, 2160));
        assert!(limits.takes(3840, 2160), "never under one display's ceiling");

        // A larger one asked for is allowed at once.
        let four: Vec<DisplaySpec> = (0..4).map(|i| spec(i * 3840, 0, 3840, 2160)).collect();
        limits.allow(&Layout::of(&four).unwrap());
        assert!(limits.takes(15360, 2160));
        assert_eq!(limits.pixels(), MAX_DESKTOP_PIXELS);
    }
}
