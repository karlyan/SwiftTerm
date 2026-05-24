#if os(macOS)
import Foundation
import AppKit
import CoreText
import Testing

@testable import SwiftTerm

/// Regression test for the Metal renderer's glyph-cache key.
///
/// CoreText cascade fallback can return several *distinct* physical fonts that
/// all report the same PostScript name. With a JetBrains Mono + PingFang SC
/// cascade, enclosed numbers like `①` (which PingFang itself lacks) resolve to a
/// system-fallback font that *also* calls itself "PingFangSC-Regular" but whose
/// glyph table differs from the cascade PingFang used for normal CJK. Keying the
/// glyph cache by PostScript name collides them, so `①` was rasterized in the
/// wrong font and rendered as a random CJK character. GlyphKey must key by the
/// CTFont instance (CFEqual) instead.
final class GlyphKeyFontIdentityTests {

    private func runFont(_ text: String) -> CTFont? {
        let size: CGFloat = 16
        let base = NSFont(name: "JetBrains Mono NL", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard let cjk = NSFont(name: "PingFang SC", size: size) else { return nil }
        let desc = base.fontDescriptor.addingAttributes([.cascadeList: [cjk.fontDescriptor]])
        guard let font = NSFont(descriptor: desc, size: size) else { return nil }
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let runs = (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attr)) as? [CTRun]) ?? []
        guard let run = runs.first,
              let attrs = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
              let rf = attrs[.font] as? NSFont else { return nil }
        return rf as CTFont
    }

    @Test func glyphKeyDistinguishesSameNamedFallbackFonts() throws {
        guard let fEnclosed = runFont("\u{2460}"),   // ① — system fallback instance
              let fCJK = runFont("控")                // cascade PingFang instance
        else {
            // PingFang unavailable on this host; nothing to assert.
            return
        }

        // Same reported name, but genuinely different font instances.
        #expect((CTFontCopyPostScriptName(fEnclosed) as String)
                == (CTFontCopyPostScriptName(fCJK) as String))
        guard !CFEqual(fEnclosed, fCJK) else {
            // Host resolved both to the same instance — the collision this guards
            // against can't occur here, so the test is not meaningful.
            return
        }

        // The keys must not collide even at the same glyph index.
        let kEnclosed = GlyphKey(font: fEnclosed, glyph: 608)
        let kCJK = GlyphKey(font: fCJK, glyph: 608)
        #expect(kEnclosed != kCJK)

        var cache: [GlyphKey: String] = [:]
        cache[kEnclosed] = "enclosed"
        cache[kCJK] = "cjk"
        #expect(cache[kEnclosed] == "enclosed")
        #expect(cache[kCJK] == "cjk")
        #expect(cache.count == 2)
    }
}
#endif
