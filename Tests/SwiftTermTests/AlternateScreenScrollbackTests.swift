#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

/// Verifies that alternate-screen (TUI) content saved into the normal buffer's
/// scrollback for live display can be excluded from a persistable dump via
/// `getBufferAsData(stripAlternateScreen:)`.
final class AlternateScreenScrollbackTests {

    private func makeTerminal() -> Terminal {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!
        t.options.saveAlternateScreenToScrollback = true
        return t
    }

    @Test func altSnapshotIsStrippedButShellOutputSurvives() {
        let t = makeTerminal()

        // Real shell output in the normal buffer.
        t.feed(text: "shell-line-1\r\nshell-line-2\r\n")

        // Run a "TUI": enter alt screen, draw, then exit. On exit,
        // saveAlternateScreenToScrollback copies the alt screen into the normal
        // buffer's scrollback (tagged fromAlternateScreen).
        t.feed(text: "\u{1b}[?1049h")        // enter alternate buffer
        t.feed(text: "TUI-SNAPSHOT-XYZ")
        t.feed(text: "\u{1b}[?1049l")        // exit -> snapshot saved to scrollback

        let full = String(data: t.getBufferAsData(kind: .normal), encoding: .utf8) ?? ""
        let persistable = String(
            data: t.getBufferAsData(kind: .normal, stripAlternateScreen: true),
            encoding: .utf8) ?? ""

        // Live dump still contains the TUI snapshot (Ctrl+C convenience intact)...
        #expect(full.contains("TUI-SNAPSHOT-XYZ"))
        // ...but the persistable dump excludes it.
        #expect(!persistable.contains("TUI-SNAPSHOT-XYZ"))
        // Real shell output is kept in both.
        #expect(persistable.contains("shell-line-1"))
        #expect(persistable.contains("shell-line-2"))
    }
}
#endif
