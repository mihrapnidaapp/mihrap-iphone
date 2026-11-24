import UIKit
import UserNotifications

/// MainActivity: the home screen with the clock, the adhan at prayer time and the action buttons.
final class HomeViewController: UIViewController, UIGestureRecognizerDelegate {
    private let photo = UIImageView()
    private let home = HomeView()
    private let actionRow = UIStackView()
    private let menuToggle = UIButton(type: .system)
    private var adhanButton: ActionButton!
    private var settingsButton: ActionButton!
    private var qiblaButton: ActionButton!
    private var timer: Timer?
    private var lastPhoto = -1
    private var played = Set<String>()

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .mihrapNavy
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.frame = view.bounds
        photo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(photo)
        home.frame = view.bounds
        home.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(home)

        adhanButton = ActionButton(symbol: "speaker.wave.2.fill") { [weak self] in self?.toggleAdhan() }
        settingsButton = ActionButton(symbol: "gearshape.fill") { [weak self] in self?.openSettings() }
        qiblaButton = ActionButton(symbol: "location.north.circle.fill") { [weak self] in self?.openQibla() }
        actionRow.axis = .horizontal
        actionRow.spacing = 12
        actionRow.isHidden = true
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        for b in [adhanButton!, qiblaButton!, settingsButton!] { actionRow.addArrangedSubview(b) }
        view.addSubview(actionRow)
        menuToggle.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        menuToggle.tintColor = UIColor(hex: "#F0D78A")
        menuToggle.backgroundColor = UIColor(red: 22 / 255, green: 75 / 255, blue: 104 / 255, alpha: 0.75)
        menuToggle.layer.cornerRadius = 22
        menuToggle.translatesAutoresizingMaskIntoConstraints = false
        menuToggle.addTarget(self, action: #selector(toggleMenu), for: .touchUpInside)
        view.addSubview(menuToggle)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            menuToggle.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            menuToggle.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
            menuToggle.widthAnchor.constraint(equalToConstant: 44),
            menuToggle.heightAnchor.constraint(equalToConstant: 44),
            actionRow.leadingAnchor.constraint(equalTo: menuToggle.trailingAnchor, constant: 12),
            actionRow.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: PrayerTimes.updated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        applyLanguage()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
        if Settings.shared.districtId.isEmpty && presentedViewController == nil {
            openSettings()
        }
    }

    @objc private func becameActive() {
        if PrayerTimes.shared.needsFetch() { PrayerTimes.shared.fetch() }
        Media.shared.sync()
        SaverAssets.shared.sync()
        Notifications.reschedule()
        IdleWindow.lastActivity = Date()
        tick()
    }

    @objc private func settingsChanged() {
        applyLanguage()
        PrayerTimes.shared.districtChanged()
        if PrayerTimes.shared.needsFetch(ignoreWait: true) { PrayerTimes.shared.fetch() }
        Media.shared.sync()
        Notifications.reschedule()
        refresh()
    }

    private func applyLanguage() {
        let rtl = L10n.rtl.contains(Settings.shared.language)
        UIView.appearance().semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        adhanButton.label = L10n.s("ezan_oku")
        settingsButton.label = L10n.s("settings")
        qiblaButton.label = IOSText.s("qibla")
    }

    @objc private func refresh() {
        Notifications.reschedule()
        tick()
    }

    private func tick() {
        let now = Date()
        let preset = Settings.shared.theme % 3
        if preset != lastPhoto {
            lastPhoto = preset
            if let url = Bundle.main.url(forResource: "photo\(preset)", withExtension: "jpg", subdirectory: "home") {
                photo.image = UIImage(contentsOfFile: url.path)
            }
            home.clockStyle = preset == 2 ? 2 : 1
        }
        let s = HomeState(now)
        home.state = s
        let pt = PrayerTimes.shared
        if Settings.shared.districtId.isEmpty { home.message = L10n.s("location_required") }
        else if s.row == nil && pt.fetching { home.message = L10n.s("loading") }
        else if s.row == nil && pt.failed { home.message = L10n.s("times_fetch_failed") }
        else { home.message = nil }
        checkAdhan(now, s.row)
        maybeStartSaver()
    }

    /// MainActivity: after the idle time on the home screen the screensaver starts.
    private func maybeStartSaver() {
        let idle = Settings.shared.idleSeconds
        guard idle > 0, presentedViewController == nil, !AdhanPlayer.shared.isPlaying,
              UIApplication.shared.applicationState == .active,
              Date().timeIntervalSince(IdleWindow.lastActivity) > TimeInterval(idle),
              !SaverAssets.shared.availableIds().isEmpty else { return }
        present(SaverViewController(), animated: true)
    }

    // checkPrayerAdhan: from 2 s before to 5 s after the minute, once per prayer and day; never at sunrise.
    private func checkAdhan(_ now: Date, _ row: DayRow?) {
        guard Settings.shared.azan != "off", let row = row, !AdhanPlayer.shared.isPlaying,
              UIApplication.shared.applicationState == .active else { return }
        let today = PrayerTimes.key(now)
        for key in PrayerTimes.keys where key != "Gunes" {
            let mark = today + "|" + key
            if played.contains(mark) { continue }
            guard let when = PrayerTimes.shared.at(row, key, now) else { continue }
            let diff = when.timeIntervalSince(now)
            if diff > 2 || diff < -5 { continue }
            played = played.filter { $0.hasPrefix(today) }
            played.insert(mark)
            startAdhan(key)
            return
        }
    }

    private func startAdhan(_ key: String) {
        guard AdhanPlayer.shared.play(key) else { return }
        dismissPresentedForAdhan {
            self.present(AdhanViewController(key: key), animated: true)
        }
    }

    private func dismissPresentedForAdhan(_ then: @escaping () -> Void) {
        if let p = presentedViewController { p.dismiss(animated: false, completion: then) } else { then() }
    }

    private func toggleAdhan() {
        if AdhanPlayer.shared.isPlaying { AdhanPlayer.shared.stop(); return }
        var key = PrayerTimes.shared.next(after: Date())?.key ?? "Imsak"
        if key == "Gunes" { key = "Imsak" }
        if !AdhanPlayer.shared.play(key) {
            toast(L10n.s("loading"))
            Media.shared.sync()
            return
        }
        present(AdhanViewController(key: key), animated: true)
    }

    @objc private func toggleMenu() {
        actionRow.isHidden.toggle()
        menuToggle.setImage(UIImage(systemName: actionRow.isHidden ? "chevron.right" : "chevron.left"), for: .normal)
    }

    // Touches on the buttons belong to the buttons, not to the clock tap.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v = touch.view
        while let current = v, current !== view {
            if current is UIControl { return false }
            v = current.superview
        }
        return true
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        // MainActivity: a tap on the clock opens the prayer schedule.
        if home.clockRect.insetBy(dx: -12, dy: -12).contains(g.location(in: home)) {
            present(UINavigationController(rootViewController: TimesListViewController()), animated: true)
        }
    }

    private func openQibla() {
        let nav = UINavigationController(rootViewController: QiblaViewController())
        nav.modalPresentationStyle = .fullScreen
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(hex: "#F0D78A")
        present(nav, animated: true)
    }

    private func openSettings() {
        let nav = UINavigationController(rootViewController: SettingsViewController())
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func toast(_ text: String) {
        let l = PaddedLabel()
        l.text = text
        l.font = Fonts.sans(15)
        l.textColor = .white
        l.backgroundColor = UIColor(white: 0.15, alpha: 0.9)
        l.layer.cornerRadius = 16
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -70),
        ])
        UIView.animate(withDuration: 0.3, delay: 2.5, options: []) { l.alpha = 0 } completion: { _ in l.removeFromSuperview() }
    }
}

/// btn_action_bg: the blue shield-shaped home button with an icon above its label.
final class ActionButton: UIControl {
    private let icon = UIImageView()
    private let text = UILabel()
    private let action: () -> Void
    var label: String { get { text.text ?? "" } set { text.text = L10n.upper(newValue) } }

    init(symbol: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 22 / 255, green: 75 / 255, blue: 104 / 255, alpha: 0.867)
        layer.cornerRadius = 14
        layer.borderWidth = 2
        layer.borderColor = UIColor(hex: "#87C7D6").cgColor
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        text.font = Fonts.sans(10, bold: true)
        text.textColor = .white
        text.textAlignment = .center
        text.adjustsFontSizeToFitWidth = true
        text.minimumScaleFactor = 0.6
        for v in [icon, text] { v.translatesAutoresizingMaskIntoConstraints = false; v.isUserInteractionEnabled = false; addSubview(v) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 76), heightAnchor.constraint(equalToConstant: 72),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 12), icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            text.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.7 : 1 } }
    @objc private func fire() { action() }
}

final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 16, dy: 8)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 32, height: s.height + 16)
    }
}

/// Silent notifications at each prayer time (not Güneş) for the next days, while the app is closed.
enum Notifications {
    private static let prefix = "prayer-"
    private static var lastPlan = ""

    static func reschedule() {
        let s = Settings.shared
        var items = [(Date, String, String)]()
        if s.notifications && s.azan != "off" {
            let now = Date()
            let place = s.districtName.isEmpty ? s.cityName : s.districtName
            for d in 0..<14 where items.count < 60 {
                let day = PrayerTimes.dayStart(now, plus: d)
                guard let row = PrayerTimes.shared.row(for: day) else { continue }
                for key in PrayerTimes.keys where key != "Gunes" {
                    guard let when = PrayerTimes.shared.at(row, key, day), when > now else { continue }
                    let c = Calendar.current.dateComponents([.hour, .minute], from: when)
                    items.append((when, prayerName(key, day), "\(pad(c.hour!)):\(pad(c.minute!))" + (place.isEmpty ? "" : " · " + place)))
                }
            }
        }
        let plan = items.map { "\($0.0.timeIntervalSince1970)\($0.1)\($0.2)" }.joined()
        if plan == lastPlan { return }
        lastPlan = plan
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined && !items.isEmpty {
                center.requestAuthorization(options: [.alert, .badge]) { granted, _ in if granted { replace(items, center) } }
            } else if settings.authorizationStatus != .denied {
                replace(items, center)
            }
        }
    }

    private static func replace(_ items: [(Date, String, String)], _ center: UNUserNotificationCenter) {
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map { $0.identifier }.filter { $0.hasPrefix(prefix) })
            for (when, title, body) in items.prefix(60) {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = nil // the user asked for a silent notification
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
                center.add(UNNotificationRequest(identifier: prefix + String(Int(when.timeIntervalSince1970)), content: content,
                                                 trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            }
        }
    }
}
