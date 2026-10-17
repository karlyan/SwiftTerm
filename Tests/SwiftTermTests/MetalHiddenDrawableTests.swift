#if os(macOS)
import AppKit
import Metal
import MetalKit
import Testing

@testable import SwiftTerm

/// A hidden terminal holds no full-size drawables (each is a window-sized
/// IOSurface; a host that keeps many terminals mounted but hidden would hold
/// three per terminal), and it gets them back the moment it draws visibly.
/// Every way a new Metal view appears while the terminal is hidden must keep
/// it released — those paths draw a synchronous first frame, and without a
/// further hide nothing would release the drawables again.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalHiddenDrawableTests {
    private static let released = CGSize(width: 1, height: 1)

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    private func fullSize(_ view: TerminalView) throws -> CGSize {
        let metalView = try #require(view.metalView)
        let scale = view.metalRenderingScaleFactor()
        return CGSize(width: metalView.bounds.width * scale, height: metalView.bounds.height * scale)
    }

    /// Let the in-flight frame complete, so the next draw is not turned away
    /// by the frame coordinator.
    private func settle(_ view: TerminalView) throws {
        let renderer = try #require(view.metalRenderer)
        let deadline = Date().addingTimeInterval(2)
        while !renderer.isIdle && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(renderer.isIdle)
    }

    @Test func hidingReleasesTheDrawables() throws {
        let view = makeView()
        try view.setUseMetal(true)
        view.drawMetalFrameNow()
        #expect(view.metalView?.drawableSize == (try fullSize(view)),
                "a visible terminal draws at full size, or this proves nothing")

        view.isHidden = true

        #expect(view.metalView?.drawableSize == Self.released)
    }

    @Test func hidingAnAncestorReleasesTheDrawables() throws {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let view = makeView()
        container.addSubview(view)
        try view.setUseMetal(true)
        view.drawMetalFrameNow()

        container.isHidden = true

        #expect(view.metalView?.drawableSize == Self.released)
    }

    @Test func unhidingDrawsAtFullSizeAgain() throws {
        let view = makeView()
        try view.setUseMetal(true)
        view.isHidden = true

        view.isHidden = false
        try settle(view)
        view.drawMetalFrameNow()

        #expect(view.metalView?.drawableSize == (try fullSize(view)))
    }

    @Test func enablingMetalWhileHiddenStaysReleased() throws {
        let view = makeView()
        view.isHidden = true

        try view.setUseMetal(true)

        #expect(view.metalView?.drawableSize == Self.released)
    }

    @Test func aRendererReplacedWhileHiddenStaysReleased() throws {
        let view = makeView()
        try view.setUseMetal(true)
        let oldRenderer = try #require(view.metalRenderer)
        view.isHidden = true

        view.metalRenderer(oldRenderer, requiresRecovery: MetalRendererRecoveryReport(
            reason: .activeFrame,
            failureDuration: 1,
            commandBufferStatus: .scheduled,
            commandBufferError: nil
        ))

        #expect(view.metalRenderer !== oldRenderer, "the renderer must be replaced, or this proves nothing")
        #expect(view.metalView?.drawableSize == Self.released)
    }

    @Test func drawingNowWhileHiddenStaysReleased() throws {
        let view = makeView()
        try view.setUseMetal(true)
        view.isHidden = true

        view.drawMetalFrameNow()

        #expect(view.metalView?.drawableSize == Self.released)
    }
}
#endif
