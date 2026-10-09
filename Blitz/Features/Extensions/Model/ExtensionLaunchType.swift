import Foundation

/// Raw values must match `LaunchType` in the runtime's `enums.generated.js`, which JS compares.
enum ExtensionLaunchType: String, Sendable {
    case userInitiated
    case background
}
