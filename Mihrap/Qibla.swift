import CoreLocation
import UIKit

/// Qibla finder (iPhone only; the Android app has none): a compass ring that turns with the phone,
/// a gold Kaaba mark at the qibla bearing, the bearing in degrees and the distance to the Kaaba.
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
}

final class QiblaViewController: UIViewController, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let dial = QiblaDialView()
    private let angleLabel = UILabel(), distanceLabel = UILabel(), placeLabel = UILabel(), hintLabel = UILabel()
    private var place: CLLocationCoordinate2D?
    private var usingGPS = false
    private var aligned = false
    private let haptic = UINotificationFeedbackGenerator()
    /// Without a compass the dial turns so the sun sits at the top: point the top edge at the sun.
    private var sunMode = false
    private var sunTimer: Timer?

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .mihrapNavy
        title = IOSText.s("qibla")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.upper(L10n.s("close")), style: .done, target: self, action: #selector(close))
        dial.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dial)
        angleLabel.font = Fonts.sans(30, bold: true)
        angleLabel.textColor = UIColor(hex: "#FFE6A0")
        distanceLabel.font = Fonts.sans(17)
        distanceLabel.textColor = .white
        placeLabel.font = Fonts.sans(14)
        placeLabel.textColor = UIColor(white: 1, alpha: 0.7)
        hintLabel.font = Fonts.sans(14)
        hintLabel.textColor = UIColor(hex: "#FF9C8A")
        hintLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [angleLabel, distanceLabel, placeLabel, hintLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for l in [angleLabel, distanceLabel, placeLabel, hintLabel] { l.textAlignment = .center }
        view.addSubview(stack)
        let g = view.safeAreaLayoutGuide
        let side = dial.widthAnchor.constraint(equalTo: g.widthAnchor, multiplier: 0.86)
        side.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dial.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            dial.topAnchor.constraint(equalTo: g.topAnchor, constant: 16),
            dial.heightAnchor.constraint(equalTo: dial.widthAnchor),
            side,
            dial.heightAnchor.constraint(lessThanOrEqualTo: g.heightAnchor, multiplier: 0.62),
            stack.topAnchor.constraint(equalTo: dial.bottomAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
        ])
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
    }

    private func updateSun() {
        guard sunMode else { return }
        guard let p = place else { hintLabel.text = IOSText.s("qibla_sun"); return }
        let s = Qibla.sun(at: p)
        if s.altitude > 0 {
            dial.sun = s.azimuth
            dial.heading = s.azimuth
            hintLabel.text = IOSText.s("qibla_sun")
        } else {
            dial.sun = -1
            dial.heading = 0
            hintLabel.text = IOSText.s("qibla_sun_down")
        }
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
        let bearing = Qibla.bearing(from: c)
        dial.qibla = bearing
        angleLabel.text = String(format: "%@ %.0f°", IOSText.s("qibla"), bearing)
        let km = Qibla.distanceKm(from: c)
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        nf.locale = Locale(identifier: Settings.shared.language)
        distanceLabel.text = String(format: IOSText.s("qibla_distance"), nf.string(from: NSNumber(value: km)) ?? "\(Int(km))")
        let s = Settings.shared
        placeLabel.text = gps ? IOSText.s("qibla_gps") : (s.districtName.isEmpty ? "" : s.districtName)
        updateSun()
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
        let heading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        dial.heading = heading
        if h.headingAccuracy < 0 || h.headingAccuracy > 20 {
            hintLabel.text = IOSText.s("qibla_calibrate")
        } else {
            hintLabel.text = IOSText.s("qibla_flat")
        }
        guard place != nil else { return }
        var diff = abs(dial.qibla - heading).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        let nowAligned = diff <= 3
        if nowAligned != aligned {
            aligned = nowAligned
            dial.aligned = nowAligned
            if nowAligned { haptic.notificationOccurred(.success) }
        }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
}

/// The compass: the ring turns so that its N points north; the Kaaba mark sits at the qibla bearing.
/// The fixed gold triangle at the top shows where the phone points.
final class QiblaDialView: UIView {
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

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = min(bounds.width, bounds.height) / 2 - 14
        let gold = UIColor(hex: "#F0D78A"), chip = UIColor(red: 22 / 255, green: 75 / 255, blue: 104 / 255, alpha: 0.95)
        // Face
        (aligned ? UIColor(red: 29 / 255, green: 102 / 255, blue: 128 / 255, alpha: 1) : chip).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        let rim = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        rim.lineWidth = 3
        (aligned ? UIColor(hex: "#FFD75A") : UIColor(hex: "#87C7D6")).setStroke()
        rim.stroke()

        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(-heading * .pi / 180))
        // Ticks every 5°, longer every 30°.
        for deg in stride(from: 0, to: 360, by: 5) {
            let a = CGFloat(deg) * .pi / 180
            let long = deg % 30 == 0
            let p = UIBezierPath()
            p.move(to: CGPoint(x: sin(a) * (r - (long ? 18 : 9)), y: -cos(a) * (r - (long ? 18 : 9))))
            p.addLine(to: CGPoint(x: sin(a) * (r - 3), y: -cos(a) * (r - 3)))
            p.lineWidth = long ? 2.5 : 1
            UIColor(white: 1, alpha: long ? 0.9 : 0.5).setStroke()
            p.stroke()
        }
        // N, E, S, W
        for (i, letter) in ["N", "E", "S", "W"].enumerated() {
            let a = CGFloat(i) * .pi / 2
            let font = Fonts.sans(r * 0.11, bold: true)
            let color = letter == "N" ? UIColor(hex: "#FF9C8A") : UIColor.white
            ctx.saveGState()
            ctx.translateBy(x: sin(a) * (r * 0.72), y: -cos(a) * (r * 0.72))
            ctx.rotate(by: a)
            Canvas.text(ctx, letter, centerX: 0, baseline: font.pointSize * 0.36, font: font, color: color)
            ctx.restoreGState()
        }
        // Kaaba mark at the qibla bearing, with a line from the centre.
        if qibla >= 0 {
            let a = CGFloat(qibla * .pi / 180)
            let line = UIBezierPath()
            line.move(to: .zero)
            line.addLine(to: CGPoint(x: sin(a) * r * 0.78, y: -cos(a) * r * 0.78))
            line.lineWidth = 4
            line.lineCapStyle = .round
            gold.setStroke()
            line.stroke()
            let k = r * 0.13
            let center = CGPoint(x: sin(a) * r * 0.86, y: -cos(a) * r * 0.86)
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: CGFloat(heading * .pi / 180)) // keep the cube upright on screen
            UIColor(hex: "#1A1A1A").setFill()
            UIBezierPath(roundedRect: CGRect(x: -k, y: -k, width: k * 2, height: k * 2), cornerRadius: k * 0.15).fill()
            gold.setFill()
            UIBezierPath(rect: CGRect(x: -k, y: -k * 0.45, width: k * 2, height: k * 0.28)).fill()
            ctx.restoreGState()
        }
        if sun >= 0 {
            let a = CGFloat(sun * .pi / 180)
            let sc = CGPoint(x: sin(a) * r * 0.55, y: -cos(a) * r * 0.55)
            let sr = r * 0.07
            UIColor(hex: "#FFD75A").setStroke()
            for i in 0..<8 {
                let b = CGFloat(i) * .pi / 4
                let ray = UIBezierPath()
                ray.move(to: CGPoint(x: sc.x + cos(b) * sr * 1.4, y: sc.y + sin(b) * sr * 1.4))
                ray.addLine(to: CGPoint(x: sc.x + cos(b) * sr * 2, y: sc.y + sin(b) * sr * 2))
                ray.lineWidth = 2
                ray.stroke()
            }
            Canvas.circle(sc.x, sc.y, sr, UIColor(hex: "#FFD75A"))
        }
        ctx.restoreGState()
        // Centre hub and the fixed pointer at the top (where the phone points).
        Canvas.circle(c.x, c.y, 7, gold)
        let tri = UIBezierPath()
        tri.move(to: CGPoint(x: c.x, y: c.y - r - 2))
        tri.addLine(to: CGPoint(x: c.x - 12, y: c.y - r - 16))
        tri.addLine(to: CGPoint(x: c.x + 12, y: c.y - r - 16))
        tri.close()
        (aligned ? UIColor(hex: "#FFD75A") : gold).setFill()
        tri.fill()
    }
}
