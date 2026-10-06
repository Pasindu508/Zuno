import Foundation

enum CheckInResult: String, Codable, Sendable, Hashable {
    case valid
    case alreadyUsed = "already_used"
    case invalid
    case refunded
    case cancelled
    case wrongEvent = "wrong_event"

    var title: String {
        switch self {
        case .valid: String(localized: "Checked in")
        case .alreadyUsed: String(localized: "Already used")
        case .invalid: String(localized: "Invalid ticket")
        case .refunded: String(localized: "Ticket refunded")
        case .cancelled: String(localized: "Ticket cancelled")
        case .wrongEvent: String(localized: "Different event")
        }
    }

    var symbolName: String {
        switch self {
        case .valid: "checkmark.circle.fill"
        case .alreadyUsed: "exclamationmark.triangle.fill"
        case .invalid: "xmark.circle.fill"
        case .refunded: "arrow.uturn.backward.circle.fill"
        case .cancelled: "xmark.octagon.fill"
        case .wrongEvent: "calendar.badge.clock"
        }
    }

    var isSuccess: Bool { self == .valid }
}

struct CheckInOutcome: Hashable, Sendable {
    var result: CheckInResult
    var attendeeName: String?
    var tierName: String?
    var checkedInAt: Date?
}

/// Pure state machine for the scanner. It prevents duplicate submissions of the same
/// code while a validation is in flight or while its result is on screen.
struct CheckInStateMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case requestingPermission
        case permissionDenied
        case scanning
        case validating(code: String)
        case result(code: String, outcome: CheckInOutcome)
        case networkError(code: String)
        /// No connection: the scanner refuses to admit anyone rather than guessing.
        case offlineRestricted
    }

    enum Event: Sendable {
        case startRequested(permission: CameraPermission)
        case permissionResolved(granted: Bool)
        /// `manual` codes are typed deliberately, so they skip the camera duplicate window.
        case codeDetected(String, isOnline: Bool, manual: Bool = false)
        case validationFinished(code: String, outcome: CheckInOutcome)
        case validationFailed(code: String)
        case dismissResult
        case connectivityChanged(isOnline: Bool)
    }

    enum CameraPermission: Sendable { case authorized, notDetermined, denied }

    private(set) var phase: Phase = .idle
    private(set) var lastCode: String?
    private(set) var lastCodeAt: Date?
    var duplicateWindow: TimeInterval = 4

    /// Returns `true` when the event should trigger a network validation for the code.
    @discardableResult
    mutating func handle(_ event: Event, now: Date = .now) -> Bool {
        switch event {
        case .startRequested(let permission):
            switch permission {
            case .authorized: phase = .scanning
            case .notDetermined: phase = .requestingPermission
            case .denied: phase = .permissionDenied
            }
        case .permissionResolved(let granted):
            phase = granted ? .scanning : .permissionDenied
        case .codeDetected(let raw, let isOnline, let manual):
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { return false }
            switch phase {
            case .scanning, .networkError, .offlineRestricted:
                break
            default:
                return false // busy validating or showing a result
            }
            if !manual, code == lastCode, let at = lastCodeAt, now.timeIntervalSince(at) < duplicateWindow {
                return false // the camera reported the same QR again
            }
            guard isOnline else {
                phase = .offlineRestricted
                return false
            }
            lastCode = code
            lastCodeAt = now
            phase = .validating(code: code)
            return true
        case .validationFinished(let code, let outcome):
            guard case .validating(let current) = phase, current == code else { return false }
            phase = .result(code: code, outcome: outcome)
        case .validationFailed(let code):
            guard case .validating(let current) = phase, current == code else { return false }
            phase = .networkError(code: code)
            lastCode = nil
        case .dismissResult:
            if case .result = phase { phase = .scanning }
            if case .networkError = phase { phase = .scanning }
            lastCodeAt = now
        case .connectivityChanged(let isOnline):
            if !isOnline, phase == .scanning { phase = .offlineRestricted }
            if isOnline, phase == .offlineRestricted { phase = .scanning }
        }
        return false
    }
}
