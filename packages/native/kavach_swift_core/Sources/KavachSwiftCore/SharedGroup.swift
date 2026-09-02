import Foundation

/// The single App Group / Keychain Access Group shared between the main
/// Kavach app and its credential-provider extension on each platform. Must
/// match the `keychain-access-groups` and `com.apple.security.application-groups`
/// entitlements set on every target (Runner, RunnerTests excluded, and the
/// two `KavachCredentialProvider` extensions).
public enum SharedGroup {
    public static let identifier = "group.com.kavach.shared"
}
