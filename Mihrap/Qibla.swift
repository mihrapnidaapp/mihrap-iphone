import CoreLocation
import UIKit

/// Qibla finder. Two looks, chosen on the screen: a brass compass, or a globe with the shortest route to
/// the Kaaba above a sliding compass tape. Both stand inside a mihrab arch.
/// Location: the phone's GPS when allowed, otherwise the coordinates of the chosen district.
enum Qibla {
    static let kaaba = CLLocationCoordinate2D(latitude: 21.422487, longitude: 39.826206)

    /// Initial great-circle bearing from the place to the Kaaba, degrees clockwise from true north.
    static func bearing(from p: CLLocationCoordinate2D) -> Double {
        let φ1 = p.latitude * .pi / 180, φ2 = kaaba.latitude * .pi / 180
        let Δλ = (kaaba.longitude - p.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The sun's azimuth (degrees clockwise from true north) and altitude, for a place and moment
    /// (low-precision solar position, accurate to well under a degree).
    static func sun(at p: CLLocationCoordinate2D, date: Date = Date()) -> (azimuth: Double, altitude: Double) {
        let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let rad = Double.pi / 180
        let g = (357.529 + 0.98560028 * d) * rad
        let q = 280.459 + 0.98564736 * d
        let L = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let e = (23.439 - 0.00000036 * d) * rad
        let ra = atan2(cos(e) * sin(L), cos(L))
        let dec = asin(sin(e) * sin(L))
        let gmst = (18.697374558 + 24.06570982441908 * d).truncatingRemainder(dividingBy: 24)
        let ha = ((gmst + p.longitude / 15) * 15) * rad - ra
        let lat = p.latitude * rad
        let alt = asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha))
        let az = atan2(-sin(ha), tan(dec) * cos(lat) - sin(lat) * cos(ha))
        return ((az / rad + 360).truncatingRemainder(dividingBy: 360), alt / rad)
    }

    static func distanceKm(from p: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: CLLocation(latitude: kaaba.latitude, longitude: kaaba.longitude)) / 1000
    }

    /// Coordinates of the chosen district from OpenStreetMap (the same lookup the web version uses).
    static func districtCoordinates(_ done: @escaping (CLLocationCoordinate2D?) -> Void) {
        let s = Settings.shared
        let key = "coords_" + s.districtId
        if let saved = UserDefaults.standard.array(forKey: key) as? [Double], saved.count == 2 {
            done(CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1])); return
        }
        let queries = [[s.districtName, s.cityName, s.countryName], [s.districtName, s.countryName], [s.cityName, s.countryName]]
            .map { $0.filter { !$0.isEmpty }.joined(separator: ", ") }.filter { !$0.isEmpty }
        func attempt(_ i: Int) {
            guard i < queries.count, !s.districtId.isEmpty else { done(nil); return }
            var c = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
            c.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "q", value: queries[i])]
            Net.json(c.url!.absoluteString) { json in
                if let first = (json as? [[String: Any]])?.first, let lat = Double(first["lat"] as? String ?? ""), let lon = Double(first["lon"] as? String ?? "") {
                    UserDefaults.standard.set([lat, lon], forKey: key)
                    done(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { attempt(i + 1) } // one request per second
                }
            }
        }
        attempt(0)
    }

    /// Signed turn from the heading to the qibla, -180…180 (positive: turn right).
    static func turn(from heading: Double, to qibla: Double) -> Double {
        var d = (qibla - heading).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Compass letters for N, E, S, W in the app language.
    static var nesw: [String] {
        let parts = IOSText.s("qibla_nesw").split(separator: " ").map(String.init)
        return parts.count == 4 ? parts : ["N", "E", "S", "W"]
    }

    static let teal = UIColor(hex: "#3CC6A8")

    /// The Kaaba mark: a black cube with a gold band, centred on the current origin.
    static func drawKaaba(_ ctx: CGContext, half k: CGFloat, gold: UIColor) {
        let body = UIBezierPath(roundedRect: CGRect(x: -k, y: -k, width: k * 2, height: k * 2), cornerRadius: k * 0.15)
        UIColor(hex: "#0E0E0E").setFill()
        body.fill()
        body.lineWidth = max(1, k * 0.1)
        gold.setStroke()
        body.stroke()
        gold.setFill()
        UIBezierPath(rect: CGRect(x: -k, y: -k * 0.5, width: k * 2, height: k * 0.3)).fill()
    }

    static func drawSun(at p: CGPoint, radius sr: CGFloat) {
        let color = UIColor(hex: "#FFD75A")
        color.setStroke()
        for i in 0..<8 {
            let b = CGFloat(i) * .pi / 4
            let ray = UIBezierPath()
            ray.move(to: CGPoint(x: p.x + cos(b) * sr * 1.4, y: p.y + sin(b) * sr * 1.4))
            ray.addLine(to: CGPoint(x: p.x + cos(b) * sr * 2, y: p.y + sin(b) * sr * 2))
            ray.lineWidth = max(1.5, sr * 0.25)
            ray.stroke()
        }
        Canvas.circle(p.x, p.y, sr, color)
    }
}

final class QiblaViewController: UIViewController, CLLocationManagerDelegate {
    private enum Style: String { case brass, map }
    private struct Palette { let background, archFill, archLine, accent, text, muted: UIColor }

    private let manager = CLLocationManager()
    private let arch = MihrabArchView()
    private let picker = UISegmentedControl(items: [IOSText.s("qibla_compass"), IOSText.s("qibla_map")])
    private let slot = UIView()
    private let brass = BrassDialView()
    private let globe = GlobeView()
    private let tape = HeadingTapeView()
    private let titleLabel = UILabel(), angleLabel = UILabel(), turnLabel = UILabel(), infoLabel = UILabel(), hintLabel = UILabel()
    private var place: CLLocationCoordinate2D?
    private var usingGPS = false
    private var heading: Double = -1
    private var qibla: Double = -1
    private var aligned = false
    private let haptic = UINotificationFeedbackGenerator()
    /// Without a compass the dial turns so the sun sits at the top: point the top edge at the sun.
    private var sunMode = false
    private var sunTimer: Timer?
    private var style = Style(rawValue: UserDefaults.standard.string(forKey: "qibla_style") ?? "") ?? .brass

    private var palette: Palette {
        switch style {
        case .brass:
            return Palette(background: UIColor(hex: "#15140F"), archFill: UIColor(hex: "#1D1A14"), archLine: UIColor(hex: "#B8893A"),
                           accent: UIColor(hex: "#E9C77A"), text: UIColor(hex: "#F2EBDD"), muted: UIColor(hex: "#B5AC9A"))
        case .map:
            return Palette(background: UIColor(hex: "#0A2A3C"), archFill: UIColor(hex: "#0F3A52"), archLine: UIColor(hex: "#C9A75A"),
                           accent: UIColor(hex: "#F0D78A"), text: .white, muted: UIColor(hex: "#A9C3CF"))
        }
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = IOSText.s("qibla")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.upper(L10n.s("close")), style: .done, target: self, action: #selector(close))
        for v in [arch, picker, slot, titleLabel, angleLabel, turnLabel, infoLabel, hintLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(arch)
        picker.selectedSegmentIndex = style == .brass ? 0 : 1
        picker.addTarget(self, action: #selector(styleChanged), for: .valueChanged)
        view.addSubview(picker)
        view.addSubview(slot)
        for v in [brass, globe, tape] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(v)
        }
        globe.placeName = Settings.shared.districtName.isEmpty ? IOSText.s("qibla_you") : Settings.shared.districtName
        globe.meccaName = IOSText.s("qibla_mecca")

        titleLabel.text = L10n.upper(IOSText.s("qibla"))
        titleLabel.font = Fonts.sans(13)
        turnLabel.font = Fonts.sans(18)
        infoLabel.font = Fonts.sans(14)
        hintLabel.font = Fonts.sans(13)
        hintLabel.numberOfLines = 0
        infoLabel.numberOfLines = 2
        for l in [titleLabel, angleLabel, turnLabel, infoLabel, hintLabel] {
            l.textAlignment = .center
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.6
        }
        let stack = UIStackView(arrangedSubviews: [titleLabel, angleLabel, turnLabel, infoLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(hintLabel)

        let g = view.safeAreaLayoutGuide
        let side = slot.widthAnchor.constraint(equalTo: g.widthAnchor, multiplier: 0.86)
        side.priority = .defaultHigh
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            picker.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            picker.widthAnchor.constraint(equalToConstant: 240),

            arch.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 10),
            arch.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 10),
            arch.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -10),
            arch.bottomAnchor.constraint(equalTo: g.bottomAnchor),

            slot.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 48),
            slot.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            slot.heightAnchor.constraint(equalTo: slot.widthAnchor),
            side,
            slot.heightAnchor.constraint(lessThanOrEqualTo: g.heightAnchor, multiplier: 0.5),

            brass.topAnchor.constraint(equalTo: slot.topAnchor),
            brass.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            brass.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            brass.trailingAnchor.constraint(equalTo: slot.trailingAnchor),

            tape.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            tape.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 28),
            tape.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -28),
            tape.heightAnchor.constraint(equalToConstant: 92),
            globe.topAnchor.constraint(equalTo: slot.topAnchor),
            globe.bottomAnchor.constraint(equalTo: tape.topAnchor, constant: -14),
            globe.widthAnchor.constraint(equalTo: globe.heightAnchor),
            globe.centerXAnchor.constraint(equalTo: slot.centerXAnchor),

            stack.topAnchor.constraint(equalTo: slot.bottomAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -36),
            hintLabel.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 10),
            hintLabel.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -72),
            hintLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 40),
            hintLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -40),
        ])
        applyStyle()

        manager.delegate = self
        manager.headingFilter = 1
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        hintLabel.text = IOSText.s("qibla_flat")
        // Until the GPS answers (or when it is not allowed), use the chosen district.
        Qibla.districtCoordinates { [weak self] c in
            guard let self = self, !self.usingGPS, let c = c else { return }
            self.set(place: c, gps: false)
        }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        } else {
            sunMode = true
            sunTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.updateSun() }
            updateSun()
        }
        refresh()
    }

    @objc private func styleChanged() {
        style = picker.selectedSegmentIndex == 0 ? .brass : .map
        UserDefaults.standard.set(style.rawValue, forKey: "qibla_style")
        applyStyle()
        refresh()
    }

    private func applyStyle() {
        let p = palette
        view.backgroundColor = p.background
        arch.fill = p.archFill
        arch.line = p.archLine
        brass.isHidden = style != .brass
        globe.isHidden = style != .map
        tape.isHidden = style != .map
        titleLabel.isHidden = style != .brass
        titleLabel.textColor = p.muted
        titleLabel.attributedText = NSAttributedString(string: L10n.upper(IOSText.s("qibla")), attributes: [.kern: 4, .font: Fonts.sans(13), .foregroundColor: p.muted])
        angleLabel.font = style == .brass ? Fonts.serif(54) : Fonts.sans(38, bold: true)
        angleLabel.textColor = p.accent
        infoLabel.textColor = p.muted
        hintLabel.textColor = p.muted
        picker.selectedSegmentTintColor = p.accent
        picker.backgroundColor = p.archFill
        picker.setTitleTextAttributes([.foregroundColor: p.text, .font: Fonts.sans(14)], for: .normal)
        picker.setTitleTextAttributes([.foregroundColor: p.background, .font: Fonts.sans(14, bold: true)], for: .selected)
        if let bar = navigationController?.navigationBar {
            let a = UINavigationBarAppearance()
            a.configureWithOpaqueBackground()
            a.backgroundColor = p.background
            a.shadowColor = .clear
            a.titleTextAttributes = [.foregroundColor: p.text, .font: Fonts.sans(17, bold: true)]
            bar.standardAppearance = a
            bar.scrollEdgeAppearance = a
            bar.compactAppearance = a
            bar.tintColor = p.accent
        }
    }

    private func updateSun() {
        guard sunMode else { return }
        guard let p = place else { hintLabel.text = IOSText.s("qibla_sun"); return }
        let s = Qibla.sun(at: p)
        if s.altitude > 0 {
            brass.sun = s.azimuth
            tape.sun = s.azimuth
            heading = s.azimuth
            hintLabel.text = IOSText.s("qibla_sun")
        } else {
            brass.sun = -1
            tape.sun = -1
            heading = -1
            hintLabel.text = IOSText.s("qibla_sun_down")
        }
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        manager.stopUpdatingHeading()
        manager.stopUpdatingLocation()
        sunTimer?.invalidate()
    }

    @objc private func close() { dismiss(animated: true) }

    private func set(place c: CLLocationCoordinate2D, gps: Bool) {
        place = c
        usingGPS = gps
        qibla = Qibla.bearing(from: c)
        globe.place = c
        updateSun()
        refresh()
    }

    /// Everything on screen from the current place, heading and look.
    private func refresh() {
        let p = palette
        brass.qibla = qibla
        brass.heading = max(heading, 0)
        tape.qibla = qibla
        tape.heading = heading
        guard qibla >= 0, let c = place else {
            angleLabel.text = "—"
            turnLabel.text = ""
            infoLabel.text = ""
            return
        }
        let degrees = "\(Int(qibla.rounded()) % 360)°"
        angleLabel.text = style == .brass ? degrees : IOSText.s("qibla") + " " + degrees
        var nowAligned = false
        if heading >= 0 {
            let d = Qibla.turn(from: heading, to: qibla)
            nowAligned = abs(d) <= 3
            turnLabel.text = nowAligned ? IOSText.s("qibla_aligned")
                : String(format: IOSText.s(d > 0 ? "qibla_right" : "qibla_left"), "\(Int(abs(d).rounded()))")
        } else {
            turnLabel.text = ""
        }
        turnLabel.textColor = nowAligned ? Qibla.teal : p.text
        turnLabel.font = nowAligned ? Fonts.sans(20, bold: true) : Fonts.sans(18)
        if nowAligned != aligned {
            aligned = nowAligned
            brass.aligned = nowAligned
            tape.aligned = nowAligned
            if nowAligned { haptic.notificationOccurred(.success) }
        }
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        nf.locale = Locale(identifier: Settings.shared.language)
        let km = Qibla.distanceKm(from: c)
        var parts = [String(format: IOSText.s("qibla_distance"), nf.string(from: NSNumber(value: km)) ?? "\(Int(km))")]
        let s = Settings.shared
        if !s.districtName.isEmpty { parts.append(s.districtName) }
        if usingGPS { parts.append("GPS") }
        infoLabel.text = parts.joined(separator: " · ")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 5000 else { return }
        set(place: loc.coordinate, gps: true)
        if loc.horizontalAccuracy < 200 { manager.stopUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        heading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        if h.headingAccuracy < 0 || h.headingAccuracy > 20 {
            hintLabel.text = IOSText.s("qibla_calibrate")
        } else {
            hintLabel.text = IOSText.s("qibla_flat")
        }
        refresh()
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
}

/// The mihrab behind the compass: a pointed arch with an inner line, and a prayer-rug border of
/// eight-pointed stars along the bottom.
final class MihrabArchView: UIView {
    var fill = UIColor(hex: "#0F3A52") { didSet { setNeedsDisplay() } }
    var line = UIColor(hex: "#C9A75A") { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    private func archPath(inset i: CGFloat) -> UIBezierPath {
        let left = i, right = bounds.width - i, w = right - left, mid = bounds.midX
        let apex = i * 1.4
        let spring = apex + w * 0.58
        let base = archBottom - i * 0.6
        let p = UIBezierPath()
        p.move(to: CGPoint(x: left, y: base))
        p.addLine(to: CGPoint(x: left, y: spring))
        p.addCurve(to: CGPoint(x: mid, y: apex), controlPoint1: CGPoint(x: left, y: spring - w * 0.29),
                   controlPoint2: CGPoint(x: left + w * 0.263, y: apex + w * 0.115))
        p.addCurve(to: CGPoint(x: right, y: spring), controlPoint1: CGPoint(x: right - w * 0.263, y: apex + w * 0.115),
                   controlPoint2: CGPoint(x: right, y: spring - w * 0.29))
        p.addLine(to: CGPoint(x: right, y: base))
        p.close()
        return p
    }

    /// The arch closes above the bottom of the view; the fringe hangs below it.
    private var archBottom: CGFloat { bounds.height - 18 }

    override func draw(_ rect: CGRect) {
        let outer = archPath(inset: 2)
        fill.setFill()
        outer.fill()
        outer.lineWidth = 1.5
        line.setStroke()
        outer.stroke()
        let inner = archPath(inset: 18)
        inner.lineWidth = 1
        line.withAlphaComponent(0.35).setStroke()
        inner.stroke()
        // Rug border: two lines with a row of small eight-pointed stars between them.
        let top = archBottom - 46, bottom = archBottom - 20, left: CGFloat = 18, right = bounds.width - 18
        line.withAlphaComponent(0.35).setStroke()
        for y in [top, bottom] {
            let l = UIBezierPath()
            l.move(to: CGPoint(x: left, y: y))
            l.addLine(to: CGPoint(x: right, y: y))
            l.lineWidth = 1
            l.stroke()
        }
        // Fringe below the arch, like the end of a prayer rug.
        line.withAlphaComponent(0.5).setStroke()
        var x: CGFloat = 8
        while x <= bounds.width - 8 {
            let f = UIBezierPath()
            f.move(to: CGPoint(x: x, y: archBottom))
            f.addLine(to: CGPoint(x: x, y: archBottom + 12))
            f.lineWidth = 1
            f.stroke()
            x += 7
        }
        let cy = (top + bottom) / 2, k: CGFloat = 5.5, step: CGFloat = 26
        let count = Int((right - left) / step)
        let start = bounds.midX - CGFloat(count - 1) / 2 * step
        line.withAlphaComponent(0.3).setStroke()
        for n in 0..<count {
            let cx = start + CGFloat(n) * step
            for angle in [0, CGFloat.pi / 4] {
                let sq = UIBezierPath(rect: CGRect(x: -k, y: -k, width: k * 2, height: k * 2))
                sq.apply(CGAffineTransform(rotationAngle: angle))
                sq.apply(CGAffineTransform(translationX: cx, y: cy))
                sq.lineWidth = 1
                sq.stroke()
            }
        }
    }
}

/// The brass compass: the ring turns so that its N points north; the needle points at the qibla bearing
/// with the Kaaba at its tip. The fixed red line at the top shows where the phone points.
final class BrassDialView: UIView {
    var heading: Double = 0 { didSet { setNeedsDisplay() } }
    var qibla: Double = -1 { didSet { setNeedsDisplay() } }
    var aligned = false { didSet { setNeedsDisplay() } }
    var sun: Double = -1 { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let space = CGColorSpaceCreateDeviceRGB()
    private static func gradient(_ hexes: [String], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: hexes.map { UIColor(hex: $0).cgColor } as CFArray, locations: locations)!
    }
    private static let brass = gradient(["#F3D99A", "#C4964A", "#7A5622"], [0, 0.45, 1])
    private static let face = gradient(["#2A2620", "#191712"], [0, 1])

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let s = min(bounds.width, bounds.height) / 2 / 164
        let rim = UIColor(hex: "#5E4219"), gold = UIColor(hex: "#E9C77A")
        func disc(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

        if aligned {
            let glow = UIBezierPath(ovalIn: disc(161 * s))
            glow.lineWidth = 5 * s
            Qibla.teal.setStroke()
            glow.stroke()
        }
        let R = 158 * s
        ctx.saveGState()
        ctx.addEllipse(in: disc(R))
        ctx.clip()
        let hl = CGPoint(x: c.x - 0.2 * R, y: c.y - 0.3 * R)
        ctx.drawRadialGradient(Self.brass, startCenter: hl, startRadius: 0, endCenter: hl, endRadius: 1.5 * R, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        let line = UIBezierPath(ovalIn: disc(150 * s))
        line.lineWidth = 1
        rim.setStroke()
        line.stroke()
        let Rf = 130 * s
        ctx.saveGState()
        ctx.addEllipse(in: disc(Rf))
        ctx.clip()
        let fc = CGPoint(x: c.x, y: c.y - 0.1 * Rf)
        ctx.drawRadialGradient(Self.face, startCenter: fc, startRadius: 0, endCenter: fc, endRadius: 1.2 * Rf, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        let faceRim = UIBezierPath(ovalIn: disc(Rf))
        faceRim.lineWidth = 2 * s
        rim.setStroke()
        faceRim.stroke()

        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(-heading * .pi / 180))
        // Engraved ticks every 5°, deeper every 30°.
        for deg in stride(from: 0, to: 360, by: 5) {
            let a = CGFloat(deg) * .pi / 180
            let major = deg % 30 == 0
            let r1 = (major ? 132 : 135) * s, r2 = (major ? 148 : 145) * s
            let p = UIBezierPath()
            p.move(to: CGPoint(x: sin(a) * r1, y: -cos(a) * r1))
            p.addLine(to: CGPoint(x: sin(a) * r2, y: -cos(a) * r2))
            p.lineWidth = (major ? 2.5 : 1) * s
            UIColor(hex: major ? "#2A1D08" : "#3B2A10").setStroke()
            p.stroke()
        }
        // Degree numbers, with the compass letters at the four points.
        let letters = Qibla.nesw
        for deg in stride(from: 0, to: 360, by: 30) {
            let a = CGFloat(deg) * .pi / 180
            let cardinal = deg % 90 == 0
            let label = cardinal ? letters[deg / 90] : "\(deg)"
            let font = cardinal ? Fonts.serif(17 * s, bold: deg == 0) : Fonts.serif(14 * s)
            ctx.saveGState()
            ctx.translateBy(x: sin(a) * 112 * s, y: -cos(a) * 112 * s)
            ctx.rotate(by: a)
            Canvas.text(ctx, label, centerX: 0, baseline: font.pointSize * 0.36, font: font,
                        color: deg == 0 ? UIColor(hex: "#E86A50") : UIColor(hex: "#D9B46A"))
            ctx.restoreGState()
        }
        if sun >= 0 {
            let a = CGFloat(sun * .pi / 180)
            Qibla.drawSun(at: CGPoint(x: sin(a) * 62 * s, y: -cos(a) * 62 * s), radius: 7 * s)
        }
        // The needle points at the qibla, the Kaaba at its tip.
        if qibla >= 0 {
            ctx.saveGState()
            ctx.rotate(by: CGFloat(qibla * .pi / 180))
            let head = UIBezierPath()
            head.move(to: CGPoint(x: 0, y: -78 * s))
            head.addLine(to: CGPoint(x: 9 * s, y: 0))
            head.addLine(to: CGPoint(x: -9 * s, y: 0))
            head.close()
            gold.setFill()
            head.fill()
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: -9 * s, y: 0))
            tail.addLine(to: CGPoint(x: 9 * s, y: 0))
            tail.addLine(to: CGPoint(x: 0, y: 72 * s))
            tail.close()
            UIColor(hex: "#4A3A20").setFill()
            tail.fill()
            ctx.translateBy(x: 0, y: -90 * s)
            ctx.rotate(by: CGFloat((heading - qibla) * .pi / 180)) // keep the cube upright on screen
            Qibla.drawKaaba(ctx, half: 12 * s, gold: gold)
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // Centre pin and the fixed line at the top (where the phone points).
        let hub = UIBezierPath(ovalIn: disc(11 * s))
        UIColor(hex: "#C4964A").setFill()
        hub.fill()
        hub.lineWidth = 1
        rim.setStroke()
        hub.stroke()
        let lubber = UIBezierPath()
        lubber.move(to: CGPoint(x: c.x, y: c.y - 162 * s))
        lubber.addLine(to: CGPoint(x: c.x, y: c.y - 132 * s))
        lubber.lineWidth = 3.5 * s
        lubber.lineCapStyle = .round
        (aligned ? Qibla.teal : UIColor(hex: "#E86A50")).setStroke()
        lubber.stroke()
    }
}

/// A globe centred between the place and Mecca, with the shortest route between them.
final class GlobeView: UIView {
    var place: CLLocationCoordinate2D? { didSet { setNeedsDisplay() } }
    var placeName = ""
    var meccaName = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    private typealias Vec = (x: Double, y: Double, z: Double)
    private static func vec(_ lat: Double, _ lon: Double) -> Vec {
        let φ = lat * .pi / 180, λ = lon * .pi / 180
        return (cos(φ) * cos(λ), cos(φ) * sin(λ), sin(φ))
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let R = min(bounds.width, bounds.height) / 2 - 2
        let gridColor = UIColor(hex: "#2D6A86"), gold = UIColor(hex: "#F0D78A")
        let ball = UIBezierPath(ovalIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        UIColor(hex: "#103E57").setFill()
        ball.fill()
        ball.lineWidth = 1.5
        gridColor.setStroke()
        ball.stroke()
        guard let p = place else { return }

        let a = Self.vec(p.latitude, p.longitude), b = Self.vec(Qibla.kaaba.latitude, Qibla.kaaba.longitude)
        var m: Vec = (x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
        let n = sqrt(m.x * m.x + m.y * m.y + m.z * m.z)
        if n < 1e-6 { m = a } else { m = (x: m.x / n, y: m.y / n, z: m.z / n) }
        let φ0 = asin(max(-1, min(1, m.z))), λ0 = atan2(m.y, m.x)
        // Orthographic projection onto the view; nil on the far side.
        func project(_ lat: Double, _ lon: Double) -> CGPoint? {
            let φ = lat * .pi / 180, dλ = lon * .pi / 180 - λ0
            let cosc = sin(φ0) * sin(φ) + cos(φ0) * cos(φ) * cos(dλ)
            guard cosc >= 0 else { return nil }
            let x = cos(φ) * sin(dλ)
            let y = cos(φ0) * sin(φ) - sin(φ0) * cos(φ) * cos(dλ)
            return CGPoint(x: c.x + CGFloat(x) * R, y: c.y - CGFloat(y) * R)
        }
        func polyline(_ points: [(Double, Double)]) -> UIBezierPath {
            let path = UIBezierPath()
            var pen = false
            for (lat, lon) in points {
                if let q = project(lat, lon) {
                    if pen { path.addLine(to: q) } else { path.move(to: q) }
                    pen = true
                } else {
                    pen = false
                }
            }
            return path
        }
        ctx.saveGState()
        ball.addClip()
        gridColor.setStroke()
        for lon in stride(from: -180.0, to: 180.0, by: 30.0) {
            let l = polyline(stride(from: -90.0, through: 90.0, by: 2.0).map { ($0, lon) })
            l.lineWidth = 1
            l.stroke()
        }
        for lat in stride(from: -60.0, through: 60.0, by: 30.0) {
            let l = polyline(stride(from: -180.0, through: 180.0, by: 2.0).map { (lat, $0) })
            l.lineWidth = 1
            l.stroke()
        }
        ctx.restoreGState()

        // The shortest route (great circle).
        let dot = max(-1, min(1, a.x * b.x + a.y * b.y + a.z * b.z))
        let ω = acos(dot)
        if ω > 1e-4 {
            let route = polyline(stride(from: 0.0, through: 1.0, by: 0.02).map { (t: Double) -> (Double, Double) in
                let k1 = sin((1 - t) * ω) / sin(ω), k2 = sin(t * ω) / sin(ω)
                let v: Vec = (x: k1 * a.x + k2 * b.x, y: k1 * a.y + k2 * b.y, z: k1 * a.z + k2 * b.z)
                return (asin(max(-1, min(1, v.z))) * 180 / .pi, atan2(v.y, v.x) * 180 / .pi)
            })
            route.lineWidth = 2.5
            route.lineCapStyle = .round
            route.setLineDash([6, 5], count: 2, phase: 0)
            gold.setStroke()
            route.stroke()
        }
        let font = Fonts.sans(14, bold: true)
        if let me = project(p.latitude, p.longitude) {
            Canvas.circle(me.x, me.y, 6, .white)
            let fitted = Canvas.fit(placeName, maxWidth: R * 1.1, size: 14) { Fonts.sans($0, bold: true) }
            Canvas.text(ctx, placeName, centerX: min(max(me.x, c.x - R * 0.6), c.x + R * 0.6), baseline: me.y - 14, font: fitted, color: .white)
        }
        if let k = project(Qibla.kaaba.latitude, Qibla.kaaba.longitude) {
            ctx.saveGState()
            ctx.translateBy(x: k.x, y: k.y)
            Qibla.drawKaaba(ctx, half: 11, gold: gold)
            ctx.restoreGState()
            Canvas.text(ctx, meccaName, centerX: min(max(k.x, c.x - R * 0.6), c.x + R * 0.6), baseline: k.y + 30, font: font, color: gold)
        }
    }
}

/// A sliding compass tape: the phone's heading at the fixed centre line, the Kaaba at the qibla bearing.
final class HeadingTapeView: UIView {
    var heading: Double = -1 { didSet { setNeedsDisplay() } }
    var qibla: Double = -1 { didSet { setNeedsDisplay() } }
    var sun: Double = -1 { didSet { setNeedsDisplay() } }
    var aligned = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height, cx = bounds.midX
        let bandTop = h * 0.28, bandBottom = h * 0.96
        let gold = UIColor(hex: "#F0D78A")
        let band = UIBezierPath(roundedRect: CGRect(x: 0, y: bandTop, width: w, height: bandBottom - bandTop), cornerRadius: 12)
        UIColor(hex: "#0F3A52").setFill()
        band.fill()
        // Without a heading (no compass and the sun down) the tape shows north to qibla, with no centre line.
        let centre = heading >= 0 ? heading : max(qibla, 0)
        let ppd = w / 68
        func x(_ d: Double) -> CGFloat { cx + CGFloat(Qibla.turn(from: centre, to: d)) * ppd }

        if heading >= 0, qibla >= 0, !aligned {
            let kx = min(max(x(qibla), 6), w - 6)
            let bar = UIBezierPath(roundedRect: CGRect(x: min(cx, kx), y: bandBottom - 10, width: abs(kx - cx), height: 5), cornerRadius: 2.5)
            UIColor(hex: "#E0832B").setFill()
            bar.fill()
        }
        let letters = Qibla.nesw
        let tickBottom = bandBottom - 16
        let first = Int(floor((centre - 36) / 5)) * 5
        for d in stride(from: first, through: Int(centre + 36), by: 5) {
            let deg = ((d % 360) + 360) % 360
            let px = x(Double(deg))
            guard px > 4, px < w - 4 else { continue }
            let len: CGFloat = deg % 90 == 0 ? 18 : (deg % 10 == 0 ? 12 : 7)
            let t = UIBezierPath()
            t.move(to: CGPoint(x: px, y: tickBottom - len))
            t.addLine(to: CGPoint(x: px, y: tickBottom))
            t.lineWidth = deg % 90 == 0 ? 2 : 1.5
            UIColor(white: 1, alpha: deg % 90 == 0 ? 1 : 0.55).setStroke()
            t.stroke()
            if deg % 10 == 0, deg % 90 != 0 {
                Canvas.text(ctx, "\(deg)", centerX: px, baseline: tickBottom - 20, font: Fonts.sans(12), color: UIColor(hex: "#CFE3EA"))
            } else if deg % 90 == 0 {
                Canvas.text(ctx, letters[deg / 90], centerX: px, baseline: tickBottom - 22, font: Fonts.sans(15, bold: true),
                            color: deg == 0 ? UIColor(hex: "#FF9C8A") : .white)
            }
        }
        if sun >= 0 {
            let sx = x(sun)
            if sx > 10, sx < w - 10 { Qibla.drawSun(at: CGPoint(x: sx, y: bandTop * 0.5), radius: 5) }
        }
        // The Kaaba above the tape at the qibla; at the nearer edge with an arrow when it is off the tape.
        if qibla >= 0 {
            let kx = x(qibla)
            let k = bandTop * 0.36
            ctx.saveGState()
            if kx < k + 2 || kx > w - k - 2 {
                let right = kx > cx
                let ex = right ? w - k - 14 : k + 14
                ctx.translateBy(x: ex, y: bandTop * 0.5)
                Qibla.drawKaaba(ctx, half: k, gold: gold)
                let arrow = UIBezierPath()
                let ax: CGFloat = right ? k + 4 : -k - 4, dir: CGFloat = right ? 1 : -1
                arrow.move(to: CGPoint(x: ax, y: -k * 0.7))
                arrow.addLine(to: CGPoint(x: ax + dir * k * 0.8, y: 0))
                arrow.addLine(to: CGPoint(x: ax, y: k * 0.7))
                arrow.close()
                gold.setFill()
                arrow.fill()
            } else {
                ctx.translateBy(x: kx, y: bandTop * 0.5)
                Qibla.drawKaaba(ctx, half: k, gold: gold)
            }
            ctx.restoreGState()
        }
        if heading >= 0 {
            let color = aligned ? Qibla.teal : UIColor.white
            let l = UIBezierPath()
            l.move(to: CGPoint(x: cx, y: bandTop))
            l.addLine(to: CGPoint(x: cx, y: bandBottom))
            l.lineWidth = aligned ? 3 : 2
            color.setStroke()
            l.stroke()
            let tri = UIBezierPath()
            tri.move(to: CGPoint(x: cx, y: bandTop + 9))
            tri.addLine(to: CGPoint(x: cx - 7, y: bandTop))
            tri.addLine(to: CGPoint(x: cx + 7, y: bandTop))
            tri.close()
            color.setFill()
            tri.fill()
        }
    }
}
