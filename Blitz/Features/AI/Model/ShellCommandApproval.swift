import Foundation

/// Whether one chat's shell commands wait for the user; never stored, so every chat starts asking.
enum ShellCommandApproval: Equatable, Sendable {
    case ask
    case automatic
}
