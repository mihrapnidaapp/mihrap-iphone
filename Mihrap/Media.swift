import CryptoKit
import Foundation

/// MediaDownloader + RemoteManifest: the same packages the Android app downloads from
/// mihrapnidaapp/tefekkur-assets (manifests on main, files in releases), SHA-256 checked.
final class Media {
    static let shared = Media()
    static let changed = Notification.Name("MihrapMediaChanged")
    private static let raw = "https://raw.githubusercontent.com/mihrapnidaapp/tefekkur-assets/main/"
    static let azanPackages = ["turkey": "azan-turkey", "mecca": "azan-mecca", "egypt": "azan-egypt", "turkey2": "azan-turkey2"]
    private static let roleToKey = ["fajr": "Imsak", "tulu": "Gunes", "dhuhr": "Ogle", "asr": "Ikindi", "maghrib": "Aksam", "isha": "Yatsi"]

    private let root: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mihrap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
        return dir
    }()
    private var running = false
    private(set) var busy = false

    // MARK: manifests

    private func manifestFile(_ package: String) -> URL { root.appendingPathComponent("manifests/\(package).json") }

    func manifest(_ package: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: manifestFile(package)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func entries(_ m: [String: Any]?) -> [[String: Any]] {
        (m?["slides"] as? [[String: Any]]) ?? (m?["tracks"] as? [[String: Any]]) ?? []
    }

    func localFile(_ entry: [String: Any]) -> URL? {
        guard let file = entry["file"] as? String else { return nil }
        let url = root.appendingPathComponent(file)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return nil }
        if let expected = entry["bytes"] as? Int64, expected > 0, size != expected { return nil }
        if let expected = entry["bytes"] as? Int, expected > 0, size != Int64(expected) { return nil }
        return url
    }

    // MARK: what the app plays and shows

    /// Recordings for a prayer key from the chosen adhan package, in the package's order.
    func tracks(_ key: String) -> [URL] {
        guard let package = Media.azanPackages[Settings.shared.azan] else { return [] }
        return entries(manifest(package))
            .filter { Media.roleToKey[$0["role"] as? String ?? ""] == key }
            .sorted { ($0["source_name"] as? String ?? "") < ($1["source_name"] as? String ?? "") }
            .compactMap { localFile($0) }
    }

    var dua: URL? {
        entries(manifest("audio-extras")).first { ($0["role"] as? String) == "after_adhan_dua" }.flatMap { localFile($0) }
    }

    /// Adhan mosque photos with their caption in the chosen language (AdhanVisuals.caption).
    func adhanVisuals() -> [(url: URL, caption: String)] {
        let lang = Settings.shared.language
        let suffix = ["tr": "tr", "de": "de", "ar": "ar"][lang] ?? "en"
        return entries(manifest("adhan-visuals")).compactMap { e in
            guard let url = localFile(e) else { return nil }
            let name = e["mosque_name_" + suffix] as? String ?? ""
            let country = e["country_" + suffix] as? String ?? ""
            return (url, country.isEmpty ? name : name + " — " + country)
        }
    }

    // MARK: download

    func wantedPackages() -> [String] {
        var out = ["audio-extras", "adhan-visuals"]
        if let azan = Media.azanPackages[Settings.shared.azan] { out.append(azan) }
        return out
    }

    /// Fetches the newest manifests, downloads missing or changed files, removes files no longer listed.
    func sync() {
        if running { return }
        running = true
        busy = true
        let packages = wantedPackages()
        DispatchQueue.global(qos: .utility).async {
            for package in packages { self.syncPackage(package) }
            DispatchQueue.main.async {
                self.running = false
                self.busy = false
                NotificationCenter.default.post(name: Media.changed, object: nil)
            }
        }
    }

    private func syncPackage(_ package: String) {
        if let data = Media.download(URL(string: Media.raw + "manifests/packages/\(package).json")!),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !entries(parsed).isEmpty {
            let current = manifest(package)
            if (parsed["revision"] as? Int ?? 0) >= (current?["revision"] as? Int ?? 0) {
                try? FileManager.default.createDirectory(at: manifestFile(package).deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: manifestFile(package), options: .atomic)
            }
        }
        guard let m = manifest(package) else { return }
        let list = entries(m)
        for entry in list where localFile(entry) == nil {
            guard let file = entry["file"] as? String, let address = entry["url"] as? String, let url = URL(string: address),
                  let data = Media.download(url) else { continue }
            if let sha = entry["sha256"] as? String, !sha.isEmpty {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if digest != sha.lowercased() { continue }
            }
            let target = root.appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
            DispatchQueue.main.async { NotificationCenter.default.post(name: Media.changed, object: nil) }
        }
        // Files the manifest no longer lists (for example removed adhan photos) are deleted.
        if let folder = m["folder"] as? String {
            let listed = Set(list.compactMap { ($0["file"] as? String).map { ($0 as NSString).lastPathComponent } })
            let dir = root.appendingPathComponent(folder)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !listed.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private static func download(_ url: URL) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("Mihrap-iOS", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let code = (response as? HTTPURLResponse)?.statusCode, code == 200 { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}
