import Foundation

/// Pure policy for temporarily revealing hidden items. `state` is desired state,
/// not evidence that a backend changed the menu bar. Only `confirmVisibility`
/// updates the last observed visibility. Apply effects serially and call
/// `suspend(reason:)` if permissions or the backend become unavailable.
///
/// All `now` values must use the same monotonic clock and be finite. The owner
/// supplies timers and routes their captured tokens back to `timerFired`.
public struct RevealController: Sendable {
    public enum SuspensionReason: Equatable, Sendable {
        case permissionsUnavailable
        case backendUnavailable
        case lifecycle
    }

    public enum State: Equatable, Sendable {
        case collapsed
        case revealed
        case suspended(SuspensionReason)
    }

    public enum Visibility: Equatable, Sendable {
        case hidden
        case visible
    }

    public enum Effect: Equatable, Sendable {
        case showHidden
        case hideHidden
        case schedule(deadline: Double, token: UInt64)
        case cancelTimer
    }

    public private(set) var state: State = .collapsed
    public private(set) var observedVisibility: Visibility?
    public private(set) var delay: Double
    public private(set) var deadline: Double?
    public private(set) var timerToken: UInt64?
    public private(set) var isPointerInInteractionRegion = false
    public private(set) var isMenuOpen = false
    /// Explicit collapse is deferred until the open menu closes. A second
    /// toggle cancels that request; hovering alone does not defer a user toggle.
    public private(set) var pendingCollapse = false
    private var generation: UInt64 = 0

    /// Initialization emits no effects and does not assert actual visibility.
    /// Delays outside 1...60 seconds (including nonfinite values) use the default.
    public init(delay: Double = 5) {
        self.delay = Self.validDelay(delay)
    }

    public mutating func confirmVisibility(_ visibility: Visibility) {
        observedVisibility = visibility
    }

    /// An explicit OK applies the saved hidden layout immediately, even if a
    /// previous backend error left the temporary-reveal policy suspended.
    public mutating func confirmExplicitHide() -> [Effect] {
        state = .collapsed
        pendingCollapse = false
        observedVisibility = .hidden
        return cancelTimer()
    }

    public mutating func toggle(now: Double) -> [Effect] {
        switch state {
        case .collapsed:
            state = .revealed
            return [.showHidden] + restartTimer(now: now)
        case .revealed:
            if isMenuOpen {
                pendingCollapse.toggle()
                return cancelTimer()
            }
            state = .collapsed
            return cancelTimer() + [.hideHidden]
        case .suspended:
            return []
        }
    }

    /// An explicit click can repair a released visibility assertion even when
    /// the desired policy still says collapsed. Keep an open menu uninterrupted.
    public mutating func requestHide() -> [Effect] {
        if isMenuOpen {
            state = .revealed
            pendingCollapse = true
            return cancelTimer()
        }
        state = .collapsed
        pendingCollapse = false
        return cancelTimer() + [.hideHidden]
    }

    public mutating func noteActivity(now: Double) -> [Effect] {
        guard state == .revealed else { return [] }
        return restartTimer(now: now)
    }

    public mutating func setPointerInInteractionRegion(_ inside: Bool, now: Double) -> [Effect] {
        guard inside != isPointerInInteractionRegion else { return [] }
        isPointerInInteractionRegion = inside
        return interactionChanged(now: now)
    }

    public mutating func setMenuOpen(_ open: Bool, now: Double) -> [Effect] {
        guard open != isMenuOpen else { return [] }
        isMenuOpen = open
        if !open, pendingCollapse, state == .revealed {
            pendingCollapse = false
            state = .collapsed
            return cancelTimer() + [.hideHidden]
        }
        return interactionChanged(now: now)
    }

    /// A changed delay starts a full new interval, never a retroactive expiry.
    public mutating func setDelay(_ value: Double, now: Double) -> [Effect] {
        let newDelay = Self.validDelay(value)
        guard delay != newDelay else { return [] }
        delay = newDelay
        guard state == .revealed else { return [] }
        return restartTimer(now: now)
    }

    public mutating func timerFired(token: UInt64, now: Double) -> [Effect] {
        guard state == .revealed, !isInteracting,
              timerToken == token, let deadline else { return [] }
        precondition(now.isFinite, "Use a finite monotonic timestamp")
        guard now >= deadline else {
            return [.schedule(deadline: deadline, token: token)]
        }
        state = .collapsed
        return cancelTimer() + [.hideHidden]
    }

    /// Best-effort fail-open request, even if the backend cannot acknowledge it.
    /// No timeout can re-hide items until the owner explicitly resumes.
    public mutating func suspend(reason: SuspensionReason) -> [Effect] {
        pendingCollapse = false
        state = .suspended(reason)
        return cancelTimer() + [.showHidden]
    }

    /// Call only after permissions/backend/lifecycle are usable again.
    /// Preserve interaction flags; an open menu still prevents a timer.
    public mutating func resume(now: Double) -> [Effect] {
        guard case .suspended(let reason) = state else { return [] }
        // A lifecycle refresh always reapplies the saved layout. Restore its
        // collapsed policy immediately unless a menu is still being used.
        if reason == .lifecycle, !isMenuOpen {
            state = .collapsed
            return []
        }
        state = .revealed
        return [.showHidden] + restartTimer(now: now)
    }

    private var isInteracting: Bool { isMenuOpen }

    private mutating func interactionChanged(now: Double) -> [Effect] {
        guard state == .revealed else { return [] }
        return restartTimer(now: now)
    }

    private mutating func restartTimer(now: Double) -> [Effect] {
        var effects = cancelTimer()
        guard !isInteracting else { return effects }
        precondition(now.isFinite && (now + delay).isFinite, "Use a finite monotonic timestamp")
        generation &+= 1
        timerToken = generation
        deadline = now + delay
        effects.append(.schedule(deadline: now + delay, token: generation))
        return effects
    }

    private mutating func cancelTimer() -> [Effect] {
        let hadTimer = timerToken != nil
        timerToken = nil
        deadline = nil
        return hadTimer ? [.cancelTimer] : []
    }

    private static func validDelay(_ value: Double) -> Double {
        value.isFinite && (1...60).contains(value) ? value : 5
    }
}
