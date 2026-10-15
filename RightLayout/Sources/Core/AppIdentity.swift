import Foundation

/// Identity of this build of RightLayout.
///
/// This is a fork of RightLayout by Alex Chernysh, published under its own name and
/// bundle identifier as required by the upstream name-use policy (TRADEMARKS.md).
public enum AppIdentity {
    /// Name shown to the user (menu bar, windows, notifications).
    public static let displayName = "RightLayout SergeyZh"
    public static let bundleIdentifier = "com.sergeyzh.rightlayout"
    /// GitHub repository releases and update checks come from.
    public static let repository = "SergeyZh/RightLayout"
    public static let repositoryURL = URL(string: "https://github.com/\(repository)")!
}
