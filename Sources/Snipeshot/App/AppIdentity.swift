import Foundation

/// Everything that carries the product name. Renaming the app starts here.
enum AppIdentity {
    static let name = "Snipeshot"
    static let bundleID = "io.github.thomasdallinger.snipeshot"
    /// Default capture folder inside ~/Pictures.
    static let folderName = "Snipeshot"
    /// Edit files sit next to each capture as `.<file>.<suffix>`.
    static let editFileSuffix = "snipeshot.json"
    static var logPrefix: String { "\(name):" }
}

func log(_ message: String) {
    NSLog("%@ %@", AppIdentity.logPrefix, message)
}
