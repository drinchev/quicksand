import Darwin
import Foundation

/// `qs list`: every sandbox with the repos cloned into it and its memory
/// repo. (It replaced cmd_list in qs.bash; the output is unchanged.)
public enum SandboxList {
    /// `homes` holds the sandbox users' homes (qs-NAME/), `shared` their
    /// workspaces, `installDir` qs's host-side manifests. `order` sorts the
    /// names the way bash sorts a glob (the locale's collation).
    public static func render(homes: URL, shared: URL, installDir: URL,
                              order: (String, String) -> Bool = collatedBefore) -> String {
        var out = "Sandboxes:\n"
        let names = subdirectories(of: homes, order: order)
            .filter { $0.hasPrefix("qs-") }
            .map { String($0.dropFirst(3)) }
        for name in names {
            out += "  \(name)\n"
            let workspace = shared.appendingPathComponent("qs-\(name)")
            // Clones live in the workspace (they survive rebuilds); the
            // host-side manifest adds the GitHub OWNER/REPO when known.
            let clones = installDir.appendingPathComponent("clones-\(name)")
            for repo in subdirectories(of: workspace.appendingPathComponent("repos"), order: order) {
                let owner = ownerRepo(manifest: clones, entry: repo)
                out += "    \(repo)\(owner.isEmpty ? "" : " (\(owner))")\n"
            }
            if isDirectory(workspace.appendingPathComponent("memory/.git")) {
                let owner = memoryOwnerRepo(manifest: installDir.appendingPathComponent("memory-\(name)"))
                out += "    memory\(owner.isEmpty ? "" : " (\(owner))")\n"
            }
        }
        if names.isEmpty { out += "  (none — run 'qs build <NAME>')\n" }
        return out
    }

    /// OWNER/REPO for `entry` in a clones manifest (REPO\tOWNER/REPO\tPATH
    /// lines), or "". Like `while read` in bash, an unterminated last line
    /// is not read.
    static func ownerRepo(manifest: URL, entry: String) -> String {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return "" }
        for line in text.components(separatedBy: "\n").dropLast() where line.hasPrefix(entry + "\t") {
            let rest = line.dropFirst(entry.count + 1)
            return String(rest.prefix { $0 != "\t" })
        }
        return ""
    }

    /// The second field of the memory manifest's first line. bash reads it
    /// with IFS=$'\t', which treats runs of tabs as one separator.
    static func memoryOwnerRepo(manifest: URL) -> String {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8),
              let first = text.components(separatedBy: "\n").first else { return "" }
        let fields = first.split(separator: "\t", omittingEmptySubsequences: true)
        return fields.count >= 2 ? String(fields[1]) : ""
    }

    /// Names of the directories in `dir` (following symlinks), skipping
    /// dotfiles, sorted like a bash glob `dir/*/`.
    static func subdirectories(of dir: URL, order: (String, String) -> Bool) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        // bash collates whole glob matches ("DIR/NAME/"), not bare names.
        let path = { (name: String) in "\(dir.path)/\(name)/" }
        return names
            .filter { !$0.hasPrefix(".") && isDirectory(dir.appendingPathComponent($0)) }
            .sorted { order(path($0), path($1)) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// strcoll order, as bash sorts glob matches. Call setlocale(LC_COLLATE,
    /// "") first to use the user's locale (the qs command does).
    public static func collatedBefore(_ a: String, _ b: String) -> Bool {
        strcoll(a, b) < 0
    }
}
