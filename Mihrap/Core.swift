import CoreText
import Foundation
import UIKit

// MARK: - Languages and Android strings

enum L10n {
    static let languages = ["tr", "en", "de", "ar", "fa", "id", "ms", "zh", "ur", "hi"]
    static let names = ["tr": "Türkçe", "en": "English", "de": "Deutsch", "ar": "العربية", "fa": "فارسی",
                        "id": "Bahasa Indonesia", "ms": "Bahasa Melayu", "zh": "中文", "ur": "اردو", "hi": "हिन्दी"]
    static let rtl: Set<String> = ["ar", "fa", "ur"]
    private static var tables = [String: [String: String]]()

    static func table(_ lang: String) -> [String: String] {
        if let t = tables[lang] { return t }
        var t = [String: String]()
        if let url = Bundle.main.url(forResource: lang, withExtension: "json", subdirectory: "strings"),
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            t = parsed
        }
        tables[lang] = t
        return t
    }

    /// Android getString(): the text for the chosen language, English when missing.
    static func s(_ key: String) -> String {
        let lang = Settings.shared.language
        return table(lang)[key] ?? table("en")[key] ?? key
    }

    /// Android format strings: %1$s, %2$d, %s, %d.
    static func format(_ key: String, _ args: CustomStringConvertible...) -> String {
        var text = s(key)
        for (i, arg) in args.enumerated() {
            for spec in ["s", "d"] { text = text.replacingOccurrences(of: "%\(i + 1)$\(spec)", with: arg.description) }
        }
        if let first = args.first {
            for spec in ["%s", "%d"] {
                if let r = text.range(of: spec) { text.replaceSubrange(r, with: first.description) }
            }
        }
        return text
    }

    static func upper(_ s: String) -> String { s.uppercased(with: Locale(identifier: Settings.shared.language)) }
}

func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

// MARK: - Settings (Prefs)

final class Settings {
    static let shared = Settings()
    static let changed = Notification.Name("MihrapSettingsChanged")
    private let d = UserDefaults.standard

    private init() {
        // 0.1.0 lower-cased English place names with Turkish rules ("Unıted Kıngdom"); repair them once.
        if !d.bool(forKey: "fixedDotlessI") {
            d.set(true, forKey: "fixedDotlessI")
            if (d.string(forKey: "language") ?? "en") != "tr" {
                for key in ["countryName", "cityName", "districtName"] {
                    if let v = d.string(forKey: key) { d.set(v.replacingOccurrences(of: "ı", with: "i"), forKey: key) }
                }
            }
        }
        if d.string(forKey: "language") == nil {
            let preferred = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
            d.set(L10n.languages.contains(preferred) ? preferred : "en", forKey: "language")
        }
    }

    var language: String { get { d.string(forKey: "language") ?? "en" } set { d.set(newValue, forKey: "language") } }
    var countryId: String { get { d.string(forKey: "countryId") ?? "" } set { d.set(newValue, forKey: "countryId") } }
    var countryName: String { get { d.string(forKey: "countryName") ?? "" } set { d.set(newValue, forKey: "countryName") } }
    var cityId: String { get { d.string(forKey: "cityId") ?? "" } set { d.set(newValue, forKey: "cityId") } }
    var cityName: String { get { d.string(forKey: "cityName") ?? "" } set { d.set(newValue, forKey: "cityName") } }
    var districtId: String { get { d.string(forKey: "districtId") ?? "" } set { d.set(newValue, forKey: "districtId") } }
    var districtName: String { get { d.string(forKey: "districtName") ?? "" } set { d.set(newValue, forKey: "districtName") } }
    /// turkey, mecca, egypt, turkey2 or off (Prefs.getAzanType).
    var azan: String { get { d.string(forKey: "azan") ?? "turkey" } set { d.set(newValue, forKey: "azan") } }
    /// Our dua_after_adhan.mp3 after every adhan except Güneş (default on).
    var dua: Bool { get { d.object(forKey: "dua") as? Bool ?? true } set { d.set(newValue, forKey: "dua") } }
    /// Silent notifications at the prayer times while the app is closed.
    var notifications: Bool { get { d.object(forKey: "notifications") as? Bool ?? true } set { d.set(newValue, forKey: "notifications") } }
    /// Screensaver after this many idle seconds on the home screen; 0 = off (Prefs.getHomeIdleSeconds, default 30).
    var idleSeconds: Int { get { d.object(forKey: "idleSeconds") as? Int ?? 30 } set { d.set(newValue, forKey: "idleSeconds") } }
    /// Seconds per screensaver slide (default 20).
    var slideSeconds: Int { get { d.object(forKey: "slideSeconds") as? Int ?? 20 } set { d.set(newValue, forKey: "slideSeconds") } }
    /// Extra screensaver languages besides the menu language.
    var saverLanguages: [String] { get { d.stringArray(forKey: "saverLanguages") ?? [] } set { d.set(newValue, forKey: "saverLanguages") } }
    /// Show Mihrap's own translations of texts with no published translation (default on).
    var mihrapTranslations: Bool { get { d.object(forKey: "mihrapTranslations") as? Bool ?? true } set { d.set(newValue, forKey: "mihrapTranslations") } }
    /// Home theme preset index (ThemePresets.ALL).
    var theme: Int { get { d.integer(forKey: "theme") } set { d.set(newValue, forKey: "theme") } }

    func notifyChanged() { NotificationCenter.default.post(name: Settings.changed, object: nil) }
}

// MARK: - Fonts (the Android app's typefaces)

enum Fonts {
    private static var names = [String: String]()

    static func register() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider), let name = font.postScriptName {
                names[url.deletingPathExtension().lastPathComponent] = name as String
            }
        }
    }

    private static func font(_ file: String, _ size: CGFloat, fallback: UIFont.Weight) -> UIFont {
        if let name = names[file], let f = UIFont(name: name, size: size) { return f }
        return UIFont.systemFont(ofSize: size, weight: fallback)
    }

    static func sans(_ size: CGFloat, bold: Bool = false) -> UIFont {
        font(bold ? "Roboto-Bold" : "Roboto-Regular", size, fallback: bold ? .bold : .regular)
    }
    static func thin(_ size: CGFloat) -> UIFont { font("Roboto-Thin", size, fallback: .thin) }
    static func mono(_ size: CGFloat) -> UIFont {
        if let name = names["DroidSansMono"], let f = UIFont(name: name, size: size) { return f }
        return UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }
    static func serif(_ size: CGFloat, bold: Bool = false) -> UIFont {
        font(bold ? "NotoSerif-Bold" : "noto_serif_regular", size, fallback: bold ? .bold : .regular)
    }
    static func arabic(_ size: CGFloat) -> UIFont { font("amiri_regular", size, fallback: .regular) }
}

extension UIColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
    static let mihrapNavy = UIColor(hex: "#071a30")
    static let mihrapGold = UIColor(hex: "#d4a94a")
    static let goldSoft = UIColor(hex: "#F0D78A")
}

// MARK: - Small network helper

enum Net {
    static func json(_ url: String, timeout: TimeInterval = 20, _ done: @escaping (Any?) -> Void) {
        guard let u = URL(string: url) else { done(nil); return }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.setValue("Mihrap-iOS", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            var result: Any?
            if let data = data, let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) {
                result = try? JSONSerialization.jsonObject(with: data)
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}
