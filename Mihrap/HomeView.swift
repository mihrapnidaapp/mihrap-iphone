import UIKit

/// The Android dimens for the current screen (values, values-port, values-sw600dp, values-sw720dp).
struct Dimens {
    let chipH: CGFloat, timeText: CGFloat, nameText: CGFloat, gap: CGFloat, topPad: CGFloat, actionBtn: CGFloat, actionText: CGFloat

    static func current(_ size: CGSize) -> Dimens {
        let shortSide = min(size.width, size.height)
        let portrait = size.height > size.width
        if shortSide >= 720 { return Dimens(chipH: 84, timeText: 16, nameText: 11, gap: 6, topPad: 28, actionBtn: 100, actionText: 12) }
        if shortSide >= 600 { return Dimens(chipH: 76, timeText: 15, nameText: 10, gap: 6, topPad: 28, actionBtn: 92, actionText: 11) }
        if portrait { return Dimens(chipH: 56, timeText: 12, nameText: 7, gap: 2, topPad: 16, actionBtn: 72, actionText: 9) }
        return Dimens(chipH: 64, timeText: 13, nameText: 9, gap: 4, topPad: 28, actionBtn: 80, actionText: 10)
    }
}

/// Everything the home screen shows for one second (MainActivity.updateClock).
struct HomeState {
    let now: Date
    let row: DayRow?
    let next: (key: String, when: Date)?
    let names: [String]
    let times: [String]
    let activeIndex: Int
    let nextName: String
    let nextLeft: String
    let nextSuffix: String
    let sunrise: String
    let sunset: String

    init(_ now: Date) {
        let pt = PrayerTimes.shared
        self.now = now
        let today = pt.row(for: now)
        row = today
        next = pt.next(after: now)
        let active = pt.activeKey(today, now)
        names = PrayerTimes.keys.map { prayerName($0, now) }
        times = PrayerTimes.keys.map { today?.times[$0] ?? "--:--" }
        activeIndex = PrayerTimes.keys.firstIndex(of: active) ?? -1
        if let n = next {
            let friday = Calendar.current.component(.weekday, from: now) == 6
            nextName = n.key == "Ogle" && friday ? L10n.s("dash_to_cuma") : L10n.s("dash_to_" + n.key)
            nextLeft = Hijri.remaining(n.when, now)
        } else {
            nextName = ""; nextLeft = ""
        }
        nextSuffix = L10n.s("time_left_suffix")
        sunrise = L10n.format("dash_sunrise", today?.times["Gunes"] ?? "--:--")
        sunset = L10n.format("dash_sunset", today?.times["Aksam"] ?? "--:--")
    }
}

/// Classic home (ThemePresets layout 1): photo, the six prayer chips, the clock with the civil and
/// Hijri date, the gold next-prayer disc and the sunrise/sunset pill. Drawn like MainActivity's views.
final class HomeView: UIView {
    var state: HomeState? { didSet { setNeedsDisplay() } }
    var message: String? { didSet { setNeedsDisplay() } }
    var clockStyle = 1
    private(set) var clockRect = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let s = state else { return }
        let size = bounds.size
        let insets = safeAreaInsets
        let dim = Dimens.current(size)
        let top = max(dim.topPad, insets.top + 4)
        let rowBottom = drawPrayerRow(ctx, s, top: top, left: insets.left + 2, width: size.width - insets.left - insets.right - 4, dim: dim)

        // Clock "HH:mm:ss" and the date lines, centred between the row and the bottom chrome.
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .day, .month, .year], from: s.now)
        let clock = "\(pad(c.hour!)):\(pad(c.minute!)):\(pad(c.second!))"
        let W = size.width, H = size.height
        let portrait = H > W
        let clockSize = portrait ? min(W * 0.19, H * 0.11) : min(H * 0.20, W * 0.16)
        let dateSize: CGFloat = portrait ? 15 : (min(W, H) >= 600 ? 24 : 17)
        let civil = "\(pad(c.day!))-\(pad(c.month!))-\(c.year!)"
        let lines = dateLines(s.now, civil)
        let clockH = 1.327 * clockSize
        let dateH = (0.128 + CGFloat(lines.count) * 1.172 + 0.027) * dateSize
        let block = clockH + 4 + dateH
        let cornersH = portrait ? min(W * 0.078, H * 0.12) * 2.6 + 24 : 0
        let bottom = H - max(insets.bottom, 12) - (portrait ? 96 : 96)
        var blockTop = rowBottom + cornersH + (bottom - rowBottom - cornersH - block) / 2
        blockTop = max(blockTop, rowBottom + cornersH)
        let clockColor = UIColor(hex: "#FFE6A0")
        let clockFont = clockStyle == 2 ? Fonts.mono(clockSize) : Fonts.thin(clockSize)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: clockStyle == 2 ? 1 : 2), blur: (clockStyle == 2 ? 4 : 10) * 1.15,
                      color: UIColor(white: 0, alpha: 0.8).cgColor)
        let clockWidth = Canvas.text(ctx, clock, centerX: W / 2, baseline: blockTop + 1.056 * clockSize, font: clockFont,
                                     color: clockColor, strokeWidth: clockSize / 32)
        ctx.restoreGState()
        clockRect = CGRect(x: W / 2 - clockWidth / 2, y: blockTop, width: clockWidth, height: clockH)
        var y = blockTop + clockH + 4 + 1.056 * dateSize
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6 * 1.15, color: UIColor(white: 0, alpha: 0.8).cgColor)
        for line in lines {
            let font = Canvas.fit(line.text, maxWidth: W * 0.94, size: dateSize) { Fonts.sans($0, bold: line.bold) }
            Canvas.text(ctx, line.text, centerX: W / 2, baseline: y, font: font, color: line.color ?? .goldSoft)
            y += 1.172 * dateSize
        }
        ctx.restoreGState()
        drawCorners(ctx, s, top: rowBottom, size: size, insets: insets)

        if let msg = message {
            let font = Fonts.sans(portrait ? 14 : 16)
            let w = (msg as NSString).size(withAttributes: [.font: font]).width + 48
            let pillW = min(w, W - 24)
            let pill = CGRect(x: (W - pillW) / 2, y: bottom - 40, width: pillW, height: 34)
            UIColor(white: 0.9, alpha: 0.92).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 17).fill()
            let f = Canvas.fit(msg, maxWidth: pillW - 24, size: font.pointSize) { Fonts.sans($0) }
            Canvas.text(ctx, msg, centerX: W / 2, baseline: pill.minY + 23, font: f, color: UIColor(hex: "#222222"))
        }
    }

    private func dateLines(_ now: Date, _ civil: String) -> [(text: String, color: UIColor?, bold: Bool)] {
        let hijri = Hijri.text(Hijri.parts(PrayerTimes.shared.row(for: now)))
        var out: [(String, UIColor?, Bool)] = [(hijri.isEmpty ? civil : civil + "  ·  " + hijri, nil, false)]
        let ramadan = Hijri.ramadanLine(now), event = Hijri.eventFor(now), kerahat = Hijri.kerahatLine(now)
        if !ramadan.isEmpty { out.append((ramadan, UIColor(hex: "#FFD27A"), true)) }
        if !event.isEmpty { out.append((event, UIColor(hex: "#FFD27A"), true)) }
        if !kerahat.isEmpty { out.append((kerahat, UIColor(hex: "#FF9C8A"), true)) }
        return out
    }

    // MainActivity.buildPrayerRow with ReferenceButtonDrawable chip variant 1.
    private func drawPrayerRow(_ ctx: CGContext, _ s: HomeState, top: CGFloat, left: CGFloat, width: CGFloat, dim: Dimens) -> CGFloat {
        let gap = dim.gap, chipH = dim.chipH
        let itemW = (width - gap * 5) / 6
        for i in 0..<6 {
            let hi = i == s.activeIndex
            let x = left + CGFloat(i) * (itemW + gap)
            let path = chipPath(CGRect(x: x, y: top, width: itemW, height: chipH))
            (hi ? UIColor(red: 29 / 255, green: 102 / 255, blue: 128 / 255, alpha: 0.933) : UIColor(red: 22 / 255, green: 75 / 255, blue: 104 / 255, alpha: 0.867)).setFill()
            path.fill()
            path.lineWidth = 2
            (hi ? UIColor(hex: "#FFD75A") : UIColor(hex: "#87C7D6")).setStroke()
            path.stroke()
            let cx = x + itemW / 2
            var y = top + 6
            (hi ? UIColor(hex: "#F0D88A") : UIColor(hex: "#E8C56A")).setFill()
            UIBezierPath(roundedRect: CGRect(x: cx - 11, y: y, width: 22, height: 2.5), cornerRadius: 1.25).fill()
            y += 2.5 + 4
            let timeFont = Canvas.fit(s.times[i], maxWidth: itemW - 8, size: dim.timeText) { Fonts.sans($0, bold: true) }
            Canvas.text(ctx, s.times[i], centerX: cx, baseline: y + 1.056 * dim.timeText, font: timeFont,
                        color: hi ? UIColor(hex: "#FFD75A") : .white)
            y += 1.327 * dim.timeText + 2
            let name = L10n.upper(s.names[i])
            let nameFont = Canvas.fit(name, maxWidth: itemW - 8, size: dim.nameText) { Fonts.sans($0) }
            Canvas.text(ctx, name, centerX: cx, baseline: y + 1.056 * dim.nameText, font: nameFont,
                        color: hi ? UIColor(hex: "#FFF8D0") : .white)
        }
        return top + chipH
    }

    private func chipPath(_ r: CGRect) -> UIBezierPath {
        let l = r.minX + 1, rr = r.maxX - 1, t = r.minY + 1, b = r.maxY - 2
        let shoulder = min(r.width * 0.16, r.height * 0.24), point = min(r.height * 0.16, r.width * 0.10)
        let p = UIBezierPath()
        p.move(to: CGPoint(x: l + shoulder, y: t))
        p.addLine(to: CGPoint(x: rr - shoulder, y: t))
        p.addLine(to: CGPoint(x: rr, y: t + shoulder))
        p.addLine(to: CGPoint(x: rr, y: b - point))
        p.addLine(to: CGPoint(x: (l + rr) / 2, y: b))
        p.addLine(to: CGPoint(x: l, y: b - point))
        p.addLine(to: CGPoint(x: l, y: t + shoulder))
        p.close()
        return p
    }

    // SkyHomeView corners-only mode: the gold next-prayer disc (right) and the sunrise/sunset pill (left).
    private func drawCorners(_ ctx: CGContext, _ s: HomeState, top: CGFloat, size: CGSize, insets: UIEdgeInsets) {
        let W = size.width, H = size.height
        let unit = min(W, H) / 100
        let r = H > W ? min(W * 0.16, H * 0.09) : min(W * 0.078, H * 0.12)
        let x = W - insets.right - r - unit * 4, y = top + r + unit * 4
        Canvas.circle(x, y, r * 1.22, UIColor(red: 232 / 255, green: 197 / 255, blue: 106 / 255, alpha: 0.333))
        Canvas.circle(x, y, r, .goldSoft)
        if s.next != nil {
            let ink = UIColor(hex: "#5A3A08")
            let suffix = !s.nextSuffix.isEmpty
            Canvas.text(ctx, s.nextName, centerX: x, baseline: y - r * (suffix ? 0.32 : 0.2),
                        font: Canvas.fit(s.nextName, maxWidth: r * 1.5, size: r * 0.27) { Fonts.sans($0, bold: true) }, color: ink)
            Canvas.text(ctx, s.nextLeft, centerX: x, baseline: y + r * (suffix ? 0.16 : 0.38),
                        font: Canvas.fit(s.nextLeft, maxWidth: r * 1.62, size: r * 0.4) { Fonts.sans($0) }, color: ink)
            if suffix {
                Canvas.text(ctx, s.nextSuffix, centerX: x, baseline: y + r * 0.52,
                            font: Canvas.fit(s.nextSuffix, maxWidth: r * 1.3, size: r * 0.24) { Fonts.sans($0) }, color: ink)
            }
        }
        // Sunrise / sunset pill.
        let px = insets.left + unit * 4, py = top + unit * 4
        let pw = H > W ? W * 0.36 : W * 0.15, ph = H > W ? r * 1.1 : H * 0.12
        let halo = unit * 1.2
        UIColor(red: 232 / 255, green: 197 / 255, blue: 106 / 255, alpha: 0.333).setFill()
        UIBezierPath(roundedRect: CGRect(x: px - halo, y: py - halo, width: pw + halo * 2, height: ph + halo * 2),
                     cornerRadius: (ph + halo * 2) / 2).fill()
        UIColor.goldSoft.setFill()
        UIBezierPath(roundedRect: CGRect(x: px, y: py, width: pw, height: ph), cornerRadius: ph / 2).fill()
        let ink = UIColor(hex: "#5A3A08")
        let textSize = H > W ? ph * 0.28 : H * 0.034
        Canvas.text(ctx, s.sunrise, centerX: px + pw / 2, baseline: py + ph * 0.43,
                    font: Canvas.fit(s.sunrise, maxWidth: pw * 0.84, size: textSize) { Fonts.sans($0) }, color: ink)
        Canvas.text(ctx, s.sunset, centerX: px + pw / 2, baseline: py + ph * 0.8,
                    font: Canvas.fit(s.sunset, maxWidth: pw * 0.84, size: textSize) { Fonts.sans($0) }, color: ink)
    }
}

/// Text drawing like Android's Canvas.drawText (x centred, y = baseline).
enum Canvas {
    @discardableResult
    static func text(_ ctx: CGContext, _ s: String, centerX: CGFloat, baseline: CGFloat, font: UIFont, color: UIColor,
                     strokeWidth: CGFloat = 0) -> CGFloat {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (s as NSString).size(withAttributes: attrs).width
        let origin = CGPoint(x: centerX - width / 2, y: baseline - font.ascender)
        (s as NSString).draw(at: origin, withAttributes: attrs)
        if strokeWidth > 0 { // Android's fake bold: the same colour stroked on top
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            attrs[.strokeColor] = color
            attrs[.strokeWidth] = strokeWidth / font.pointSize * 100
            (s as NSString).draw(at: origin, withAttributes: attrs)
            ctx.restoreGState()
        }
        return width
    }

    /// SkyHomeView.fitText: the given size, shrunk so the text fits maxWidth.
    static func fit(_ s: String, maxWidth: CGFloat, size: CGFloat, _ make: (CGFloat) -> UIFont) -> UIFont {
        let font = make(size)
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        if w > maxWidth && w > 0 { return make(max(1, size * maxWidth / w)) }
        return font
    }

    static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: UIColor) {
        color.setFill()
        UIBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
    }
}
