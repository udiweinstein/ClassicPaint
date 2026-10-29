import Cocoa

// MARK: - Check for Updates
//
// Asks GitHub for the latest published release and compares its tag (e.g. "1.5") with the
// running version (CFBundleShortVersionString). The repository comes from Info.plist
// (ClassicPaintUpdateRepo), so forks can point it at their own releases.

enum Updater {
    private static let lastCheckKey = "LastUpdateCheck"
    private static let autoCheckKey = "AutoCheckForUpdates"
    private static let skippedKey = "SkippedUpdateVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    private static var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "ClassicPaintUpdateRepo") as? String ?? "udiweinstein/ClassicPaint"
    }

    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    struct Release {
        let version: String
        let pageURL: URL
        let downloadURL: URL?
        let notes: String
    }

    /// "1.10" > "1.9", "v1.5" == "1.5", "1.5" == "1.5.0"
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".").map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func fetchLatest(_ done: @escaping (Result<Release, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClassicPaint/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result<Release, Error>
            if let error = error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(NSError(domain: "ClassicPaint", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: http.statusCode == 404
                        ? "No published release was found."
                        : "GitHub answered with status \(http.statusCode). Please try again later."]))
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let page = (json["html_url"] as? String).flatMap(URL.init(string:)) {
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true } ?? assets.first
                let dl = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))
                result = .success(Release(version: tag, pageURL: page, downloadURL: dl,
                                          notes: json["body"] as? String ?? ""))
            } else {
                result = .failure(NSError(domain: "ClassicPaint", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "The answer from GitHub could not be read."]))
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    /// Help ▸ Check for Updates… — always reports the result.
    static func checkNow() {
        fetchLatest { result in
            switch result {
            case .failure(let e):
                appDelegate.message("Couldn't check for updates.", e.localizedDescription)
            case .success(let r):
                UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                if compare(currentVersion, r.version) == .orderedAscending {
                    offer(r, manual: true)
                } else {
                    appDelegate.message("You're up to date!",
                                        "ClassicPaint \(currentVersion) is the latest version.")
                }
            }
        }
    }

    /// At launch: at most once a day, quietly; only speaks up when there is something new.
    static func checkInBackgroundIfDue() {
        guard autoCheck else { return }
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        fetchLatest { result in
            guard case .success(let r) = result else { return }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            guard compare(currentVersion, r.version) == .orderedAscending,
                  UserDefaults.standard.string(forKey: skippedKey) != r.version else { return }
            offer(r, manual: false)
        }
    }

    private static func offer(_ r: Release, manual: Bool) {
        let a = NSAlert()
        a.messageText = "A new version of ClassicPaint is available!"
        var info = "ClassicPaint \(r.version) is available — you have \(currentVersion)."
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            // first few lines of the release notes, without Markdown symbols
            let lines = notes.components(separatedBy: .newlines)
                .map { line in
                    var l = line.replacingOccurrences(of: "## ", with: "")
                    for mark in ["**", "*", "`"] { l = l.replacingOccurrences(of: mark, with: "") }
                    return l
                }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(6)
            info += "\n\n" + lines.joined(separator: "\n")
        }
        a.informativeText = info
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        if !manual { a.addButton(withTitle: "Skip This Version") }
        a.showsSuppressionButton = !manual
        a.suppressionButton?.title = "Check for updates automatically"
        a.suppressionButton?.state = autoCheck ? .on : .off
        let answer = a.runModal()
        if !manual { autoCheck = a.suppressionButton?.state == .on }
        switch answer {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(r.downloadURL ?? r.pageURL)   // downloads ClassicPaint.zip
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(r.version, forKey: skippedKey)
        default:
            break
        }
    }
}
