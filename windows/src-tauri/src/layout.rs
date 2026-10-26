//! Window geometry in physical pixels: the shelf stack, pinned images and the selector's labels.
//! Sizes from the design are in points (DIPs) and get multiplied by the monitor scale.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Rect {
        Rect { x, y, w, h }
    }

    /// The rectangle spanned by two corners, in either order.
    pub fn spanning(a: (i32, i32), b: (i32, i32)) -> Rect {
        Rect::new(a.0.min(b.0), a.1.min(b.1), (a.0 - b.0).abs(), (a.1 - b.1).abs())
    }

    pub fn right(&self) -> i32 {
        self.x + self.w
    }

    pub fn bottom(&self) -> i32 {
        self.y + self.h
    }

    pub fn is_empty(&self) -> bool {
        self.w <= 0 || self.h <= 0
    }

    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x && y >= self.y && x < self.right() && y < self.bottom()
    }

    pub fn intersect(&self, o: &Rect) -> Rect {
        let x = self.x.max(o.x);
        let y = self.y.max(o.y);
        let r = self.right().min(o.right());
        let b = self.bottom().min(o.bottom());
        if r <= x || b <= y {
            Rect::default()
        } else {
            Rect::new(x, y, r - x, b - y)
        }
    }

    pub fn union(&self, o: &Rect) -> Rect {
        if self.is_empty() {
            return *o;
        }
        if o.is_empty() {
            return *self;
        }
        let x = self.x.min(o.x);
        let y = self.y.min(o.y);
        Rect::new(x, y, self.right().max(o.right()) - x, self.bottom().max(o.bottom()) - y)
    }

    pub fn inset(&self, d: i32) -> Rect {
        Rect::new(self.x + d, self.y + d, self.w - 2 * d, self.h - 2 * d)
    }

    pub fn offset(&self, dx: i32, dy: i32) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }
}

/// A monitor in virtual-screen physical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Monitor {
    pub rect: Rect,
    pub work: Rect,
    pub scale: f64,
}

pub fn monitor_at(monitors: &[Monitor], x: i32, y: i32) -> Option<&Monitor> {
    monitors.iter().find(|m| m.rect.contains(x, y))
}

fn px(points: f64, scale: f64) -> i32 {
    (points * scale).round() as i32
}

// ---------- shelf ----------

pub const SHELF_MAX_ITEMS: usize = 5;
pub const CARD_WIDTH: f64 = 200.0;
const SHELF_MARGIN: f64 = 16.0;
const SHELF_SPACING: f64 = 10.0;
/// Room around the cards so their shadows are not clipped by the window.
const SHADOW_ROOM: f64 = 18.0;

/// Card height in points: `clamp(200 × h / w, 72, 150)`.
pub fn card_height(width: u32, height: u32) -> f64 {
    let aspect = if width > 0 { height as f64 / width as f64 } else { 0.6 };
    (CARD_WIDTH * aspect).clamp(72.0, 150.0)
}

/// The shelf window: bottom-left of the work area, cards stacked upwards, shadow room on every side.
pub fn shelf_frame(items: &[(u32, u32)], work: Rect, scale: f64) -> Rect {
    let content: f64 = items.iter().map(|&(w, h)| card_height(w, h)).sum::<f64>()
        + SHELF_SPACING * items.len().saturating_sub(1) as f64;
    let max_height = work.h as f64 / scale - SHELF_MARGIN;
    let height = (content + SHADOW_ROOM * 2.0).min(max_height);
    let width = CARD_WIDTH + SHADOW_ROOM * 2.0;
    let bottom = work.bottom() + px(SHADOW_ROOM - SHELF_MARGIN, scale);
    let h = px(height, scale);
    Rect::new(work.x + px(SHELF_MARGIN - SHADOW_ROOM, scale), bottom - h, px(width, scale), h)
}

/// Whether the shelf should jump to the monitor under the cursor.
pub fn should_follow(anchor: Option<&Monitor>, under_cursor: Option<&Monitor>, button_down: bool, hovering: bool) -> bool {
    match (anchor, under_cursor) {
        (Some(a), Some(c)) => a.rect != c.rect && !button_down && !hovering,
        (None, Some(_)) => !button_down && !hovering,
        _ => false,
    }
}

// ---------- pins ----------

/// A pinned image at its size in points (at most 60 % of the work area), centred on the work area.
pub fn pin_frame(width: u32, height: u32, image_scale: f64, monitor: &Monitor) -> Rect {
    let image_scale = if image_scale > 0.0 { image_scale } else { 1.0 };
    let (w, h) = (width.max(1) as f64 / image_scale, height.max(1) as f64 / image_scale);
    let (max_w, max_h) = (monitor.work.w as f64 / monitor.scale * 0.6, monitor.work.h as f64 / monitor.scale * 0.6);
    let fit = (max_w / w).min(max_h / h).min(1.0);
    let (pw, ph) = (px(w * fit, monitor.scale).max(1), px(h * fit, monitor.scale).max(1));
    Rect::new(monitor.work.x + (monitor.work.w - pw) / 2, monitor.work.y + (monitor.work.h - ph) / 2, pw, ph)
}

// ---------- selector ----------

/// Loupe box (side in pixels) next to the pointer, flipped to stay on screen. The coordinate tag
/// below it needs `tag_room` more pixels.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn loupe_origin(p: (i32, i32), side: i32, gap: i32, tag_room: i32, bounds: Rect) -> (i32, i32) {
    let mut x = p.0 + gap;
    let mut y = p.1 + gap;
    if x + side > bounds.right() {
        x = p.0 - gap - side;
    }
    if y + side + tag_room > bounds.bottom() {
        y = p.1 - gap - side - tag_room;
    }
    (x, y)
}

/// Size tag below the selection, or inside its bottom edge when there is no room.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn size_tag_origin(sel: Rect, tag_w: i32, tag_h: i32, gap: i32, edge: i32, bounds: Rect) -> (i32, i32) {
    let mut y = sel.bottom() + gap;
    if y + tag_h > bounds.bottom() {
        y = sel.bottom() - tag_h - gap;
    }
    let x = sel.x.min(bounds.right() - tag_w - edge).max(bounds.x + edge);
    (x, y)
}

/// The topmost window containing the point (targets are front to back).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn window_at(targets: &[Rect], x: i32, y: i32) -> Option<Rect> {
    targets.iter().copied().find(|t| t.contains(x, y))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn monitor(x: i32, scale: f64) -> Monitor {
        Monitor { rect: Rect::new(x, 0, 1920, 1080), work: Rect::new(x, 0, 1920, 1040), scale }
    }

    #[test]
    fn rect_basics() {
        assert_eq!(Rect::spanning((10, 50), (4, 20)), Rect::new(4, 20, 6, 30));
        let a = Rect::new(0, 0, 10, 10);
        assert_eq!(a.intersect(&Rect::new(5, 5, 10, 10)), Rect::new(5, 5, 5, 5));
        assert!(a.intersect(&Rect::new(10, 0, 5, 5)).is_empty());
        assert_eq!(a.union(&Rect::new(20, 20, 1, 1)), Rect::new(0, 0, 21, 21));
        assert_eq!(Rect::default().union(&a), a);
        assert!(a.contains(0, 0) && !a.contains(10, 5));
    }

    #[test]
    fn card_heights_are_clamped() {
        assert_eq!(card_height(1920, 1080), 112.5);
        assert_eq!(card_height(2000, 100), 72.0);
        assert_eq!(card_height(100, 2000), 150.0);
        assert_eq!(card_height(0, 0), 120.0);
    }

    #[test]
    fn shelf_sits_bottom_left_with_shadow_room() {
        let m = monitor(0, 1.0);
        let f = shelf_frame(&[(1920, 1080)], m.work, 1.0);
        // 112.5 card + 2 × 18 room; bottom edge 2 px below the work area (16 margin − 18 room).
        assert_eq!(f, Rect::new(-2, 1042 - 149, 236, 149));
        let two = shelf_frame(&[(1920, 1080), (100, 100)], m.work, 1.0);
        assert_eq!(two.h, (112.5f64 + 150.0 + 10.0 + 36.0).round() as i32);
        assert_eq!(two.bottom(), f.bottom());
    }

    #[test]
    fn shelf_scales_and_caps_its_height() {
        let m = Monitor { rect: Rect::new(1920, 0, 2880, 1620), work: Rect::new(1920, 0, 2880, 1560), scale: 1.5 };
        let f = shelf_frame(&[(100, 100)], m.work, 1.5);
        assert_eq!(f.x, 1920 - 3);
        assert_eq!(f.w, 354);
        assert_eq!(f.h, 279);
        let tall = shelf_frame(&[(100, 100); 20], Rect::new(0, 0, 400, 300), 1.0);
        assert_eq!(tall.h, 284);
    }

    #[test]
    fn follow_rules() {
        let (a, b) = (monitor(0, 1.0), monitor(1920, 1.0));
        assert!(should_follow(Some(&a), Some(&b), false, false));
        assert!(!should_follow(Some(&a), Some(&a), false, false));
        assert!(!should_follow(Some(&a), Some(&b), true, false));
        assert!(!should_follow(Some(&a), Some(&b), false, true));
        assert!(!should_follow(Some(&a), None, false, false));
        assert!(should_follow(None, Some(&b), false, false));
    }

    #[test]
    fn monitor_lookup() {
        let ms = [monitor(0, 1.0), monitor(1920, 2.0)];
        assert_eq!(monitor_at(&ms, 2000, 10).map(|m| m.scale), Some(2.0));
        assert!(monitor_at(&ms, -5, 10).is_none());
    }

    #[test]
    fn pins_use_points_and_fit_the_work_area() {
        let m = monitor(0, 1.0);
        // A 2× capture of 800×600 px is 400×300 pt.
        assert_eq!(pin_frame(800, 600, 2.0, &m), Rect::new(760, 370, 400, 300));
        // Too big: limited to 60 % of the work area, aspect kept.
        let big = pin_frame(4000, 1000, 1.0, &m);
        assert_eq!((big.w, big.h), (1152, 288));
        let hi = Monitor { scale: 2.0, ..monitor(0, 2.0) };
        assert_eq!(pin_frame(200, 100, 1.0, &hi).w, 400);
    }

    #[test]
    fn loupe_flips_at_edges() {
        let b = Rect::new(0, 0, 1000, 800);
        assert_eq!(loupe_origin((100, 100), 112, 20, 30, b), (120, 120));
        assert_eq!(loupe_origin((950, 100), 112, 20, 30, b), (818, 120));
        assert_eq!(loupe_origin((100, 700), 112, 20, 30, b), (120, 538));
    }

    #[test]
    fn size_tag_placement() {
        let b = Rect::new(0, 0, 1000, 800);
        assert_eq!(size_tag_origin(Rect::new(10, 10, 100, 100), 80, 20, 6, 4, b), (10, 116));
        assert_eq!(size_tag_origin(Rect::new(10, 700, 100, 95), 80, 20, 6, 4, b), (10, 769));
        assert_eq!(size_tag_origin(Rect::new(990, 10, 5, 5), 80, 20, 6, 4, b), (916, 21));
        assert_eq!(size_tag_origin(Rect::new(-3, 10, 5, 5), 80, 20, 6, 4, b), (4, 21));
    }

    #[test]
    fn window_hit_test_prefers_front() {
        let targets = [Rect::new(100, 100, 50, 50), Rect::new(0, 0, 500, 500)];
        assert_eq!(window_at(&targets, 120, 120), Some(targets[0]));
        assert_eq!(window_at(&targets, 10, 10), Some(targets[1]));
        assert_eq!(window_at(&targets, 600, 10), None);
    }
}
