#if os(macOS)
import Foundation
import AppKit
import CoreText
import Testing

@testable import SwiftTerm

/// The rasterizer tells a glyph with no ink apart from a failed draw.
///
/// The Metal renderer caches what the rasterizer returns, and a blank glyph
/// used to come back as nil — the same answer as a failure, which is not
/// cached so it can be retried. Every blank cell shapes to a space, so each row
/// rebuild asked CoreText for the space's bounds again (most of the renderer's
/// rasterizer time in a profile of an idle multi-pane app).
struct GlyphRasterTests {
    private func glyph(_ character: Character, in font: CTFont) -> CGGlyph {
        var chars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        return glyphs[0]
    }

    @Test func aSpaceIsBlankNotAFailure() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) as CTFont
        let raster = CoreTextGlyphRasterizer().rasterize(font: font, glyph: glyph(" ", in: font))
        guard case .blank = raster else {
            Issue.record("expected .blank for a space, got \(String(describing: raster))")
            return
        }
    }

    @Test func aLetterHasABitmap() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) as CTFont
        let raster = CoreTextGlyphRasterizer().rasterize(font: font, glyph: glyph("A", in: font))
        guard case .bitmap(let bitmap) = raster else {
            Issue.record("expected a bitmap for A, got \(String(describing: raster))")
            return
        }
        #expect(bitmap.width > 0 && bitmap.height > 0)
    }
}
#endif
