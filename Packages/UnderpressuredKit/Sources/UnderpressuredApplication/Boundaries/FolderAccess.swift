import Foundation

/// Write access to folders that intake did not grant (spec §6). The sandboxed app asks the user with a folder panel.
@MainActor
public protocol FolderAccess: AnyObject {
    /// Whether the app may create new files in `folder`.
    func canCreateFiles(in folder: URL) -> Bool
    /// Asks the user for `folder` and returns once they answer. Processing reports a refusal as "No permission".
    func requestAccess(to folder: URL) async
}

/// Every folder is writable: the non-sandboxed app, and tests.
@MainActor
public final class UnrestrictedFolderAccess: FolderAccess {
    public init() {}
    public func canCreateFiles(in folder: URL) -> Bool { true }
    public func requestAccess(to folder: URL) async {}
}
