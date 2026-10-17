#if os(macOS) && DEBUG
import AppKit
import Metal
import Testing

@testable import SwiftTerm

/// The Metal renderer keeps a cached row when the row is redrawn with the cells
/// and decorations it already had (TUIs erase and rewrite their whole screen
/// every frame). These pin both halves: an unchanged rewrite rebuilds nothing,
/// and every change that does not touch a cell — selection, colors, palette,
/// font, blink phase — still rebuilds the rows it affects.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalRowReuseTests {
    private static let lines = (0..<5).map { "\($0)  ⏺ Update(src/app.swift)  正在分析 ✅ ok" }

    /// A view with the Metal renderer and a first frame built.
    private func makeView() throws -> (TerminalView, MetalTerminalRenderer) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 200))
        try view.setUseMetal(true)
        let renderer = try #require(view.metalRenderer)
        view.getTerminal().feed(text: Self.lines.joined(separator: "\r\n"))
        frame(view, renderer)
        return (view, renderer)
    }

    /// Build a frame with the whole screen marked dirty — what a full-screen
    /// repaint reports — and return how many rows were rebuilt.
    @discardableResult
    private func frame(_ view: TerminalView, _ renderer: MetalTerminalRenderer) -> Int {
        let buffer = view.getTerminal().displayBuffer
        view.metalDirtyRange = buffer.yDisp...(buffer.yDisp + buffer.rows - 1)
        _ = renderer.buildDrawData(scale: 2)
        return renderer.debugRowsRebuilt
    }

    private func rewrite(_ view: TerminalView, changing row: Int? = nil) {
        var text = "\u{1b}[H"
        for (i, line) in Self.lines.enumerated() {
            text += "\u{1b}[2K" + (i == row ? line.replacingOccurrences(of: "ok", with: "OK") : line)
            if i < Self.lines.count - 1 { text += "\r\n" }
        }
        view.getTerminal().feed(text: text)
    }

    @Test func rewritingTheSameScreenRebuildsNothing() throws {
        let (view, renderer) = try makeView()
        let generation = view.getTerminal().buffer.lines[0].generation
        rewrite(view)
        #expect(view.getTerminal().buffer.lines[0].generation != generation,
                "the rewrite must move the generation, or this proves nothing")
        #expect(frame(view, renderer) == 0)
        #expect(renderer.debugRowsCached == view.getTerminal().rows)
    }

    @Test func aChangedRowIsTheOnlyOneRebuilt() throws {
        let (view, renderer) = try makeView()
        rewrite(view, changing: 2)
        #expect(frame(view, renderer) == 1)
    }

    @Test func selectingRebuildsTheSelectedRows() throws {
        let (view, renderer) = try makeView()
        view.selectAll(nil)
        #expect(frame(view, renderer) >= Self.lines.count)
    }

    @Test func aNewForegroundColorRebuilds() throws {
        let (view, renderer) = try makeView()
        view.nativeForegroundColor = .systemRed
        #expect(frame(view, renderer) >= Self.lines.count)
    }

    @Test func aNewPaletteRebuilds() throws {
        let (view, renderer) = try makeView()
        view.installColors((0..<16).map { _ in Color(red: 0x8000, green: 0x2000, blue: 0x1000) })
        #expect(frame(view, renderer) >= Self.lines.count)
    }

    @Test func aNewFontRebuilds() throws {
        let (view, renderer) = try makeView()
        view.font = NSFont.monospacedSystemFont(ofSize: view.font.pointSize + 2, weight: .regular)
        #expect(frame(view, renderer) >= Self.lines.count)
    }

    @Test func aLinkHighlightRebuildsItsRow() throws {
        let (view, renderer) = try makeView()
        view.linkHighlightMode = .hover
        frame(view, renderer)
        // Only the hovered range changes from here on.
        let row = view.getTerminal().displayBuffer.yDisp + 1
        view.linkHighlightRange = [Terminal.LinkMatch.RowRange(row: row, range: 0..<4)]
        #expect(frame(view, renderer) >= 1)
    }

    @Test func aChangeElsewhereInAWrappedParagraphRebuildsIt() throws {
        let (view, renderer) = try makeView()
        let cols = view.getTerminal().cols
        // One logical line wrapped over two rows, below the five fixture rows.
        view.getTerminal().feed(text: "\r\n" + String(repeating: "a", count: cols + 5))
        frame(view, renderer)
        // Rewrite only the continuation row.
        view.getTerminal().feed(text: "\r\u{1b}[2Kbbbbb")
        #expect(frame(view, renderer) >= 2, "both rows of the paragraph lay out together")
    }

    @Test func theBlinkPhaseRebuildsOnlyBlinkingRows() throws {
        let (view, renderer) = try makeView()
        // Row 5 blinks; rows 0–4 do not.
        view.getTerminal().feed(text: "\r\n\u{1b}[5mblink\u{1b}[0m")
        frame(view, renderer)
        view.textBlinkVisible.toggle()
        #expect(frame(view, renderer) == 1)
    }
}
#endif
