import Foundation
import Testing
@testable import RemotoInput

@Suite struct PacerTests {
    @Test func firstPushUsesInitialAverageAndJitter() {
        var p = Pacer()
        p.push(dx: 10, dy: 4, now: 0)
        #expect(p.avg == 0.016)
        #expect(p.jit == 0.002)
        // lead = min(0.016 + clamp(2*0.002, 0.002, 0.010), 0.034) = 0.020
        #expect(approx(p.deadline, 0.020))
    }

    @Test func averageAndJitterFollowTheGap() {
        var p = Pacer()
        p.push(dx: 1, dy: 0, now: 0)
        p.push(dx: 1, dy: 0, now: 0.008)
        // sample = |0.008 - 0.016| = 0.008
        #expect(approx(p.avg, 0.2 * 0.008 + 0.8 * 0.016))
        #expect(approx(p.jit, 0.85 * 0.002 + 0.15 * 0.008))
        #expect(approx(p.deadline, 0.008 + p.avg + min(max(2 * p.jit, 0.002), 0.010)))
    }

    @Test func gapsOfATenthOrMoreDoNotTeach() {
        var p = Pacer()
        p.push(dx: 1, dy: 0, now: 0)
        p.push(dx: 1, dy: 0, now: 0.1)
        #expect(p.avg == 0.016)
        #expect(p.jit == 0.002)
    }

    @Test func averageIsClampedAndLeadCapped() {
        var fast = Pacer()
        for i in 0..<200 { fast.push(dx: 1, dy: 0, now: Double(i) * 0.0005) }
        #expect(approx(fast.avg, 0.004))

        var slow = Pacer()
        var t = 0.0
        for i in 0..<200 {
            t += i.isMultiple(of: 2) ? 0.09 : 0.01
            slow.push(dx: 1, dy: 0, now: t)
            #expect(slow.avg <= 0.034 && slow.avg >= 0.004)
            #expect(slow.deadline - t <= 0.034 + 1e-12)
        }
        // Sample capped at 0.034 keeps jitter bounded too.
        #expect(slow.jit <= 0.034)
    }

    @Test func partialDeliveryIsProportional() {
        var p = Pacer()
        p.push(dx: 10, dy: 4, now: 0)  // deadline 0.020
        #expect(p.deliver(now: 0) == nil)  // now must be after start
        let first = p.deliver(now: 0.010)
        #expect(first.map { approx($0.x, 5) && approx($0.y, 2) } == true)
        #expect(approx(p.pending.x, 5))
        // Next fraction is measured from the new start.
        let second = p.deliver(now: 0.015)
        #expect(second.map { approx($0.x, 2.5) } == true)
        let rest = p.deliver(now: 0.020)
        #expect(rest.map { approx($0.x, 2.5) && approx($0.y, 1) } == true)
        #expect(!p.hasPending)
        #expect(p.deliver(now: 0.030) == nil)
    }

    @Test func engineTicksAt240HzAndLosesNothing() {
        let h = Harness()
        h.send(.move(dx: 30, dy: -12))
        #expect(h.moves.isEmpty)
        h.advance(0.004166)
        #expect(h.moves.isEmpty)
        h.advance(0.000002)
        #expect(h.moves.count == 1)
        h.advance(0.05)
        #expect(h.moves.reduce(0) { $0 + $1.dx } == 30)
        #expect(h.moves.reduce(0) { $0 + $1.dy } == -12)
        #expect(h.sink.cursor.x == 750 && h.sink.cursor.y == 438)
        #expect(h.core.nextDeadline() == nil)
    }

    @Test func pendingMotionGoesOutBeforeAClick() {
        let h = Harness()
        h.send(.move(dx: 7, dy: 0))
        h.send(.click(.left, count: 1))
        #expect(h.events.count == 3)
        if case let .mouse(kind, _, x, _, dx, _, _, _) = h.events[0] {
            #expect(kind == .moved && dx == 7 && x == 727)
        } else {
            Issue.record("expected the move first")
        }
        #expect(h.buttons.map(\.kind) == [.down, .up])
    }

    @Test func deltasAreClampedTo4000() {
        let h = Harness()
        h.sink.screens = []
        h.send(.move(dx: 10_000, dy: -9_999))
        h.process(.flush({}))
        #expect(h.moves.last?.dx == 4000)
        #expect(h.moves.last?.dy == -4000)
        h.send(.move(dx: .infinity, dy: 1))
        h.send(.move(dx: 0, dy: 0))
        h.process(.flush({}))
        #expect(h.moves.count == 1)
    }

    @Test func movesAreClampedToTheNearestScreen() {
        let h = Harness()
        h.send(.move(dx: 2000, dy: 10))
        h.process(.flush({}))
        #expect(h.moves.last?.x == 1439)
        #expect(h.moves.last?.y == 460)
        #expect(h.moves.last?.dx == 719)
    }

    @Test func subpixelsAreKept() {
        let h = Harness()
        for _ in 0..<4 {
            h.send(.move(dx: 0.5, dy: 0.25))
            h.process(.flush({}))
        }
        #expect(h.sink.cursor.x == 722)
        #expect(h.sink.cursor.y == 451)
        #expect(h.moves.map(\.dx) == [0, 1, 0, 1])
    }

    @Test func movesWhileHoldingAreDrags() {
        let h = Harness()
        h.send(.button(.right, .down))
        h.send(.move(dx: 3, dy: 0))
        h.process(.flush({}))
        #expect(h.moves.last?.kind == .dragged)
        #expect(h.moves.last?.button == .right)
    }
}

@Suite struct ScrollTests {
    @Test func phases() {
        let h = Harness()
        h.send(.scroll(phase: 2, dx: 0, dy: 5))  // not active → began
        h.send(.scroll(phase: 2, dx: 0, dy: 6))
        h.send(.scroll(phase: 1, dx: 0, dy: 7))  // active → end, then began
        h.send(.scroll(phase: 4, dx: 0, dy: 9))
        h.send(.scroll(phase: 8, dx: 0, dy: 9))  // inactive → nothing
        h.send(.scroll(phase: 3, dx: 0, dy: 9))  // unknown → ignored
        h.send(.scroll(phase: 0, dx: 1, dy: 2))
        let s = h.scrolls
        #expect(s.map(\.phase) == [1, 2, 4, 1, 4, 0])
        #expect(s.map(\.momentum).allSatisfy { $0 == 0 })
        #expect(s.map(\.wheel1) == [5, 6, 0, 7, 0, 2])
        #expect(s[5].wheel2 == 1)
        #expect(s[2].dy == 0 && s[4].dy == 0)
    }

    @Test func cancelledEndsWithItsOwnPhase() {
        let h = Harness()
        h.send(.scroll(phase: 1, dx: 0, dy: 1))
        h.send(.scroll(phase: 8, dx: 0, dy: 1))
        #expect(h.scrolls.map(\.phase) == [1, 8])
        #expect(!h.core.scrollActive)
    }

    @Test func gestureEndsAfter300msOfSilence() {
        let h = Harness()
        h.send(.scroll(phase: 1, dx: 0, dy: 3))
        h.advance(0.2)
        h.send(.scroll(phase: 2, dx: 0, dy: 3))
        h.advance(0.299)
        #expect(h.scrolls.count == 2)
        h.advance(0.002)
        #expect(h.scrolls.map(\.phase) == [1, 2, 4])
        #expect(!h.core.scrollActive)
    }

    @Test func fractionsAccumulateOnlyInChangedAndWheel() {
        let h = Harness()
        h.send(.scroll(phase: 1, dx: 0, dy: 0.6))
        h.send(.scroll(phase: 2, dx: 0, dy: 0.6))
        h.send(.scroll(phase: 2, dx: 0, dy: 0.6))
        h.send(.scroll(phase: 2, dx: -0.7, dy: 0))
        h.send(.scroll(phase: 2, dx: -0.7, dy: 0))
        // Began resets, so 0.6 is lost; then 0.6, 1.2 → 0, 1.
        #expect(h.scrolls.map(\.wheel1) == [0, 0, 1, 0, 0])
        #expect(h.scrolls.map(\.wheel2) == [0, 0, 0, 0, -1])
        // Fixed point keeps the raw value.
        #expect(h.scrolls[1].dy == 0.6)
    }

    @Test func scrollDeltasAreClamped() {
        let h = Harness()
        h.send(.scroll(phase: 0, dx: -5000, dy: 9999))
        h.send(.scroll(phase: 0, dx: .nan, dy: 1))
        #expect(h.scrolls.count == 1)
        #expect(h.scrolls[0].wheel1 == 4000)
        #expect(h.scrolls[0].wheel2 == -4000)
    }
}

@Suite struct FlingTests {
    @Test func belowEightyIsIgnored() {
        #expect(Fling(vx: 79.9, vy: 0, now: 0) == nil)
        #expect(Fling(vx: 48, vy: 63, now: 0) == nil)  // hypot 79.2
        #expect(Fling(vx: 48, vy: 64, now: 0) != nil)  // hypot 80
        #expect(Fling(vx: .nan, vy: 500, now: 0) == nil)
    }

    @Test func speedIsCappedAt12000() {
        let f = Fling(vx: 30000, vy: 40000, now: 0)!
        #expect(approx(f.speed, 12000, 1e-6))
        #expect(approx(f.vx, 7200, 1e-6) && approx(f.vy, 9600, 1e-6))
    }

    @Test func decaysExponentiallyAndEnds() {
        var f = Fling(vx: 0, vy: 1000, now: 0)!
        var t = 0.0
        var first = true
        var steps = 0
        while true {
            t += 0.008333
            let before = f.vy
            let step = f.tick(now: t)
            steps += 1
            if case let .scroll(_, dy, momentum) = step {
                #expect(momentum == (first ? 1 : 2))
                first = false
                #expect(approx(f.vy, before * exp(-2.6 * 0.008333), 1e-9))
                #expect(approx(dy, f.vy * 0.008333, 1e-9))
            } else {
                #expect(step == .end(started: true))
                #expect(f.vy < 12)
                break
            }
        }
        // 1000 → 12 at 2.6/s takes ln(1000/12)/2.6 ≈ 1.70 s.
        #expect(abs(t - log(1000.0 / 12) / 2.6) < 0.01)
        #expect(steps > 100)
    }

    @Test func earlyTicksWaitAndLongGapsAreCapped() {
        var f = Fling(vx: 5000, vy: 0, now: 0)!
        #expect(f.tick(now: 0.004) == .wait)
        if case let .scroll(dx, _, _) = f.tick(now: 0.1) {
            #expect(approx(dx, f.vx * 0.024999, 1e-9))
        } else {
            Issue.record("expected a scroll")
        }
    }

    @Test func stopsAfterFourSeconds() {
        // Even a slow decay never runs past 4 s (friction is fixed, so check the bound directly).
        var f = Fling(vx: 12000, vy: 0, now: 0)!
        var t = 0.0
        var last: Fling.Step = .wait
        repeat {
            t += 0.008333
            last = f.tick(now: t)
        } while last != .end(started: true)
        #expect(t <= 4.0)
    }

    @Test func engineFlingPostsMomentumThenEnd() {
        let h = Harness()
        h.send(.scroll(phase: 1, dx: 0, dy: 5))
        h.send(.fling(vx: 0, vy: 2000))
        #expect(h.scrolls.map(\.phase) == [1, 4])
        h.advance(5)
        let m = h.scrolls.dropFirst(2)
        #expect(m.first?.momentum == 1)
        #expect(m.dropFirst().dropLast().allSatisfy { $0.momentum == 2 && $0.phase == 0 })
        #expect(m.last?.momentum == 3)
        #expect(m.last?.dy == 0)
        #expect(h.core.fling == nil)
        #expect(h.core.nextDeadline() == nil)
    }

    @Test func touchAndScrollCancelTheFling() {
        let h = Harness()
        h.send(.fling(vx: 900, vy: 0))
        h.send(.touch)  // not started yet → nothing to end
        #expect(h.scrolls.isEmpty)
        #expect(h.core.fling == nil)

        h.send(.fling(vx: 900, vy: 0))
        h.advance(0.02)
        h.send(.touch)
        #expect(h.scrolls.last?.momentum == 3)
        #expect(h.core.fling == nil)

        h.send(.fling(vx: 900, vy: 0))
        h.advance(0.02)
        h.clear()
        h.send(.scroll(phase: 1, dx: 0, dy: 2))
        #expect(h.scrolls.map(\.momentum) == [3, 0])
        #expect(h.scrolls.map(\.phase) == [0, 1])
    }

    @Test func tooSlowFlingDoesNothing() {
        let h = Harness()
        h.send(.fling(vx: 50, vy: 50))
        h.advance(1)
        #expect(h.scrolls.isEmpty)
    }
}

@Suite struct ButtonTests {
    @Test func doubleClickNeedsTimeAndDistance() {
        let h = Harness()
        h.send(.button(.left, .down))
        h.send(.button(.left, .up))
        h.advance(0.4)
        h.send(.button(.left, .down))
        h.send(.button(.left, .up))
        h.advance(0.49)
        h.send(.button(.left, .down))
        h.send(.button(.left, .up))
        h.advance(0.51)
        h.send(.button(.left, .down))
        h.send(.button(.left, .up))
        #expect(h.buttons.map(\.clickState) == [1, 1, 2, 2, 3, 3, 1, 1])
    }

    @Test func doubleClickDistanceIsFivePixels() {
        let h = Harness()
        h.send(.click(.left, count: 1))
        h.send(.move(dx: 3, dy: 4))  // exactly 5 px
        h.send(.click(.left, count: 1))
        h.send(.move(dx: 5, dy: 1))  // 5.1 px
        h.send(.click(.left, count: 1))
        #expect(h.buttons.filter { $0.kind == .down }.map(\.clickState) == [1, 2, 1])
    }

    @Test func otherButtonOrTimingResetsTheCount() {
        let h = Harness()
        h.process(.setTiming(InputTiming(doubleClickMs: 200)))
        h.send(.click(.left, count: 1))
        h.send(.click(.right, count: 1))
        h.send(.click(.right, count: 1))
        h.advance(0.25)
        h.send(.click(.right, count: 1))
        #expect(h.buttons.filter { $0.kind == .down }.map(\.clickState) == [1, 1, 2, 1])
    }

    @Test func multiClickPostsPairs() {
        let h = Harness()
        h.send(.click(.middle, count: 3))
        #expect(h.buttons.map(\.clickState) == [1, 1, 2, 2, 3, 3])
        #expect(h.buttons.map(\.kind) == [.down, .up, .down, .up, .down, .up])
        h.clear()
        h.send(.click(.left, count: 9))  // clamped to 3
        #expect(h.buttons.count == 6)
    }

    @Test func buttonsAreRefcountedAcrossSessions() {
        let h = Harness()
        h.send(.button(.left, .down), session: 1)
        h.send(.button(.left, .down), session: 1)  // same session: nothing
        h.send(.button(.left, .down), session: 2)
        #expect(h.buttons.map(\.kind) == [.down])
        h.send(.click(.left, count: 1), session: 3)  // held: nothing
        h.send(.button(.left, .up), session: 1)
        #expect(h.buttons.count == 1)
        h.send(.button(.left, .up), session: 1)  // not held anymore
        #expect(h.buttons.count == 1)
        h.send(.button(.left, .up), session: 2)
        #expect(h.buttons.map(\.kind) == [.down, .up])
    }
}
