//! 配对二维码在壳里生成（白屏修复，refs #1120）。
//!
//! 前端开了 `freezePrototype`，npm `qrcode` 在加载时给继承来的 `toString` 赋值，
//! 原型冻结后直接抛错、整个界面渲染不出来。二维码改由成熟的 `qrcode` crate 生成
//! SVG，网页只负责显示，前端少一个第三方库，原型冻结照样保留。

use qrcode::render::svg;
use qrcode::{EcLevel, QrCode};

/// 低纠错 L：配对串较长时 L 更好扫（沿用原前端参数）。2 模块静区。
pub fn svg(text: &str) -> Result<String, String> {
    let code = QrCode::with_error_correction_level(text.as_bytes(), EcLevel::L)
        .map_err(|e| format!("qr: {e}"))?;
    Ok(code
        .render::<svg::Color>()
        .quiet_zone(true)
        .min_dimensions(720, 720)
        .dark_color(svg::Color("#000000"))
        .light_color(svg::Color("#ffffff"))
        .build())
}

#[cfg(test)]
mod tests {
    /// 反证：返回空串或非 SVG → 红；超长输入不 panic、走 Err。
    #[test]
    fn renders_svg_and_rejects_oversize() {
        let s = super::svg("ppf://pair/v3?t=abc&n=xyz").unwrap();
        assert!(s.contains("<svg") && s.contains("</svg>"), "{s}");
        assert!(super::svg(&"x".repeat(10_000)).is_err());
    }
}
