import Foundation
import Darwin

struct WebDirectoryResolver {
    @MainActor
    static func resolve() -> URL {
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
            return url
        }

        guard let idx = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            let line = "ONLYWALLPAPERS_WEB_RESOLVE status=fail source=bundle reason=no-index dir=\n"
            FileHandle.standardOutput.write(Data(line.utf8))
            exit(EXIT_FAILURE)
        }
        let webDir = idx.deletingLastPathComponent()
        let line = "ONLYWALLPAPERS_WEB_RESOLVE status=ok source=bundle dir=" + webDir.path + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        return webDir
    }
}
