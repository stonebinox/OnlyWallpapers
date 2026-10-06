import Foundation
import Darwin

struct WebDirectoryResolver {
    struct ResolveResult {
        let url: URL
        let source: String
    }

    @MainActor
    static func resolve() -> ResolveResult {
        let env = ProcessInfo.processInfo.environment["WALLPAPER_WEB_DIR"]

        if let raw = env, !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            if !expanded.hasPrefix("/") {
                let line = "ONLYWALLPAPERS_WEB_RESOLVE status=fail source=env reason=not-absolute dir=" + expanded + "\n"
                FileHandle.standardOutput.write(Data(line.utf8))
                exit(EXIT_FAILURE)
            }
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            let indexPath = url.appendingPathComponent("index.html").path
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: indexPath, isDirectory: &isDir) || isDir.boolValue {
                let line = "ONLYWALLPAPERS_WEB_RESOLVE status=fail source=env reason=no-index dir=" + url.path + "\n"
                FileHandle.standardOutput.write(Data(line.utf8))
                exit(EXIT_FAILURE)
            }
            let line = "ONLYWALLPAPERS_WEB_RESOLVE status=ok source=env dir=" + url.path + "\n"
            FileHandle.standardOutput.write(Data(line.utf8))
            return ResolveResult(url: url, source: "env")
        }

        // Require all 3 code files to be regular, readable files.
        // A directory named wallpaper.js or an unreadable file must cause bundle fallback.
        if !AppStorageManager.seedFailed {
            let webDir = AppStorageManager.appSupportRoot().appendingPathComponent("web", isDirectory: true)
            let fm = FileManager.default
            let allPresent = ["index.html", "style.css", "wallpaper.js"].allSatisfy { name in
                var isDir: ObjCBool = false
                let path = webDir.appendingPathComponent(name).path
                return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isReadableFile(atPath: path)
            }
            if allPresent {
                let line = "ONLYWALLPAPERS_WEB_RESOLVE status=ok source=appstore dir=" + webDir.path + "\n"
                FileHandle.standardOutput.write(Data(line.utf8))
                return ResolveResult(url: webDir, source: "appstore")
            }
        }

        guard let idx = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            let line = "ONLYWALLPAPERS_WEB_RESOLVE status=fail source=bundle reason=no-index dir=\n"
            FileHandle.standardOutput.write(Data(line.utf8))
            exit(EXIT_FAILURE)
        }
        let webDir = idx.deletingLastPathComponent()
        let line = "ONLYWALLPAPERS_WEB_RESOLVE status=ok source=bundle dir=" + webDir.path + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        return ResolveResult(url: webDir, source: "bundle")
    }
}
