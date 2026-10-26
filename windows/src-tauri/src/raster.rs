//! A tiny software rasterizer for the selector overlay: alpha-blended, antialiased rectangles and
//! rounded rectangles on a top-down BGRA buffer. Text is left to GDI.

use crate::layout::Rect;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RectF {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl RectF {
    pub fn new(x: f32, y: f32, w: f32, h: f32) -> RectF {
        RectF { x, y, w, h }
    }

    pub fn inset(&self, d: f32) -> RectF {
        RectF::new(self.x + d, self.y + d, self.w - 2.0 * d, self.h - 2.0 * d)
    }

    /// Integer bounds covering this rectangle, grown by `margin`.
    pub fn bounds(&self, margin: f32) -> Rect {
        let x0 = (self.x - margin).floor() as i32;
        let y0 = (self.y - margin).floor() as i32;
        let x1 = (self.x + self.w + margin).ceil() as i32;
        let y1 = (self.y + self.h + margin).ceil() as i32;
        Rect::new(x0, y0, x1 - x0, y1 - y0)
    }
}

impl From<Rect> for RectF {
    fn from(r: Rect) -> RectF {
        RectF::new(r.x as f32, r.y as f32, r.w as f32, r.h as f32)
    }
}

/// Signed distance from a point to a rounded rectangle (negative inside).
pub fn rrect_sdf(px: f32, py: f32, r: RectF, radius: f32) -> f32 {
    let radius = radius.min(r.w / 2.0).min(r.h / 2.0).max(0.0);
    let (cx, cy) = (r.x + r.w / 2.0, r.y + r.h / 2.0);
    let qx = (px - cx).abs() - (r.w / 2.0 - radius);
    let qy = (py - cy).abs() - (r.h / 2.0 - radius);
    let outside = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt();
    outside + qx.max(qy).min(0.0) - radius
}

fn coverage(sdf: f32) -> f32 {
    (0.5 - sdf).clamp(0.0, 1.0)
}

/// Opaque colour as `[r, g, b]`.
pub type Rgb = [u8; 3];
pub const WHITE: Rgb = [255, 255, 255];
pub const BLACK: Rgb = [0, 0, 0];

pub struct Canvas<'a> {
    pub px: &'a mut [u8],
    pub w: i32,
    pub h: i32,
}

impl Canvas<'_> {
    fn clip(&self, r: Rect) -> Rect {
        r.intersect(&Rect::new(0, 0, self.w, self.h))
    }

    #[inline]
    pub fn blend(&mut self, x: i32, y: i32, c: Rgb, alpha: f32) {
        if alpha <= 0.0 || x < 0 || y < 0 || x >= self.w || y >= self.h {
            return;
        }
        let i = ((y * self.w + x) * 4) as usize;
        let a = alpha.min(1.0);
        for (k, &v) in [c[2], c[1], c[0]].iter().enumerate() {
            let d = self.px[i + k] as f32;
            self.px[i + k] = (d + (v as f32 - d) * a + 0.5) as u8;
        }
    }

    #[cfg(test)]
    pub fn get(&self, x: i32, y: i32) -> Rgb {
        let i = ((y * self.w + x) * 4) as usize;
        [self.px[i + 2], self.px[i + 1], self.px[i]]
    }

    pub fn fill_rect(&mut self, r: Rect, c: Rgb, alpha: f32) {
        let r = self.clip(r);
        for y in r.y..r.bottom() {
            for x in r.x..r.right() {
                self.blend(x, y, c, alpha);
            }
        }
    }

    /// A `width`-pixel frame drawn inside `r`.
    pub fn stroke_rect(&mut self, r: Rect, width: i32, c: Rgb, alpha: f32) {
        let width = width.max(1).min(r.w / 2 + 1).min(r.h / 2 + 1);
        self.fill_rect(Rect::new(r.x, r.y, r.w, width), c, alpha);
        self.fill_rect(Rect::new(r.x, r.bottom() - width, r.w, width), c, alpha);
        self.fill_rect(Rect::new(r.x, r.y + width, width, r.h - 2 * width), c, alpha);
        self.fill_rect(Rect::new(r.right() - width, r.y + width, width, r.h - 2 * width), c, alpha);
    }

    pub fn fill_round_rect(&mut self, r: RectF, radius: f32, c: Rgb, alpha: f32) {
        let b = self.clip(r.bounds(1.0));
        for y in b.y..b.bottom() {
            for x in b.x..b.right() {
                let cov = coverage(rrect_sdf(x as f32 + 0.5, y as f32 + 0.5, r, radius));
                self.blend(x, y, c, alpha * cov);
            }
        }
    }

    /// Antialiased outline of `width` pixels inside the rounded rectangle.
    pub fn stroke_round_rect(&mut self, r: RectF, radius: f32, width: f32, c: Rgb, alpha: f32) {
        let inner = r.inset(width);
        let b = self.clip(r.bounds(1.0));
        for y in b.y..b.bottom() {
            for x in b.x..b.right() {
                let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
                let ring = coverage(rrect_sdf(fx, fy, r, radius)) - coverage(rrect_sdf(fx, fy, inner, radius - width));
                self.blend(x, y, c, alpha * ring.max(0.0));
            }
        }
    }

    /// Soft shadow: full `alpha` inside, fading out over `blur` pixels.
    pub fn shadow(&mut self, r: RectF, radius: f32, blur: f32, alpha: f32) {
        let b = self.clip(r.bounds(blur + 1.0));
        for y in b.y..b.bottom() {
            for x in b.x..b.right() {
                let d = rrect_sdf(x as f32 + 0.5, y as f32 + 0.5, r, radius);
                let t = ((d + blur * 0.5) / (blur * 1.5)).clamp(0.0, 1.0);
                self.blend(x, y, BLACK, alpha * (1.0 - t * t * (3.0 - 2.0 * t)));
            }
        }
    }
}

/// Copies `area` from `src` to `dst` (same size, BGRA), darkened by `keep`/256 outside `cutout`.
pub fn compose_dimmed(src: &[u8], dst: &mut [u8], width: i32, area: Rect, cutout: Option<Rect>, keep: u32) {
    let area = area.intersect(&Rect::new(0, 0, width, (src.len() / (width.max(1) as usize * 4)) as i32));
    for y in area.y..area.bottom() {
        let row = (y * width) as usize * 4;
        let (cx0, cx1) = match cutout {
            Some(c) if y >= c.y && y < c.bottom() => (c.x.max(area.x).min(area.right()), c.right().min(area.right()).max(area.x)),
            _ => (area.x, area.x),
        };
        for (from, to, dim) in [(area.x, cx0, true), (cx0, cx1, false), (cx1.max(cx0), area.right(), true)] {
            if to <= from {
                continue;
            }
            let (s, e) = (row + from as usize * 4, row + to as usize * 4);
            if dim {
                for (d, &v) in dst[s..e].iter_mut().zip(&src[s..e]) {
                    *d = ((v as u32 * keep) >> 8) as u8;
                }
            } else {
                dst[s..e].copy_from_slice(&src[s..e]);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn canvas(buf: &mut Vec<u8>, w: i32, h: i32) -> Canvas<'_> {
        buf.resize((w * h * 4) as usize, 0);
        Canvas { px: buf, w, h }
    }

    #[test]
    fn sdf_signs() {
        let r = RectF::new(0.0, 0.0, 10.0, 10.0);
        assert!(rrect_sdf(5.0, 5.0, r, 2.0) < 0.0);
        assert!(rrect_sdf(15.0, 5.0, r, 2.0) > 0.0);
        assert!((rrect_sdf(10.0, 5.0, r, 2.0)).abs() < 1e-5);
        // The corner is cut by the radius.
        assert!(rrect_sdf(0.2, 0.2, r, 4.0) > 0.0);
        assert!(rrect_sdf(0.2, 0.2, r, 0.0) < 0.0);
    }

    #[test]
    fn blending_and_clipping() {
        let mut buf = Vec::new();
        let mut c = canvas(&mut buf, 4, 4);
        c.fill_rect(Rect::new(-2, -2, 4, 4), WHITE, 1.0);
        assert_eq!(c.get(1, 1), WHITE);
        assert_eq!(c.get(2, 2), BLACK);
        c.fill_rect(Rect::new(2, 2, 10, 10), WHITE, 0.5);
        assert_eq!(c.get(3, 3), [128, 128, 128]);
    }

    #[test]
    fn stroke_stays_inside() {
        let mut buf = Vec::new();
        let mut c = canvas(&mut buf, 6, 6);
        c.stroke_rect(Rect::new(1, 1, 4, 4), 1, WHITE, 1.0);
        assert_eq!(c.get(1, 1), WHITE);
        assert_eq!(c.get(4, 4), WHITE);
        assert_eq!(c.get(2, 2), BLACK);
        assert_eq!(c.get(0, 0), BLACK);
        assert_eq!(c.get(5, 5), BLACK);
    }

    #[test]
    fn round_rect_antialiases_corners_only() {
        let mut buf = Vec::new();
        let mut c = canvas(&mut buf, 20, 20);
        c.fill_round_rect(RectF::new(2.0, 2.0, 16.0, 16.0), 6.0, WHITE, 1.0);
        assert_eq!(c.get(10, 10), WHITE);
        assert_eq!(c.get(10, 2), WHITE);
        assert_eq!(c.get(2, 2), BLACK);
        let corner = c.get(3, 4)[0];
        assert!(corner > 0 && corner < 255, "{corner}");
    }

    #[test]
    fn shadow_fades_out() {
        let mut buf = Vec::new();
        let mut c = canvas(&mut buf, 40, 40);
        c.fill_rect(Rect::new(0, 0, 40, 40), WHITE, 1.0);
        c.shadow(RectF::new(10.0, 10.0, 20.0, 20.0), 4.0, 6.0, 0.5);
        assert_eq!(c.get(20, 20), [128, 128, 128]);
        assert_eq!(c.get(0, 20), WHITE);
        let edge = c.get(31, 20)[0];
        assert!(edge > 128 && edge < 255, "{edge}");
    }

    #[test]
    fn compose_dims_around_the_cutout() {
        let src = vec![200u8; 4 * 4 * 4];
        let mut dst = vec![0u8; 4 * 4 * 4];
        compose_dimmed(&src, &mut dst, 4, Rect::new(0, 0, 4, 4), Some(Rect::new(1, 1, 2, 2)), 128);
        let at = |x: usize, y: usize| dst[(y * 4 + x) * 4];
        assert_eq!(at(0, 0), 100);
        assert_eq!(at(1, 1), 200);
        assert_eq!(at(2, 2), 200);
        assert_eq!(at(3, 2), 100);
        assert_eq!(at(1, 3), 100);
        // Only the requested area is touched.
        let mut part = vec![0u8; 4 * 4 * 4];
        compose_dimmed(&src, &mut part, 4, Rect::new(2, 0, 2, 1), None, 256);
        assert_eq!((part[0], part[8]), (0, 200));
    }
}
