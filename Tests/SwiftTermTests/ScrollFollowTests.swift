#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

/// Verifies viewport-follow behavior in `Terminal.scroll()`:
/// new output follows the bottom only while the viewport is already at the
/// bottom; once the user scrolls up the viewport stays put so older content
/// remains readable, and returning to the bottom resumes following.
///
/// Regression guard: previously `scroll()` keyed off `Terminal.userScrolling`,
/// a flag that was never set true, so every new line forced `yDisp = yBase`
/// and the viewport always chased output.
final class ScrollFollowTests {

    private func makeTerminal() -> Terminal {
        // Default options: 80x25 with 500 lines of scrollback.
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        return h.terminal!
    }

    private func feedLines(_ t: Terminal, _ count: Int) {
        for i in 0..<count {
            t.feed(text: "line-\(i)\r\n")
        }
    }

    @Test func followsBottomWhenAtBottom() {
        let t = makeTerminal()
        // 60 lines > 25 rows builds scrollback but stays under the 500 limit,
        // so nothing is trimmed and the viewport tracks the base.
        feedLines(t, 60)
        #expect(t.buffer.yDisp == t.buffer.yBase)

        let baseBefore = t.buffer.yBase
        feedLines(t, 10)
        #expect(t.buffer.yBase == baseBefore + 10)
        #expect(t.buffer.yDisp == t.buffer.yBase)   // kept following
    }

    @Test func staysPutWhenScrolledUp() {
        let t = makeTerminal()
        feedLines(t, 60)
        #expect(t.buffer.yDisp == t.buffer.yBase)

        // User scrolls up five rows.
        t.buffer.yDisp = t.buffer.yBase - 5
        let pinned = t.buffer.yDisp
        #expect(pinned < t.buffer.yBase)

        // New output must not drag the viewport down.
        feedLines(t, 8)
        #expect(t.buffer.yDisp == pinned)          // same content still shown
        #expect(t.buffer.yDisp < t.buffer.yBase)   // still scrolled up
    }

    @Test func resumesFollowingWhenBackAtBottom() {
        let t = makeTerminal()
        feedLines(t, 60)

        t.buffer.yDisp = t.buffer.yBase - 5
        feedLines(t, 5)
        #expect(t.buffer.yDisp < t.buffer.yBase)   // still pinned up

        // Scroll back to the bottom; following resumes.
        t.buffer.yDisp = t.buffer.yBase
        feedLines(t, 5)
        #expect(t.buffer.yDisp == t.buffer.yBase)
    }
}
#endif
