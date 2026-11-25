import Darwin
import Foundation

/// The `qs` link on the user's PATH that points at the qs inside the app,
/// like Docker Desktop's `docker` link. Installing it needs an admin
/// password (/usr/local/bin is root-owned), which macOS asks for.
public enum CommandLineTool {
    public static let defaultLink = "/usr/local/bin/qs"

    public enum Status: Equatable {
        /// Nothing at the link path.
        case missing
        /// The link already points at this app's qs.
        case installed
        /// A link into some other copy of Quicksand.app (an older build, a
        /// different location): replacing it is safe.
        case otherQuicksand(String)
        /// Something that isn't ours: a file, or a link elsewhere. Never
        /// replaced.
        case foreign(String)
    }

    /// What is at `link`, compared with `target` (this app's qs).
    public static func status(link: String = defaultLink, target: URL) -> Status {
        var st = stat()
        guard lstat(link, &st) == 0 else { return .missing }
        guard (st.st_mode & S_IFMT) == S_IFLNK,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link)
        else { return .foreign(link) }
        if URL(fileURLWithPath: dest).standardizedFileURL.path == target.standardizedFileURL.path {
            return .installed
        }
        return dest.hasSuffix(".app/Contents/MacOS/qs") ? .otherQuicksand(dest) : .foreign(dest)
    }

    /// The AppleScript that creates (or replaces) the link with an admin
    /// prompt. Paths go through `quoted form of`, so no path can break out
    /// of the shell command.
    public static func installScript(link: String = defaultLink, target: URL) -> String {
        let dir = (link as NSString).deletingLastPathComponent
        return """
        set linkDir to \(appleScriptString(dir))
        set linkPath to \(appleScriptString(link))
        set targetPath to \(appleScriptString(target.path))
        do shell script "/bin/mkdir -p " & quoted form of linkDir & " && /bin/ln -sfn " & quoted form of targetPath & " " & quoted form of linkPath with administrator privileges
        """
    }

    /// A Swift string as an AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
