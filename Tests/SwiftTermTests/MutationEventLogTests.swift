import Testing
@testable import SwiftTerm

// Headless tests for the AI-native incremental read substrate (P1 / M3): the mutation-time,
// copy-by-value, append-only change-event log with one monotonic event_seq plus content/drive
// watermarks. These prove the four things the M2 spike deferred (findings §5):
//   (a) event taxonomy   — scroll / clear / resize / buffer-switch are first-class ops;
//   (b) index reconciliation — every text-write carries an eviction-stable absolute row;
//   (c) funnel completeness  — every mutated row is captured, not just range endpoints;
//   (d) seq semantics    — strict monotonic event_seq; content_seq/drive_seq exclude cursor moves.
// Plus the contract: capture is copy-by-value-immutable, and default-off captures nothing.
final class MutationEventLogTests {

    // MARK: - helpers

    private func makeTerminal(cols: Int = 20, rows: Int = 6, scrollback: Int = 100,
                              capture: Bool = true) -> Terminal {
        let t = TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback).terminal
        t.mutationCaptureEnabled = capture
        return t
    }

    /// All text-write payloads in a list of events, as (absRow, text) pairs.
    private func textWrites(_ events: [Terminal.ChangeEvent]) -> [(absRow: Int, text: String)] {
        events.compactMap {
            if case let .textWrite(absRow, text) = $0.payload { return (absRow, text) }
            return nil
        }
    }

    private func scrolls(_ events: [Terminal.ChangeEvent]) -> [(top: Int, bottom: Int, count: Int)] {
        events.compactMap {
            if case let .scroll(top, bottom, count) = $0.payload { return (top, bottom, count) }
            return nil
        }
    }

    private func clears(_ events: [Terminal.ChangeEvent]) -> [Terminal.ClearScope] {
        events.compactMap {
            if case let .clear(scope) = $0.payload { return scope }
            return nil
        }
    }

    /// The last text captured for a given absolute row across the events (last-write-wins).
    private func lastText(_ events: [Terminal.ChangeEvent], absRow: Int) -> String? {
        textWrites(events).last(where: { $0.absRow == absRow })?.text
    }

    // MARK: - (d) event_seq is strictly monotonic; the log is sorted

    @Test func eventSeqStrictlyMonotonic() {
        let t = makeTerminal()
        // A mix of content, scroll, clear, resize and buffer-switch events.
        t.feed(text: "alpha\r\nbeta\r\ngamma\r\ndelta\r\nepsilon\r\nzeta\r\neta")
        t.feed(text: "\u{1b}[2J")              // clear
        t.feed(text: "\u{1b}[?1049h")          // enter alt
        t.feed(text: "screen")
        t.feed(text: "\u{1b}[?1049l")          // leave alt
        t.resize(cols: 30, rows: 8)            // resize

        let log = t.changeLog
        #expect(log.count > 5)
        for i in 1 ..< log.count {
            #expect(log[i].seq > log[i - 1].seq)   // strictly increasing
        }
        #expect(log.last?.seq == t.eventSeq)       // eventSeq tracks the last recorded event
    }

    // MARK: - capture correctness + copy-by-value immutability (text writes)

    @Test func textWritesAreCapturedByValueAndImmutable() {
        let t = makeTerminal()
        t.feed(text: "AAAA")
        let afterFirst = t.drainChangeLog()
        // The row's post-write content was snapshotted (last-write-wins over the stale pre-write copy).
        #expect(lastText(afterFirst, absRow: 0) == "AAAA")
        #expect(afterFirst.allSatisfy { $0.bufferKind == .normal })

        // Overwrite the same row. The previously-drained delta must be UNCHANGED — it is a by-value
        // copy, not a live reference into the buffer.
        t.feed(text: "\rBBBB")
        #expect(lastText(afterFirst, absRow: 0) == "AAAA")     // old snapshot still says AAAA
        let afterSecond = t.drainChangeLog()
        #expect(lastText(afterSecond, absRow: 0) == "BBBB")    // new snapshot says BBBB
    }

    // MARK: - (b) index reconciliation: eviction-stable absolute rows across scroll

    @Test func captureCorrectAndCopyByValueAcrossScroll() {
        // rows=3 so the 4th line forces exactly one scroll() within region [0, 2].
        let t = makeTerminal(cols: 10, rows: 3, scrollback: 100)
        t.feed(text: "L0\r\nL1\r\nL2\r\nL3")

        let log = t.drainChangeLog()

        // (a) Scroll surfaced as a first-class event (not just row rewrites), with the right region.
        let s = scrolls(log)
        #expect(s.count == 1)
        #expect(s.first?.top == 0)
        #expect(s.first?.bottom == 2)
        #expect(s.first?.count == 1)        // content moved up by one row

        // (b) Eviction-stable absolute rows: L0..L3 keep distinct, monotonically increasing absRows
        // even though L0 scrolled into scrollback. linesTop+index is stable, unlike the spike's yBase+y.
        #expect(lastText(log, absRow: 0) == "L0")
        #expect(lastText(log, absRow: 1) == "L1")
        #expect(lastText(log, absRow: 2) == "L2")
        #expect(lastText(log, absRow: 3) == "L3")

        // Copy-by-value across the scroll: snapshot the events, mutate further, originals unchanged.
        t.feed(text: "\r\nL4")
        #expect(lastText(log, absRow: 3) == "L3")

        // The live snapshot agrees: bottom visible row is L3, top of the visible window scrolled off L0.
        let snap = t.snapshot()
        #expect(snap.bufferKind == .normal)
        #expect(snap.rowsText.last == "L4")
    }

    // MARK: - (c) funnel completeness across insert-line / delete-line

    @Test func insertLineCapturedCompleteAndByValue() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 0)
        t.feed(text: "R0\r\nR1\r\nR2\r\nR3")
        _ = t.drainChangeLog()                          // clear the initial writes

        // Cursor to row 1 (CSI 2;1H is 1-based), insert a blank line: R1,R2 shift down, R3 falls off.
        t.feed(text: "\u{1b}[2;1H\u{1b}[L")
        let log = t.drainChangeLog()

        // Funnel completeness: EVERY affected row in [1, scrollBottom] is captured (not just the two
        // endpoints). After IL: row1 = blank, row2 = R1, row3 = R2.
        #expect(lastText(log, absRow: 1) == "")
        #expect(lastText(log, absRow: 2) == "R1")
        #expect(lastText(log, absRow: 3) == "R2")

        // Copy-by-value: later mutation does not retroactively change captured deltas.
        t.feed(text: "\u{1b}[1;1Hxx")
        #expect(lastText(log, absRow: 2) == "R1")
    }

    @Test func deleteLineCapturedCompleteAndByValue() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 0)
        t.feed(text: "R0\r\nR1\r\nR2\r\nR3")
        _ = t.drainChangeLog()

        // Cursor to row 1, delete a line: R2,R3 shift up, row3 becomes blank.
        t.feed(text: "\u{1b}[2;1H\u{1b}[M")
        let log = t.drainChangeLog()

        #expect(lastText(log, absRow: 1) == "R2")
        #expect(lastText(log, absRow: 2) == "R3")
        #expect(lastText(log, absRow: 3) == "")
    }

    // MARK: - (a)/(d) resize is a first-class event that bumps driveSeq, not contentSeq

    @Test func resizeEmitsResizeEventAndBumpsOnlyDriveSeq() {
        let t = makeTerminal(cols: 20, rows: 6)
        t.feed(text: "content")
        let contentBefore = t.contentSeq
        let driveBefore = t.driveSeq

        t.resize(cols: 24, rows: 8)

        // contentSeq is untouched by a resize; driveSeq advances to the resize event.
        #expect(t.contentSeq == contentBefore)
        #expect(t.driveSeq > driveBefore)
        #expect(t.driveSeq == t.eventSeq)

        // The resize op is in the log with the new geometry.
        let resizeEvents = t.changeLog.compactMap { ev -> (Int, Int)? in
            if case let .resize(c, r) = ev.payload { return (c, r) }
            return nil
        }
        #expect(resizeEvents.last?.0 == 24)
        #expect(resizeEvents.last?.1 == 8)
    }

    // MARK: - (d) a cursor-only move bumps NEITHER content_seq NOR drive_seq

    @Test func cursorOnlyMoveBumpsNeitherWatermark() {
        let t = makeTerminal(cols: 20, rows: 6)
        t.feed(text: "hi")                         // a real content change first
        let contentBefore = t.contentSeq
        let driveBefore = t.driveSeq
        let eventBefore = t.eventSeq
        #expect(contentBefore > 0)

        // A pure cursor move: CSI 3;5H → row 2, col 4 (0-based). No cell content changes.
        t.feed(text: "\u{1b}[3;5H")

        // The cursor genuinely moved...
        #expect(t.buffer.y == 2)
        #expect(t.buffer.x == 4)
        // ...yet NEITHER watermark advanced, and nothing was appended to the log.
        #expect(t.contentSeq == contentBefore)
        #expect(t.driveSeq == driveBefore)
        #expect(t.eventSeq == eventBefore)
    }

    // MARK: - (a)/(d) buffer switch is a first-class event that bumps content + drive

    @Test func bufferSwitchEmitsEventAndBumpsDriveSeq() {
        let t = makeTerminal(cols: 20, rows: 6)
        t.feed(text: "normal")
        let driveBefore = t.driveSeq

        t.feed(text: "\u{1b}[?1049h")              // enter alternate screen
        #expect(t.currentBufferKind == .alt)
        let enterSwitches = t.changeLog.compactMap { ev -> Bool? in
            if case let .bufferSwitch(toAlt) = ev.payload { return toAlt }
            return nil
        }
        #expect(enterSwitches.last == true)
        #expect(t.driveSeq > driveBefore)
        let driveAfterEnter = t.driveSeq

        t.feed(text: "\u{1b}[?1049l")              // leave alternate screen
        #expect(t.currentBufferKind == .normal)
        let allSwitches = t.changeLog.compactMap { ev -> Bool? in
            if case let .bufferSwitch(toAlt) = ev.payload { return toAlt }
            return nil
        }
        #expect(allSwitches.last == false)
        #expect(t.driveSeq > driveAfterEnter)
    }

    // MARK: - (a) clear (erase-in-display) is a first-class event

    @Test func eraseInDisplayEmitsClearEvent() {
        let t = makeTerminal(cols: 20, rows: 6)
        t.feed(text: "some text")
        _ = t.drainChangeLog()

        t.feed(text: "\u{1b}[2J")                  // ED all
        #expect(clears(t.drainChangeLog()).contains(.all))

        t.feed(text: "x")
        _ = t.drainChangeLog()
        t.feed(text: "\u{1b}[0J")                  // ED below
        #expect(clears(t.drainChangeLog()).contains(.below))
    }

    // MARK: - read API: changesSince returns the tail and is idempotent for a fixed seq

    @Test func changesSinceReturnsTailAndIsIdempotent() {
        let t = makeTerminal()
        t.feed(text: "one\r\ntwo\r\nthree")
        let mid = t.eventSeq
        t.feed(text: "\r\nfour\r\nfive")

        // Everything strictly after `mid`.
        let tail = t.changesSince(mid)
        #expect(!tail.isEmpty)
        #expect(tail.allSatisfy { $0.seq > mid })

        // Idempotent: replaying the same fixed range yields a byte-identical result while retained.
        #expect(t.changesSince(mid) == tail)

        // Full range and the empty tail behave as specified.
        #expect(t.changesSince(0) == t.changeLog)
        #expect(t.changesSince(t.eventSeq).isEmpty)
    }

    // MARK: - snapshot accessor reflects the visible screen + watermarks

    @Test func snapshotReflectsVisibleScreenAndWatermarks() {
        let t = makeTerminal(cols: 10, rows: 3, scrollback: 100)
        t.feed(text: "aa\r\nbb\r\ncc")

        let snap = t.snapshot()
        #expect(snap.cols == 10)
        #expect(snap.rows == 3)
        #expect(snap.bufferKind == .normal)
        #expect(snap.rowsText == ["aa", "bb", "cc"])
        #expect(snap.eventSeq == t.eventSeq)
        #expect(snap.contentSeq == t.contentSeq)
        #expect(snap.driveSeq == t.driveSeq)
        // Absolute rows are linesTop + yBase + visibleRow and strictly increasing top→bottom.
        #expect(snap.rowAbsRows == [snap.linesTop + snap.yBase + 0,
                                    snap.linesTop + snap.yBase + 1,
                                    snap.linesTop + snap.yBase + 2])
        // A snapshot pairs with changesSince for an idempotent incremental read baseline.
        #expect(t.changesSince(snap.eventSeq).isEmpty)
    }

    // MARK: - default-off is zero-cost / byte-identical: it captures NOTHING

    @Test func defaultOffCapturesNothing() {
        // Default-constructed terminal: mutationCaptureEnabled is false.
        let t = TerminalTestHarness.makeTerminal(cols: 20, rows: 6, scrollback: 100).terminal
        #expect(t.mutationCaptureEnabled == false)

        // Exercise every hooked path: text, scroll, IL/DL, clear, resize, buffer switch.
        t.feed(text: "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng")
        t.feed(text: "\u{1b}[2;1H\u{1b}[L\u{1b}[M")
        t.feed(text: "\u{1b}[2J")
        t.feed(text: "\u{1b}[?1049h\u{1b}[?1049l")
        t.resize(cols: 24, rows: 8)

        // Nothing recorded; all seqs at their initial zero; the read APIs return empty.
        #expect(t.changeLog.isEmpty)
        #expect(t.eventSeq == 0)
        #expect(t.contentSeq == 0)
        #expect(t.driveSeq == 0)
        #expect(t.changesSince(0).isEmpty)
        #expect(t.drainChangeLog().isEmpty)

        // The L0 snapshot floor is always available regardless of the flag (it is a live read, not capture).
        #expect(t.snapshot().rows == 8)
    }

    // MARK: - reconstruction harness (proves NO content is silently lost across wraps/scrolls)

    /// Replay an event window onto an absolute-row model seeded from `baseline`, then project to the
    /// final visible window. Models the M4 consumer: text-writes set rows by eviction-stable absRow.
    /// A full-screen `.scroll` (scrollTop==0, the only kind these tests produce) advances the viewport
    /// and trims, but never renumbers surviving content — absRows are stable — so it is a no-op on the
    /// absRow model. The whole point: because every touched row is captured at its STABLE absRow, the
    /// reconstruction is order-independent (stale pre-write captures are simply superseded by absRow).
    /// Tests take the baseline AFTER any clear/resize/buffer-switch so the window holds only
    /// text-writes + scrolls.
    private func reconstruct(baseline: Terminal.ScreenSnapshot,
                             events: [Terminal.ChangeEvent],
                             final: Terminal.ScreenSnapshot) -> [String] {
        var model: [Int: String] = [:]
        for (i, abs) in baseline.rowAbsRows.enumerated() { model[abs] = baseline.rowsText[i] }
        for ev in events {
            switch ev.payload {
            case let .textWrite(absRow, text):
                model[absRow] = text
            case .scroll:
                break // full-screen scroll keeps absRows stable → viewport advance, no model change
            case .clear, .resize, .bufferSwitch:
                break // not exercised between baseline and final in these tests
            }
        }
        return final.rowAbsRows.map { model[$0] ?? "" }
    }

    // (a) A line wrapping across >=2 rows mid-screen reconstructs EXACTLY (no scroll).
    @Test func wrappingLineMidScreenReconstructsExactly() {
        let t = makeTerminal(cols: 10, rows: 6, scrollback: 100)
        let baseline = t.snapshot()
        // 25 chars at row 1 (1-based row 2) → wraps across rows 1,2,3.
        t.feed(text: "\u{1b}[2;1HABCDEFGHIJKLMNOPQRSTUVWXY")
        let final = t.snapshot()
        let recon = reconstruct(baseline: baseline, events: t.changesSince(baseline.eventSeq), final: final)
        // Sanity: the write really did wrap onto interior rows (this is what regressed before the fix).
        #expect(final.rowsText[2] == "KLMNOPQRST")
        #expect(recon == final.rowsText)
    }

    // (b) A wrapping write at the bottom that triggers scroll reconstructs EXACTLY (normal buffer).
    @Test func wrappingScrollNormalBufferReconstructsExactly() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 100)
        t.feed(text: "L0\r\nL1\r\nL2\r\nL3")          // fill; cursor at bottom row
        let baseline = t.snapshot()
        t.feed(text: "\rABCDEFGHIJKLMNOPQRSTUVWXY")    // long line at the bottom → wraps + scrolls
        let final = t.snapshot()
        let recon = reconstruct(baseline: baseline, events: t.changesSince(baseline.eventSeq), final: final)
        #expect(recon == final.rowsText)
    }

    // (b-alt) The same at the bottom of the ALTERNATE buffer — the ordering-critical case: content
    // written then scrolled in place must be captured BEFORE the scroll shifts it.
    @Test func wrappingScrollAltBufferReconstructsExactly() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 100)
        t.feed(text: "\u{1b}[?1049h")                  // enter alternate screen
        t.feed(text: "L0\r\nL1\r\nL2\r\nL3")
        let baseline = t.snapshot()
        #expect(baseline.bufferKind == .alt)
        t.feed(text: "\rABCDEFGHIJKLMNOPQRSTUVWXY")
        let final = t.snapshot()
        let recon = reconstruct(baseline: baseline, events: t.changesSince(baseline.eventSeq), final: final)
        #expect(recon == final.rowsText)
    }

    // (c) insertMode + wrap reconstructs EXACTLY (forces the per-char insertCharacter wrap path).
    @Test func insertModeWrapReconstructsExactly() {
        let t = makeTerminal(cols: 10, rows: 6, scrollback: 100)
        let baseline = t.snapshot()
        t.feed(text: "\u{1b}[4h")                       // IRM insert mode on
        t.feed(text: "\u{1b}[2;1HABCDEFGHIJKLMNOPQRSTUVWXY")
        let final = t.snapshot()
        let recon = reconstruct(baseline: baseline, events: t.changesSince(baseline.eventSeq), final: final)
        #expect(final.rowsText[1] == "ABCDEFGHIJ")
        #expect(final.rowsText[2] == "KLMNOPQRST")
        #expect(recon == final.rowsText)
    }

    // (d) DECBI (ESC 6) columnScroll mutates EVERY row in the region — reconstruct exactly.
    @Test func columnScrollDECBIReconstructsEveryRow() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 0)
        t.feed(text: "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD")
        t.feed(text: "\u{1b}[1;1H")                     // cursor to row0,col0 (left margin)
        let baseline = t.snapshot()
        t.feed(text: "\u{1b}6")                         // DECBI → columnScroll inserts a cell per region row
        let final = t.snapshot()
        // The op actually mutated every region row (content shifted right by one column).
        #expect(final.rowsText != baseline.rowsText)
        #expect(final.rowsText[1] == " BBBBB")
        #expect(final.rowsText[2] == " CCCCC")
        let recon = reconstruct(baseline: baseline, events: t.changesSince(baseline.eventSeq), final: final)
        #expect(recon == final.rowsText)
    }

    // (e) DECFRA (fill rectangular area, CSI Pc;Pt;Pl;Pb;Pr $ x) mutates every rectangle row with no
    // updateRange in upstream — capture must mark/record the whole rectangle. Reconstruct exactly.
    @Test func decfraFillRectangleReconstructsEveryRow() {
        let t = makeTerminal(cols: 10, rows: 5, scrollback: 100)
        let baseline = t.snapshot()
        // Fill rows 2..4, cols 2..4 (1-based) with 'X' (0x58) → 0-based rows 1..3, cols 1..3.
        t.feed(text: "\u{1b}[88;2;2;4;4$x")
        let final = t.snapshot()
        #expect(final.rowsText != baseline.rowsText)         // the op actually mutated content
        #expect(final.rowsText[2].contains("XXX"))           // an interior rectangle row got filled
        let recon = reconstruct(baseline: baseline, events: t.changesSince(baseline.eventSeq), final: final)
        #expect(recon == final.rowsText)
    }

    // (f) DECIC (insert columns, CSI Pn ' }) mutates every row in scrollTop...scrollBottom with no
    // updateRange in upstream — capture must mark/record the whole region. Reconstruct exactly.
    @Test func decicInsertColumnsReconstructsEveryRow() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 0)
        t.feed(text: "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD")
        t.feed(text: "\u{1b}[1;1H")                          // cursor to row0,col0
        let baseline = t.snapshot()
        t.feed(text: "\u{1b}[2'}")                           // insert 2 columns at col0 in every region row
        let final = t.snapshot()
        #expect(final.rowsText != baseline.rowsText)         // every region row shifted right by 2
        let recon = reconstruct(baseline: baseline, events: t.changesSince(baseline.eventSeq), final: final)
        #expect(recon == final.rowsText)
    }
}
