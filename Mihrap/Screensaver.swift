import CryptoKit
import UIKit

// MARK: - Texts and backgrounds (SlideAssets)

/// One screensaver text: a quotation (id 1…347) or one of the 99 Names (348…446).
struct SaverRecord {
    let id: Int
    let category: String
    let text: String
    let source: String
    let nameAr: String
    let name: String
    let meaning: String
    let translation: String
}

final class SaverAssets {
    static let shared = SaverAssets()
    static let changed = Notification.Name("MihrapSaverChanged")
    static let esmaFirst = 348, esmaCount = 99, quoteCount = 347
    private static let manifestURL = "https://raw.githubusercontent.com/mihrapnidaapp/tefekkur-assets/main/manifests/packages/screensaver-shared.json"
    /// The published web version serves the shared package's backgrounds byte for byte (checked by SHA-256).
    private static let pages = "https://mihrapnidaapp.github.io/mihrap-web/mihrap/slides/"

    private var texts = [String: [Int: SaverRecord]]()
    private var running = false
    private let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mihrap/saver", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
        return dir
    }()

    // MARK: texts

    func records(_ lang: String) -> [Int: SaverRecord] {
        if let t = texts[lang] { return t }
        var map = [Int: SaverRecord]()
        if let url = Bundle.main.url(forResource: lang, withExtension: "json", subdirectory: "texts"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for r in list {
                guard let id = r["id"] as? Int else { continue }
                map[id] = SaverRecord(id: id, category: r["category"] as? String ?? "", text: r["text"] as? String ?? "",
                                      source: (r["source_display"] as? String) ?? (r["source"] as? String) ?? "",
                                      nameAr: r["name_ar"] as? String ?? "", name: r["name"] as? String ?? "",
                                      meaning: r["meaning"] as? String ?? "", translation: r["translation"] as? String ?? "")
            }
        }
        texts[lang] = map
        return map
    }

    /// The record in that language, or English when it has none.
    func record(_ id: Int, _ lang: String) -> (SaverRecord, String)? {
        if let r = records(lang)[id] { return (r, lang) }
        if let r = records("en")[id] { return (r, "en") }
        return nil
    }

    /// ScreensaverTextRenderer.hidden: Mihrap's own translations the viewer chose not to see (Esma keeps the slide).
    func isHidden(_ id: Int, _ lang: String) -> Bool {
        if Settings.shared.mihrapTranslations { return false }
        guard let r = records(lang)[id] else { return false }
        return r.translation == "mihrap" && r.category != "ESMA"
    }

    /// The menu language plus the ticked screensaver languages.
    func languages() -> [String] {
        var out = [Settings.shared.language]
        for l in Settings.shared.saverLanguages where L10n.languages.contains(l) && !out.contains(l) { out.append(l) }
        return out
    }

    // MARK: backgrounds

    func backgroundFile(_ id: Int) -> URL {
        folder.appendingPathComponent(id >= SaverAssets.esmaFirst ? "esma.jpg" : String(format: "%03d.jpg", id))
    }

    /// Slide ids whose background is on the device.
    func availableIds() -> [Int] {
        let fm = FileManager.default
        var ids = (1...SaverAssets.quoteCount).filter { fm.fileExists(atPath: backgroundFile($0).path) }
        if fm.fileExists(atPath: backgroundFile(SaverAssets.esmaFirst).path) {
            ids += Array(SaverAssets.esmaFirst..<(SaverAssets.esmaFirst + SaverAssets.esmaCount))
        }
        return ids
    }

    var downloadedCount: Int { availableIds().filter { $0 < SaverAssets.esmaFirst }.count }

    private var lastId = -1

    /// SlideAssets.nextRandom: a random slide in a random screensaver language; hidden ones are skipped.
    func nextRandom() -> (id: Int, lang: String)? {
        let ids = availableIds()
        guard !ids.isEmpty else { return nil }
        let langs = languages()
        var id = 0, lang = "", tries = 0
        repeat {
            id = ids.randomElement()!
            lang = langs.randomElement()!
            tries += 1
        } while (id == lastId && ids.count > 1) || (tries < 60 && isHidden(id, lang))
        lastId = id
        return (id, lang)
    }

    /// Downloads the backgrounds the device does not have yet (about 80 MB the first time).
    func sync() {
        if running { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            defer { DispatchQueue.main.async { self.running = false } }
            guard let data = SaverAssets.fetch(URL(string: SaverAssets.manifestURL)!),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let slides = m["slides"] as? [[String: Any]] else { return }
            var added = 0
            for s in slides {
                guard let name = s["source_name"] as? String, let sha = s["sha256"] as? String else { continue }
                let isEsma = name.hasPrefix("esma/")
                let file = isEsma ? "esma.jpg" : (name as NSString).lastPathComponent
                let target = self.folder.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: target.path) { continue }
                guard let content = SaverAssets.fetch(URL(string: SaverAssets.pages + file)!) else { continue }
                let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
                guard digest == sha.lowercased() else { continue }
                try? content.write(to: target, options: .atomic)
                added += 1
                if added % 10 == 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: SaverAssets.changed, object: nil) } }
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: SaverAssets.changed, object: nil) }
        }
    }

    private static func fetch(_ url: URL) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Mihrap-iOS", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}

// MARK: - Slide drawing (ScreensaverTextRenderer), on a 1920×1080 landscape canvas

enum SlideRenderer {
    static let size = CGSize(width: 1920, height: 1080)

    private struct Tone { let dark: Bool; let text: UIColor; let source: UIColor; let outline: UIColor; let halo: UIColor }

    /// Draws the background and the text; also tells whether the text came out dark (for the clock line).
    static func render(id: Int, lang: String) -> (image: UIImage, dark: Bool)? {
        guard let bg = UIImage(contentsOfFile: SaverAssets.shared.backgroundFile(id).path) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var dark = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let ctx = rc.cgContext
            let w = size.width, h = size.height
            let s = max(w / bg.size.width, h / bg.size.height)
            bg.draw(in: CGRect(x: (w - bg.size.width * s) / 2, y: (h - bg.size.height * s) / 2, width: bg.size.width * s, height: bg.size.height * s))
            guard let (r, recLang) = SaverAssets.shared.record(id, lang) else { return }
            let sampler = Sampler(bg, canvas: size)
            if r.category == "ESMA" {
                let meaning = recLang != "ar" && (r.translation != "mihrap" || Settings.shared.mihrapTranslations)
                dark = drawEsma(ctx, r, arabic: recLang == "ar", showMeaning: meaning, sampler: sampler)
            } else if !r.text.isEmpty {
                dark = drawQuote(ctx, r, arabic: ["ar", "fa", "ur"].contains(recLang), sampler: sampler)
            }
        }
        return (image, dark)
    }

    private static func quoteFont(_ arabic: Bool, _ size: CGFloat) -> UIFont { arabic ? Fonts.arabic(size) : Fonts.serif(size) }

    private static func width(_ s: String, _ font: UIFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }

    private static func wrap(_ text: String, _ font: UIFont, _ maxWidth: CGFloat) -> [String] {
        var lines = [String]()
        for para in text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
            let p = para.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            let spaced = p.contains(" ")
            let units = spaced ? p.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) : p.map { String($0) }
            var line = ""
            for u in units {
                let candidate = line.isEmpty ? u : line + (spaced ? " " : "") + u
                if width(candidate, font) <= maxWidth || line.isEmpty { line = candidate } else { lines.append(line); line = u }
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// Near-white areas get dark text with a light halo; everything else white text with a dark outline and halo.
    private static func tone(_ sampler: Sampler, centerX: CGFloat, textWidth: CGFloat, top: CGFloat, bottom: CGFloat) -> Tone {
        let half = min(size.width * 0.5, textWidth * 0.5)
        let (lum, bright) = sampler.sample(CGRect(x: centerX - half, y: top, width: half * 2, height: bottom - top))
        if lum >= 145 || bright >= 0.5 {
            return Tone(dark: true, text: UIColor(hex: "#18202C"), source: UIColor(hex: "#2A2F38"),
                        outline: UIColor(red: 24 / 255, green: 32 / 255, blue: 44 / 255, alpha: 0.333), halo: UIColor(white: 1, alpha: 0.85))
        }
        let strength = max(0.55, min(0.9, 0.55 + (CGFloat(lum) - 80) / 120 * 0.35 + bright * 0.2))
        return Tone(dark: false, text: .white, source: UIColor(hex: "#F8EFD9"), outline: UIColor(white: 0, alpha: 0.9), halo: UIColor(white: 0, alpha: strength))
    }

    /// Halo (blurred stroke and fill, twice), then a thin outline, then the text.
    private static func drawToned(_ ctx: CGContext, _ text: String, centerX: CGFloat, baseline: CGFloat, font: UIFont, tone t: Tone, color: UIColor) {
        let size = font.pointSize
        let w = width(text, font)
        let origin = CGPoint(x: centerX - w / 2, y: baseline - font.ascender)
        let ns = text as NSString
        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = t.halo
        shadow.shadowBlurRadius = max(2, size * 0.11) * 2
        shadow.shadowOffset = .zero
        let haloStroke: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.halo, .strokeColor: t.halo,
                                                         .strokeWidth: -(size * 0.07) / size * 100, .shadow: shadow]
        for _ in 0..<2 { ns.draw(at: origin, withAttributes: haloStroke) }
        ctx.restoreGState()
        let outlineWidth = max(1.5, size * (t.dark ? 0.02 : 0.045))
        ns.draw(at: origin, withAttributes: [.font: font, .strokeColor: t.outline, .strokeWidth: outlineWidth / size * 100])
        ns.draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func cleanAttribution(_ v0: String) -> String {
        var v = v0
        for prefix in ["Hikmet — ", "Wisdom — ", "Weisheit — ", "حكمة — ", "حکمت — ", "Hikmah — ", "箴言 — ", "हिकमत — "] where v.hasPrefix(prefix) {
            v = String(v.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        switch v {
        case "Hikmet", "Genel Hikmet": return "Geleneksel"
        case "Wisdom", "Traditional wisdom": return "Traditional"
        case "Weisheit", "Überlieferte Weisheit": return "Überliefert"
        case "حكمة", "حكمة مأثورة": return "مأثور"
        default: return v
        }
    }

    private static func drawQuote(_ ctx: CGContext, _ r: SaverRecord, arabic: Bool, sampler: Sampler) -> Bool {
        let w = size.width, h = size.height, base = w
        let left = w * 0.105, right = w * 0.895, top = h * 0.13, bottom = h * 0.83
        let textBottom = bottom - h * 0.105, dividerY = bottom - h * 0.105
        let maxWidth = right - left - w * 0.07, maxTextHeight = h * 0.48
        let factor: CGFloat = arabic ? 1.48 : 1.30
        var fontSize = base * (arabic ? 0.041 : 0.038)
        let minSize = base * 0.022
        var lines = [String]()
        var used = fontSize
        while fontSize >= minSize {
            lines = wrap(r.text, quoteFont(arabic, fontSize), maxWidth)
            used = fontSize
            if CGFloat(lines.count) * fontSize * factor <= maxTextHeight { break }
            fontSize -= max(1, w * 0.0015)
        }
        guard !lines.isEmpty else { return false }
        let font = quoteFont(arabic, used)
        let lineHeight = used * factor
        var y = top + ((textBottom - top) - CGFloat(lines.count) * lineHeight) * 0.5 + used
        let center = w * 0.5
        // The first line chooses the tone for the whole quotation.
        let t = tone(sampler, centerX: center, textWidth: width(lines[0], font), top: y - used, bottom: y + used * 0.25)
        for line in lines {
            drawToned(ctx, line, centerX: center, baseline: y, font: font, tone: t, color: t.text)
            y += lineHeight
        }
        let srcSize = base * (arabic ? 0.022 : 0.020)
        let srcFont = arabic ? Fonts.arabic(srcSize) : Fonts.sans(srcSize, bold: true)
        var sy = dividerY + h * 0.055
        for line in wrap(cleanAttribution(r.source), srcFont, maxWidth * 0.86) {
            drawToned(ctx, line, centerX: center, baseline: sy, font: srcFont, tone: t, color: t.source)
            sy += srcSize * 1.22
        }
        return t.dark
    }

    private static func drawEsma(_ ctx: CGContext, _ r: SaverRecord, arabic: Bool, showMeaning: Bool, sampler: Sampler) -> Bool {
        let w = size.width, h = size.height, base = w, center = w * 0.5, maxWidth = w * 0.74
        let areaTop = h * 0.12, areaBottom = h * 0.78
        let nameAr = r.nameAr, name = arabic ? "" : r.name, meaning = showMeaning ? r.meaning : ""
        let meaningArabic = meaning.unicodeScalars.first.map { (0x0600...0x06FF).contains(Int($0.value)) } ?? false
        func meaningFont(_ s: CGFloat) -> UIFont { meaningArabic ? Fonts.arabic(s) : Fonts.serif(s) }
        var scale: CGFloat = 1
        var arSize: CGFloat = 0, nameSize: CGFloat = 0, meaningSize: CGFloat = 0, gap: CGFloat = 0, meaningLine: CGFloat = 0
        var total: CGFloat = 0, arH: CGFloat = 0, nameH: CGFloat = 0
        var meaningLines = [String]()
        while true {
            arSize = base * (arabic ? 0.12 : 0.095) * scale
            while width(nameAr, Fonts.arabic(arSize)) > maxWidth { arSize *= 0.95 }
            arH = arSize * 1.05
            nameSize = base * 0.044 * scale
            meaningSize = base * 0.028 * scale
            gap = base * 0.0225 * scale
            meaningLine = meaningSize * 1.3
            nameH = nameSize * 0.75
            total = arH
            if !name.isEmpty { total += gap + nameH }
            meaningLines = meaning.isEmpty ? [] : wrap(meaning, meaningFont(meaningSize), maxWidth)
            if !meaningLines.isEmpty { total += gap * 0.8 + meaningSize + CGFloat(meaningLines.count - 1) * meaningLine }
            if total <= areaBottom - areaTop || scale < 0.6 { break }
            scale *= 0.93
        }
        let top = areaTop + (areaBottom - areaTop - total) * 0.5
        var widest = width(nameAr, Fonts.arabic(arSize))
        if !name.isEmpty { widest = max(widest, width(name, Fonts.serif(nameSize))) }
        for l in meaningLines { widest = max(widest, width(l, meaningFont(meaningSize))) }
        let t = tone(sampler, centerX: center, textWidth: widest, top: top, bottom: top + total)
        var y = top + arH * 0.8
        drawToned(ctx, nameAr, centerX: center, baseline: y, font: Fonts.arabic(arSize), tone: t, color: t.text)
        y += arH * 0.2
        if !name.isEmpty {
            y += gap + nameH
            drawToned(ctx, name, centerX: center, baseline: y, font: Fonts.serif(nameSize), tone: t, color: t.text)
        }
        if !meaningLines.isEmpty {
            y += gap * 0.8 + meaningSize
            for l in meaningLines {
                drawToned(ctx, l, centerX: center, baseline: y, font: meaningFont(meaningSize), tone: t, color: t.text)
                y += meaningLine
            }
        }
        return t.dark
    }
}

/// Reads the background's brightness behind the text (20 × 12 samples, like the Android renderer).
private struct Sampler {
    private let pixels: [UInt8]
    private let pw = 192, ph = 108
    private let canvas: CGSize

    init(_ image: UIImage, canvas: CGSize) {
        self.canvas = canvas
        var buf = [UInt8](repeating: 0, count: 192 * 108 * 4)
        if let cg = image.cgImage, let ctx = CGContext(data: &buf, width: 192, height: 108, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            // Same aspect-fill placement as the slide itself.
            let s = max(canvas.width / image.size.width, canvas.height / image.size.height)
            let dw = image.size.width * s, dh = image.size.height * s
            let k = CGFloat(192) / canvas.width
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: (canvas.width - dw) / 2 * k, y: (canvas.height - dh) / 2 * k, width: dw * k, height: dh * k))
        }
        pixels = buf
    }

    /// Average luminance (0…255) and the share of bright samples in a canvas rectangle.
    func sample(_ r: CGRect) -> (Int, CGFloat) {
        let k = CGFloat(pw) / canvas.width
        let x0 = max(0, min(pw - 1, Int(r.minX * k))), x1 = max(x0 + 1, min(pw, Int(r.maxX * k)))
        let y0 = max(0, min(ph - 1, Int(r.minY * k))), y1 = max(y0 + 1, min(ph, Int(r.maxY * k)))
        var total = 0, bright = 0, n = 0
        for row in 0..<12 {
            let yy = y0 + (y1 - y0 - 1) * row / 11
            for col in 0..<20 {
                let xx = x0 + (x1 - x0 - 1) * col / 19
                // CGContext rows start at the bottom.
                let o = ((ph - 1 - yy) * pw + xx) * 4
                let l = (Int(pixels[o]) * 54 + Int(pixels[o + 1]) * 183 + Int(pixels[o + 2]) * 19) >> 8
                total += l; if l > 170 { bright += 1 }; n += 1
            }
        }
        return (n > 0 ? total / n : 80, n > 0 ? CGFloat(bright) / CGFloat(n) : 0)
    }
}

// MARK: - Screensaver screen

/// The whole landscape slide is shown; on a portrait or wider screen it sits on a blurred copy of itself
/// (the user rejected cropping). The prayer strip, next-prayer disc and clock line are drawn on top.
final class SlideView: UIView {
    private let fill = UIImageView(), blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark)), photo = UIImageView()
    var image: UIImage? { didSet { fill.image = image; photo.image = image } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        fill.contentMode = .scaleAspectFill
        photo.contentMode = .scaleAspectFit
        for v in [fill, blur, photo] as [UIView] {
            v.frame = bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(v)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class SaverOverlayView: UIView {
    var dark = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let now = Date()
        let s = HomeState(now)
        let ins = safeAreaInsets
        let W = bounds.width, H = bounds.height
        let unit = min(W, H) / 100
        // Shift a little every minute so nothing stays lit in one place for hours.
        let minute = Int(now.timeIntervalSince1970 / 60)
        let dx = CGFloat((minute * 7) % 5) * unit * 0.4, dy = CGFloat((minute * 3) % 3) * unit * 0.3
        let r = H > W ? min(W * 0.11, H * 0.06) : min(W * 0.06, H * 0.095)
        let bottom = H - max(ins.bottom, unit * 2) - dy
        let discX = W - max(ins.right, unit * 3) - r - dx, discY = bottom - r
        let stripH = H > W ? r * 1.5 : H * 0.11
        let stripLeft = max(ins.left, unit * 2) + dx
        UIColor(red: 16 / 255, green: 24 / 255, blue: 40 / 255, alpha: 0.36).setFill()
        UIBezierPath(roundedRect: CGRect(x: stripLeft, y: bottom - stripH, width: discX - stripLeft, height: stripH), cornerRadius: stripH * 0.3).fill()
        let n = s.names.count, left = stripLeft + unit, right = discX - r - unit
        if right > left {
            let slot = (right - left) / CGFloat(n)
            for i in 0..<n {
                let active = i == s.activeIndex
                let cx = left + slot * (CGFloat(i) + 0.5)
                Canvas.text(ctx, s.names[i], centerX: cx, baseline: bottom - stripH + stripH * 0.4,
                            font: Canvas.fit(s.names[i], maxWidth: slot * 0.9, size: stripH * 0.32) { Fonts.sans($0, bold: active) },
                            color: active ? .goldSoft : UIColor(white: 1, alpha: 0.8))
                Canvas.text(ctx, s.times[i], centerX: cx, baseline: bottom - stripH + stripH * 0.87,
                            font: Canvas.fit(s.times[i], maxWidth: slot * 0.92, size: stripH * 0.46) { Fonts.sans($0, bold: true) },
                            color: active ? .goldSoft : .white)
            }
        }
        Canvas.circle(discX, discY, r * 1.22, UIColor(red: 232 / 255, green: 197 / 255, blue: 106 / 255, alpha: 0.333))
        Canvas.circle(discX, discY, r, .goldSoft)
        if s.next != nil {
            let ink = UIColor(hex: "#5A3A08")
            Canvas.text(ctx, s.nextName, centerX: discX, baseline: discY - r * 0.2,
                        font: Canvas.fit(s.nextName, maxWidth: r * 1.5, size: r * 0.27) { Fonts.sans($0, bold: true) }, color: ink)
            Canvas.text(ctx, s.nextLeft, centerX: discX, baseline: discY + r * 0.38,
                        font: Canvas.fit(s.nextLeft, maxWidth: r * 1.62, size: r * 0.4) { Fonts.sans($0) }, color: ink)
        }
        let c = Calendar.current.dateComponents([.day, .month, .year, .hour, .minute], from: now)
        let line = "\(pad(c.day!))-\(pad(c.month!))-\(c.year!)  ·  \(pad(c.hour!)):\(pad(c.minute!))"
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: unit * 0.2), blur: unit * 0.8 * 1.15,
                      color: (dark ? UIColor(white: 1, alpha: 0.85) : UIColor(white: 0, alpha: 0.9)).cgColor)
        Canvas.text(ctx, line, centerX: W / 2, baseline: bottom - stripH - unit * 1.5,
                    font: Canvas.fit(line, maxWidth: W * 0.6, size: H > W ? W * 0.05 : H * 0.045) { Fonts.sans($0, bold: true) },
                    color: dark ? UIColor(hex: "#18202C") : .white)
        ctx.restoreGState()
    }
}

final class SaverViewController: UIViewController {
    private var front = SlideView(), back = SlideView()
    private let overlay = SaverOverlayView()
    private var slideTimer: Timer?, clockTimer: Timer?

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for v in [back, front] {
            v.frame = view.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(v)
        }
        back.isHidden = true
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        showNext(animated: false)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.overlay.setNeedsDisplay() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        slideTimer?.invalidate()
        clockTimer?.invalidate()
    }

    @objc private func close() { dismiss(animated: true) }

    private func showNext(animated: Bool) {
        let seconds = TimeInterval(max(5, Settings.shared.slideSeconds))
        guard let choice = SaverAssets.shared.nextRandom() else {
            slideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.showNext(animated: animated) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = SlideRenderer.render(id: choice.id, lang: choice.lang)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let rendered = rendered {
                    self.present(rendered.image, animated: animated)
                    self.overlay.dark = rendered.dark
                }
                self.slideTimer = Timer.scheduledTimer(withTimeInterval: rendered == nil ? 1 : seconds, repeats: false) { [weak self] _ in
                    self?.showNext(animated: true)
                }
            }
        }
    }

    /// SlideTransitions: fade, slide in from either side, rotate in, or a curved swing; 700 ms.
    private func present(_ image: UIImage, animated: Bool) {
        let incoming = back, outgoing = front
        incoming.image = image
        incoming.isHidden = false
        view.insertSubview(incoming, belowSubview: overlay)
        incoming.transform = .identity
        incoming.alpha = 1
        guard animated else {
            outgoing.isHidden = true
            front = incoming; back = outgoing
            return
        }
        let W = view.bounds.width, H = view.bounds.height
        var outEnd = CGAffineTransform.identity
        var outAlpha: CGFloat = 0
        switch Int.random(in: 0..<5) {
        case 1: incoming.transform = CGAffineTransform(translationX: W, y: 0); outEnd = CGAffineTransform(translationX: -W, y: 0); outAlpha = 1
        case 2: incoming.transform = CGAffineTransform(translationX: -W, y: 0); outEnd = CGAffineTransform(translationX: W, y: 0); outAlpha = 1
        case 3: incoming.transform = CGAffineTransform(rotationAngle: Bool.random() ? .pi / 2 : -.pi / 2); incoming.alpha = 0.2
        case 4:
            let fromRight = Bool.random()
            incoming.transform = CGAffineTransform(translationX: (fromRight ? 1.1 : -1.1) * W, y: (Bool.random() ? 0.35 : -0.35) * H)
                .rotated(by: (fromRight ? 18 : -18) * .pi / 180)
        default: incoming.alpha = 0
        }
        UIView.animate(withDuration: 0.7, delay: 0, options: [.curveEaseInOut]) {
            incoming.transform = .identity
            incoming.alpha = 1
            outgoing.transform = outEnd
            outgoing.alpha = outAlpha
        } completion: { _ in
            outgoing.isHidden = true
            outgoing.transform = .identity
            outgoing.alpha = 1
        }
        front = incoming; back = outgoing
    }
}

/// Notes every touch so the home screen knows when to start the screensaver.
final class IdleWindow: UIWindow {
    static var lastActivity = Date()
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches { IdleWindow.lastActivity = Date() }
        super.sendEvent(event)
    }
}
