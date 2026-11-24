import UIKit

/// Texts the iPhone app needs that the Android strings do not have (tr, en, de, ar, fa, id, ms, zh, ur, hi).
enum IOSText {
    private static let table: [String: [String]] = [
        "off": ["Kapalı", "Off", "Aus", "إيقاف", "خاموش", "Mati", "Dimatikan", "关闭", "بند", "बंद"],
        "notifications": ["Vakit girince bildirim (sessiz)", "Notification at prayer time (silent)", "Benachrichtigung zur Gebetszeit (lautlos)",
                          "إشعار عند دخول الوقت (صامت)", "اعلان هنگام وقت نماز (بی‌صدا)", "Notifikasi saat waktu salat (senyap)",
                          "Pemberitahuan pada waktu solat (senyap)", "礼拜时间通知（静音）", "نماز کے وقت اطلاع (خاموش)", "नमाज़ के समय सूचना (मौन)"],
        "notifications_hint": ["Uygulama kapalıyken iPhone ezan çalamaz; vakit girince sessiz bir bildirim gelir. Uygulama açıkken ezan tam çalar.",
                               "iPhone cannot play the adhan while the app is closed; a silent notification appears at prayer time. With the app open the adhan plays in full.",
                               "Bei geschlossener App kann das iPhone keinen Adhan abspielen; zur Gebetszeit erscheint eine lautlose Benachrichtigung. Bei geöffneter App wird der Adhan vollständig abgespielt.",
                               "لا يستطيع iPhone تشغيل الأذان والتطبيق مغلق؛ يظهر إشعار صامت عند دخول الوقت. والتطبيق مفتوح يُشغَّل الأذان كاملًا.",
                               "وقتی برنامه بسته است iPhone نمی‌تواند اذان پخش کند؛ هنگام وقت نماز یک اعلان بی‌صدا نمایش داده می‌شود. با برنامهٔ باز، اذان کامل پخش می‌شود.",
                               "iPhone tidak dapat memutar azan saat aplikasi ditutup; notifikasi senyap muncul saat waktu salat. Saat aplikasi terbuka, azan diputar penuh.",
                               "iPhone tidak boleh memainkan azan semasa aplikasi ditutup; pemberitahuan senyap dipaparkan pada waktu solat. Semasa aplikasi dibuka, azan dimainkan sepenuhnya.",
                               "应用关闭时 iPhone 无法播放宣礼；礼拜时间会显示一条静音通知。应用打开时宣礼完整播放。",
                               "ایپ بند ہو تو iPhone اذان نہیں چلا سکتا؛ نماز کے وقت ایک خاموش اطلاع آتی ہے۔ ایپ کھلی ہو تو اذان پوری چلتی ہے۔",
                               "ऐप बंद होने पर iPhone अज़ान नहीं चला सकता; नमाज़ के समय एक मौन सूचना आती है। ऐप खुला हो तो अज़ान पूरी चलती है।"],
        "downloading": ["Ezan sesleri ve fotoğraflar indiriliyor…", "Downloading adhan recordings and photos…", "Adhan-Aufnahmen und Fotos werden geladen…",
                        "جارٍ تنزيل تسجيلات الأذان والصور…", "در حال دریافت صداهای اذان و عکس‌ها…", "Mengunduh rekaman azan dan foto…",
                        "Memuat turun rakaman azan dan foto…", "正在下载宣礼录音和照片…", "اذان کی ریکارڈنگز اور تصاویر ڈاؤن لوڈ ہو رہی ہیں…", "अज़ान रिकॉर्डिंग और फ़ोटो डाउनलोड हो रहे हैं…"],
    ]
    static func s(_ key: String) -> String {
        let i = L10n.languages.firstIndex(of: Settings.shared.language) ?? 1
        return table[key]?[i] ?? key
    }
}

/// SettingsActivity: location, adhan and display settings. Changes apply when the sheet closes.
final class SettingsViewController: UITableViewController {
    private enum Row { case country, city, district, times, azan, dua, notifications, language, theme }
    private var sections: [(title: String, footer: String?, rows: [Row])] = []

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Media.changed, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func reload() {
        title = L10n.s("settings")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.s("save"), style: .done, target: self, action: #selector(done))
        sections = [
            (L10n.s("settings_tab_location"), nil, [.country, .city, .district, .times]),
            (L10n.s("settings_tab_worship"), Media.shared.busy ? IOSText.s("downloading") : IOSText.s("notifications_hint"),
             [.azan, .dua, .notifications]),
            (L10n.s("settings_tab_display"), nil, [.language, .theme]),
        ]
        tableView.semanticContentAttribute = L10n.rtl.contains(Settings.shared.language) ? .forceRightToLeft : .forceLeftToRight
        tableView.reloadData()
    }

    @objc private func done() {
        Settings.shared.notifyChanged()
        dismiss(animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    private func azanName(_ code: String) -> String { code == "off" ? IOSText.s("off") : L10n.s("azan_" + code) }
    private static let themes = ["theme_medina", "theme_kaaba", "theme_green_dome"]

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let s = Settings.shared
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator
        switch sections[indexPath.section].rows[indexPath.row] {
        case .country: cell.textLabel?.text = L10n.s("country"); cell.detailTextLabel?.text = s.countryName
        case .city: cell.textLabel?.text = L10n.s("city"); cell.detailTextLabel?.text = s.cityName
        case .district: cell.textLabel?.text = L10n.s("district"); cell.detailTextLabel?.text = s.districtName
        case .times: cell.textLabel?.text = L10n.s("times_list")
        case .azan: cell.textLabel?.text = L10n.s("azan_type_section"); cell.detailTextLabel?.text = azanName(s.azan)
        case .dua, .notifications:
            let isDua = sections[indexPath.section].rows[indexPath.row] == .dua
            cell.textLabel?.text = isDua ? L10n.s("dua_after_adhan") : IOSText.s("notifications")
            cell.textLabel?.numberOfLines = 0
            let toggle = UISwitch()
            toggle.isOn = isDua ? s.dua : s.notifications
            toggle.addAction(UIAction { _ in
                if isDua { Settings.shared.dua = toggle.isOn } else { Settings.shared.notifications = toggle.isOn }
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .language: cell.textLabel?.text = L10n.s("language"); cell.detailTextLabel?.text = L10n.names[s.language]
        case .theme:
            cell.textLabel?.text = L10n.s("theme_section")
            cell.detailTextLabel?.text = L10n.s(SettingsViewController.themes[s.theme % 3])
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let s = Settings.shared
        switch sections[indexPath.section].rows[indexPath.row] {
        case .country:
            push(LocationPickerViewController(kind: .country))
        case .city:
            if !s.countryId.isEmpty { push(LocationPickerViewController(kind: .city)) }
        case .district:
            if !s.cityId.isEmpty { push(LocationPickerViewController(kind: .district)) }
        case .times:
            push(TimesListViewController())
        case .azan:
            let codes = ["turkey", "turkey2", "mecca", "egypt", "off"]
            push(ChoiceViewController(title: L10n.s("azan_type_section"), options: codes.map { azanName($0) },
                                      selected: codes.firstIndex(of: s.azan) ?? 0) { Settings.shared.azan = codes[$0] })
        case .language:
            push(ChoiceViewController(title: L10n.s("language"), options: L10n.languages.map { L10n.names[$0]! },
                                      selected: L10n.languages.firstIndex(of: s.language) ?? 1) { Settings.shared.language = L10n.languages[$0] })
        case .theme:
            push(ChoiceViewController(title: L10n.s("theme_section"), options: SettingsViewController.themes.map { L10n.s($0) },
                                      selected: s.theme % 3) { Settings.shared.theme = $0 })
        case .dua, .notifications:
            break
        }
    }

    private func push(_ vc: UIViewController) { navigationController?.pushViewController(vc, animated: true) }
}

/// A simple list with one checked choice.
final class ChoiceViewController: UITableViewController {
    private let options: [String]
    private var selected: Int
    private let onChoose: (Int) -> Void

    init(title: String, options: [String], selected: Int, onChoose: @escaping (Int) -> Void) {
        self.options = options
        self.selected = selected
        self.onChoose = onChoose
        super.init(style: .insetGrouped)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { options.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = options[indexPath.row]
        cell.accessoryType = indexPath.row == selected ? .checkmark : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selected = indexPath.row
        onChoose(indexPath.row)
        navigationController?.popViewController(animated: true)
    }
}

/// AddLocationDialog: country, city and district lists from ezanvakti.emushaf.net (Diyanet ids).
final class LocationPickerViewController: UITableViewController, UISearchResultsUpdating {
    enum Kind { case country, city, district }
    private let kind: Kind
    private var items = [(id: String, name: String)]()
    private var shown = [(id: String, name: String)]()
    private let search = UISearchController(searchResultsController: nil)

    init(kind: Kind) {
        self.kind = kind
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let s = Settings.shared
        let (url, idKey, trKey, enKey, titleKey): (String, String, String, String, String)
        switch kind {
        case .country: (url, idKey, trKey, enKey, titleKey) = ("https://ezanvakti.emushaf.net/ulkeler", "UlkeID", "UlkeAdi", "UlkeAdiEn", "country")
        case .city: (url, idKey, trKey, enKey, titleKey) = ("https://ezanvakti.emushaf.net/sehirler/\(s.cityParent)", "SehirID", "SehirAdi", "SehirAdiEn", "city")
        case .district: (url, idKey, trKey, enKey, titleKey) = ("https://ezanvakti.emushaf.net/ilceler/\(s.cityId)", "IlceID", "IlceAdi", "IlceAdiEn", "district")
        }
        title = L10n.s(titleKey)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        tableView.backgroundView = spinner
        let turkish = s.language == "tr"
        Net.json(url) { [weak self] json in
            guard let self = self else { return }
            let list = (json as? [[String: Any]]) ?? []
            self.items = list.compactMap { e in
                guard let id = e[idKey].map({ "\($0)" }) else { return nil }
                let tr = e[trKey] as? String ?? "", en = e[enKey] as? String ?? ""
                return (id, turkish || en.isEmpty ? LocationPickerViewController.title(tr) : LocationPickerViewController.title(en))
            }
            self.shown = self.items
            self.tableView.backgroundView = nil
            if self.items.isEmpty {
                let l = UILabel()
                l.text = L10n.s("times_fetch_failed")
                l.textAlignment = .center
                l.textColor = .secondaryLabel
                self.tableView.backgroundView = l
            }
            self.tableView.reloadData()
        }
    }

    /// The service sends upper-case names; show them in title case (Turkish rules for Turkish names).
    private static func title(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "tr")).capitalized(with: Locale(identifier: "tr"))
    }

    func updateSearchResults(for searchController: UISearchController) {
        let q = searchController.searchBar.text ?? ""
        shown = q.isEmpty ? items : items.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = shown[indexPath.row].name
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = shown[indexPath.row]
        let s = Settings.shared
        search.isActive = false
        switch kind {
        case .country:
            s.countryId = item.id; s.countryName = item.name
            s.cityId = ""; s.cityName = ""; s.districtId = ""; s.districtName = ""
            navigationController?.pushViewController(LocationPickerViewController(kind: .city), animated: true)
        case .city:
            s.cityId = item.id; s.cityName = item.name
            s.districtId = ""; s.districtName = ""
            navigationController?.pushViewController(LocationPickerViewController(kind: .district), animated: true)
        case .district:
            s.districtId = item.id; s.districtName = item.name
            if let settings = navigationController?.viewControllers.first { navigationController?.popToViewController(settings, animated: true) }
        }
    }
}

extension Settings {
    var cityParent: String { countryId }
}

/// TimesListActivity: the cached days as a table.
final class TimesListViewController: UITableViewController {
    private var rows = [DayRow]()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.s("times_list_title")
        if navigationController?.viewControllers.first === self {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.upper(L10n.s("close")), style: .done, target: self, action: #selector(close))
        }
        rows = PrayerTimes.shared.rows
        tableView.allowsSelection = false
        tableView.rowHeight = 44
    }

    @objc private func close() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let pt = PrayerTimes.shared
        var when = "-"
        if let f = pt.fetchedAt {
            let df = DateFormatter()
            df.dateFormat = "dd-MM-yyyy HH:mm"
            when = df.string(from: f)
        }
        return L10n.format("times_list_meta", Settings.shared.districtName, rows.count, PrayerTimes.maxDays, when)
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let wrap = UIView()
        let meta = UILabel()
        meta.text = self.tableView(tableView, titleForHeaderInSection: section)
        meta.font = Fonts.sans(13)
        meta.textColor = UIColor(hex: "#48645F")
        meta.numberOfLines = 0
        let header = TimesRow(header: true)
        header.set([L10n.s("times_date")] + PrayerTimes.keys.map { L10n.s("prayer_" + $0) })
        let stack = UIStackView(arrangedSubviews: [meta, header])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        wrap.backgroundColor = UIColor(hex: "#F7FAF9")
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])
        return wrap
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(rows.count, 1) }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if rows.isEmpty {
            cell.textLabel?.text = L10n.s("times_list_empty")
            cell.textLabel?.numberOfLines = 0
            return cell
        }
        let r = rows[indexPath.row]
        let line = TimesRow(header: false)
        line.set([r.date.replacingOccurrences(of: ".", with: "/")] + PrayerTimes.keys.map { r.times[$0] ?? "--:--" })
        line.backgroundColor = indexPath.row % 2 == 0 ? UIColor(red: 246 / 255, green: 249 / 255, blue: 248 / 255, alpha: 1)
            : UIColor(red: 225 / 255, green: 237 / 255, blue: 234 / 255, alpha: 1)
        line.frame = cell.contentView.bounds
        line.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cell.contentView.addSubview(line)
        return cell
    }
}

/// One table line: the date column is wider than the six time columns.
final class TimesRow: UIStackView {
    private let header: Bool
    init(header: Bool) {
        self.header = header
        super.init(frame: .zero)
        axis = .horizontal
        distribution = .fill
        if header { backgroundColor = UIColor(red: 32 / 255, green: 84 / 255, blue: 76 / 255, alpha: 1) }
    }
    required init(coder: NSCoder) { fatalError() }

    func set(_ texts: [String]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        var first: UILabel?
        for (i, t) in texts.enumerated() {
            let l = UILabel()
            l.text = t
            l.textAlignment = .center
            l.font = header ? Fonts.sans(12, bold: true) : Fonts.sans(13)
            l.textColor = header ? .white : UIColor(red: 28 / 255, green: 42 / 255, blue: 39 / 255, alpha: 1)
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.6
            addArrangedSubview(l)
            if i == 0 { first = l } else if let f = first {
                l.widthAnchor.constraint(equalTo: f.widthAnchor, multiplier: 0.72).isActive = true
            }
        }
    }
}
