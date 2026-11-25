import Darwin
import Foundation
import Testing
@testable import QuicksandCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("qs-cmd-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}

// MARK: - The bash qs behind the Swift qs

@Suite struct LegacyCLITests {
    @Test func qsBashOverridesEverything() {
        let found = LegacyCLI.locateScript(environment: ["QS_BASH": "/somewhere/qs.bash"],
                                           executable: URL(fileURLWithPath: "/Applications/Quicksand.app/Contents/MacOS/qs"))
        #expect(found?.path == "/somewhere/qs.bash")
    }

    @Test func findsTheCopyInsideTheApp() throws {
        let root = try tempDir()
        let app = root.appendingPathComponent("Quicksand.app/Contents")
        try touch(app.appendingPathComponent("MacOS/qs"))
        try touch(app.appendingPathComponent("Resources/quicksand/qs.bash"))
        // A checkout above the app must not win over the bundled copy.
        try touch(root.appendingPathComponent("qs.bash"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("profile.d"), withIntermediateDirectories: true)

        let found = LegacyCLI.locateScript(environment: [:], executable: app.appendingPathComponent("MacOS/qs"))
        #expect(found?.path == app.appendingPathComponent("Resources/quicksand/qs.bash").path)
    }

    @Test func findsTheCheckoutAboveABuild() throws {
        let repo = try tempDir()
        try touch(repo.appendingPathComponent("qs.bash"))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("profile.d"), withIntermediateDirectories: true)
        let built = repo.appendingPathComponent("app/.build/arm64-apple-macosx/debug/qs")
        try touch(built)

        #expect(LegacyCLI.locateScript(environment: [:], executable: built)?.path
                == repo.appendingPathComponent("qs.bash").path)
    }

    @Test func aStrayQsBashWithoutProfileDIsNotACheckout() throws {
        let dir = try tempDir()
        try touch(dir.appendingPathComponent("qs.bash"))
        let exe = dir.appendingPathComponent("bin/qs")
        try touch(exe)
        #expect(LegacyCLI.locateScript(environment: [:], executable: exe) == nil)
        #expect(LegacyCLI.locateScript(environment: ["QS_BASH": ""], executable: nil) == nil)
    }

    @Test func passesTheArgumentsThroughUnchanged() {
        let args = LegacyCLI.arguments(script: URL(fileURLWithPath: "/r/qs.bash"),
                                       passing: ["claude", "work", "--", "-p", "a b", ""])
        #expect(args == ["/bin/bash", "/r/qs.bash", "claude", "work", "--", "-p", "a b", ""])
    }

    @Test func knowsItsOwnExecutable() {
        let exe = LegacyCLI.currentExecutable()
        #expect(exe != nil)
        #expect(exe.map { LegacyCLI.isRegularFile($0.path) } == true)
    }
}

// MARK: - Install qs command

@Suite struct CommandLineToolTests {
    let target = URL(fileURLWithPath: "/Applications/Quicksand.app/Contents/MacOS/qs")

    @Test func tellsWhatIsAtTheLinkPath() throws {
        let dir = try tempDir()
        let link = dir.appendingPathComponent("qs").path
        #expect(CommandLineTool.status(link: link, target: target) == .missing)

        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target.path)
        #expect(CommandLineTool.status(link: link, target: target) == .installed)

        try FileManager.default.removeItem(atPath: link)
        let older = "/Users/me/Downloads/Quicksand.app/Contents/MacOS/qs"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: older)
        #expect(CommandLineTool.status(link: link, target: target) == .otherQuicksand(older))

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/opt/homebrew/bin/qs")
        #expect(CommandLineTool.status(link: link, target: target) == .foreign("/opt/homebrew/bin/qs"))

        try FileManager.default.removeItem(atPath: link)
        try touch(URL(fileURLWithPath: link))
        #expect(CommandLineTool.status(link: link, target: target) == .foreign(link))
    }

    @Test func quotesPathsForAppleScriptAndTheShell() {
        let odd = URL(fileURLWithPath: "/Users/me/My \"Apps\"\\x/Quicksand.app/Contents/MacOS/qs")
        let script = CommandLineTool.installScript(target: odd)
        #expect(script.contains(#"set targetPath to "/Users/me/My \"Apps\"\\x/Quicksand.app/Contents/MacOS/qs""#))
        #expect(script.contains(#"set linkPath to "/usr/local/bin/qs""#))
        #expect(script.contains("quoted form of targetPath"))
        #expect(script.contains("with administrator privileges"))
    }
}
