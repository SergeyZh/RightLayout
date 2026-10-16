import Foundation

extension Bundle {
    /// RightLayout's SwiftPM resource bundle.
    ///
    /// A release `.app` keeps it in `Contents/Resources`: `codesign` rejects anything
    /// in the bundle root, which is the only place the generated `Bundle.module` looks
    /// besides the build directory. `swift run` and tests fall back to `Bundle.module`.
    static let rightLayoutResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("RightLayout_RightLayout.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
