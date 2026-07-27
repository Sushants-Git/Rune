import Cocoa

/// The icon a project already ships — a web favicon, an Android launcher icon,
/// an Xcode app icon — used to mark its workspace in ⌘K.
///
/// A repo you work in every day has a face you already recognise, and it beats
/// another identical terminal glyph.
@MainActor
enum ProjectIcon {
    /// Look for a project icon at `directory` or, failing that, at each parent
    /// up to and including the repository root.
    static func image(forDirectory directory: String) -> NSImage? {
        if let cached = cache[directory] { return cached }

        let found = search(from: directory)
        cache[directory] = found
        return found
    }

    /// Cleared when a lookup could go stale is not worth the bookkeeping: a
    /// project gains a favicon roughly never, and a relaunch picks it up.
    private static var cache: [String: NSImage?] = [:]

    private static func search(from directory: String) -> NSImage? {
        let manager = FileManager.default
        var current = directory

        // Six levels is plenty to get from `src/components/foo` to the root,
        // and stopping at `.git` keeps one project from borrowing its
        // neighbour's icon out of a shared parent folder.
        for _ in 0..<6 {
            if let image = icon(in: current) { return image }

            var isDirectory: ObjCBool = false
            let git = (current as NSString).appendingPathComponent(".git")
            if manager.fileExists(atPath: git, isDirectory: &isDirectory) { return nil }

            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, parent != "/", !parent.isEmpty else { return nil }
            current = parent
        }
        return nil
    }

    private static func icon(in directory: String) -> NSImage? {
        let manager = FileManager.default

        for candidate in candidates {
            let path = (directory as NSString).appendingPathComponent(candidate)
            guard manager.fileExists(atPath: path),
                  let image = NSImage(contentsOfFile: path),
                  image.size.width > 0
            else { continue }
            return image
        }

        // Xcode keeps the app icon as a folder of sizes rather than one file.
        for catalog in ["Assets.xcassets", "Resources/Assets.xcassets"] {
            let appIcon = (directory as NSString)
                .appendingPathComponent("\(catalog)/AppIcon.appiconset")
            guard let entries = try? manager.contentsOfDirectory(atPath: appIcon) else { continue }
            // Largest file is the highest resolution, which is what we want to
            // downscale from.
            let best = entries
                .filter { $0.hasSuffix(".png") }
                .map { (appIcon as NSString).appendingPathComponent($0) }
                .max { fileSize($0) < fileSize($1) }
            if let best, let image = NSImage(contentsOfFile: best) { return image }
        }

        return nil
    }

    private static func fileSize(_ path: String) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else { return 0 }
        return (attributes[.size] as? Int) ?? 0
    }

    /// Where the common toolchains put an icon, most specific first. `.ico`,
    /// `.png` and `.svg` all decode through NSImage as-is.
    private static let candidates: [String] = [
        // Plain web
        "favicon.ico", "favicon.png", "favicon.svg",
        "public/favicon.ico", "public/favicon.png", "public/favicon.svg",
        "public/apple-touch-icon.png", "public/icon.png", "public/icon.svg",
        "public/logo.svg", "public/logo.png",

        // Next.js app router, SvelteKit, Astro, Vite
        "app/favicon.ico", "app/icon.png", "app/icon.svg",
        "src/app/favicon.ico", "src/app/icon.png", "src/app/icon.svg",
        "static/favicon.ico", "static/favicon.png", "static/favicon.svg",
        "src/favicon.ico", "src/favicon.svg",
        "assets/favicon.ico", "assets/favicon.png", "assets/favicon.svg",
        "src/assets/favicon.ico", "src/assets/favicon.png", "src/assets/favicon.svg",
        "src/assets/logo.svg", "src/assets/logo.png",

        // Docs sites and older layouts
        "docs/favicon.ico", "web/favicon.ico", "www/favicon.ico",
        "resources/favicon.ico", "dist/favicon.ico",

        // Android
        "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
        "app/src/main/res/mipmap-xhdpi/ic_launcher.png",
        "app/src/main/res/mipmap-hdpi/ic_launcher.png",
        "app/src/main/ic_launcher-playstore.png",
        "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
        "android/app/src/main/res/mipmap-xhdpi/ic_launcher.png",
    ]
}
