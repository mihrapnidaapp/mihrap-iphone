import Foundation

/// One day of Diyanet times (PrayerApi / TimesCache row): "dd.MM.yyyy" and "HH:mm" strings.
struct DayRow: Codable {
    var date: String
    var times: [String: String]
    var hijriShort: String?
    var hijriLong: String?
}

/// PrayerApi + TimesCache + TimesSync: a rolling window of 90 days for the chosen district,
/// from ezanvakti.imsakiyem.com (range) with ezanvakti.emushaf.net as the fallback.
final class PrayerTimes {
    static let shared = PrayerTimes()
    static let keys = ["Imsak", "Gunes", "Ogle", "Ikindi", "Aksam", "Yatsi"]
    static let updated = Notification.Name("MihrapTimesUpdated")
    static let maxDays = 90

    private(set) var rows = [DayRow]()
    private(set) var district = ""
    private(set) var fetchedAt: Date?
    private(set) var fetching = false
    private(set) var failed = false
    private var lastAttempt: Date?
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("times.json")
    }()

    private struct Stored: Codable { var district: String; var fetchedAt: Date?; var rows: [DayRow] }

    private init() {
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            rows = s.rows; district = s.district; fetchedAt = s.fetchedAt
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Stored(district: district, fetchedAt: fetchedAt, rows: rows)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: dates

    static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .year], from: d)
        return "\(pad(c.day!)).\(pad(c.month!)).\(c.year!)"
    }
    static func iso(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .year], from: d)
        return "\(c.year!)-\(pad(c.month!))-\(pad(c.day!))"
    }
    static func dayStart(_ d: Date, plus days: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: d))!
    }
    private static func rowDate(_ r: DayRow) -> Date? {
        let p = r.date.split(separator: ".").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[2], month: p[1], day: p[0]))
    }

    func row(for day: Date) -> DayRow? {
        let k = PrayerTimes.key(day)
        return rows.first { $0.date == k }
    }

    /// The moment of a prayer on that day, or nil.
    func at(_ row: DayRow?, _ key: String, _ day: Date) -> Date? {
        guard let v = row?.times[key] else { return nil }
        let p = v.split(separator: ":").compactMap { Int($0) }
        guard p.count >= 2 else { return nil }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        c.hour = p[0]; c.minute = p[1]; c.second = 0
        return Calendar.current.date(from: c)
    }

    func next(after now: Date) -> (key: String, when: Date)? {
        for offset in 0..<2 {
            let day = PrayerTimes.dayStart(now, plus: offset)
            guard let r = row(for: day) else { continue }
            for k in PrayerTimes.keys {
                if let w = at(r, k, day), w > now { return (k, w) }
            }
        }
        return nil
    }

    /// The latest prayer whose time has begun; Güneş is a time marker, not an adhan.
    func activeKey(_ row: DayRow?, _ now: Date) -> String {
        guard let row = row else { return "" }
        var current = ""
        for k in PrayerTimes.keys where k != "Gunes" {
            if let w = at(row, k, now), w <= now { current = k }
        }
        return current.isEmpty ? "Yatsi" : current
    }

    var forwardDays: Int {
        let today = PrayerTimes.dayStart(Date())
        return rows.filter { (PrayerTimes.rowDate($0) ?? .distantPast) >= today }.count
    }

    func needsFetch(ignoreWait: Bool = false) -> Bool {
        let s = Settings.shared
        if s.districtId.isEmpty { return false }
        if district != s.districtId || rows.isEmpty { return true }
        if forwardDays >= PrayerTimes.maxDays { return false }
        guard let last = lastAttempt else { return true }
        return ignoreWait || Date().timeIntervalSince(last) > 6 * 3600
    }

    /// Clears the cache when the district changes (SettingsActivity: TimesCache.clear).
    func districtChanged() {
        if district != Settings.shared.districtId {
            rows = []; fetchedAt = nil; district = ""; save()
            NotificationCenter.default.post(name: PrayerTimes.updated, object: nil)
        }
    }

    func fetch(_ done: (() -> Void)? = nil) {
        let target = Settings.shared.districtId
        if target.isEmpty || fetching { done?(); return }
        fetching = true
        lastAttempt = Date()
        NotificationCenter.default.post(name: PrayerTimes.updated, object: nil)
        let start = Date(), end = PrayerTimes.dayStart(Date(), plus: PrayerTimes.maxDays - 1)
        let finish: ([DayRow]?) -> Void = { list in
            self.fetching = false
            if let list = list, !list.isEmpty {
                self.rows = PrayerTimes.merge(self.district == target ? self.rows : [], list)
                self.district = target; self.fetchedAt = Date(); self.failed = false
                self.save()
            } else {
                self.failed = true
            }
            NotificationCenter.default.post(name: PrayerTimes.updated, object: nil)
            done?()
        }
        let fallback = {
            Net.json("https://ezanvakti.emushaf.net/vakitler/\(target)") { json in
                finish(PrayerTimes.convertEmushaf(json as? [[String: Any]] ?? []))
            }
        }
        let url = "https://ezanvakti.imsakiyem.com/api/prayer-times/\(target)/range?startDate=\(PrayerTimes.iso(start))&endDate=\(PrayerTimes.iso(end))&limit=100"
        Net.json(url) { json in
            let list = PrayerTimes.convertRange((json as? [String: Any])?["data"] as? [[String: Any]] ?? [])
            if list.count >= 30 { finish(list) } else { fallback() }
        }
    }

    private static func convertRange(_ data: [[String: Any]]) -> [DayRow] {
        var out = [DayRow]()
        for s in data {
            guard let date = s["date"] as? String, let t = s["times"] as? [String: Any] else { continue }
            let p = String(date.prefix(10)).split(separator: "-")
            guard p.count == 3 else { continue }
            var times = [String: String]()
            for (k, src) in [("Imsak", "imsak"), ("Gunes", "gunes"), ("Ogle", "ogle"), ("Ikindi", "ikindi"), ("Aksam", "aksam"), ("Yatsi", "yatsi")] {
                times[k] = t[src] as? String ?? ""
            }
            var row = DayRow(date: "\(p[2]).\(p[1]).\(p[0])", times: times)
            if let hj = s["hijri_date"] as? [String: Any] {
                row.hijriLong = hj["full_date"] as? String
                if let d = hj["day"] as? Int, let m = hj["month"] as? Int, let y = hj["year"] as? Int, d > 0, m > 0 {
                    row.hijriShort = "\(d).\(m).\(y)"
                }
            }
            out.append(row)
        }
        return out
    }

    private static func convertEmushaf(_ data: [[String: Any]]) -> [DayRow] {
        data.compactMap { s in
            guard let date = s["MiladiTarihKisa"] as? String else { return nil }
            var times = [String: String]()
            for k in keys { times[k] = s[k] as? String ?? "" }
            return DayRow(date: date, times: times, hijriShort: s["HicriTarihKisa"] as? String, hijriLong: s["HicriTarihUzun"] as? String)
        }
    }

    private static func merge(_ existing: [DayRow], _ incoming: [DayRow]) -> [DayRow] {
        var byDate = [String: DayRow]()
        for r in existing { byDate[r.date] = r }
        for r in incoming { byDate[r.date] = r }
        let from = dayStart(Date(), plus: -1)
        return byDate.values.filter { (rowDate($0) ?? .distantPast) >= from }
            .sorted { (rowDate($0) ?? .distantPast) < (rowDate($1) ?? .distantPast) }
    }
}

// MARK: - Hijri dates, blessed days, kerahat and Ramadan lines (HijriDays + MainActivity.dateLine)

enum Hijri {
    static let months: [String: [String]] = [
        "tr": ["Muharrem", "Safer", "Rebiülevvel", "Rebiülâhir", "Cemâziyelevvel", "Cemâziyelâhir", "Recep", "Şâban", "Ramazan", "Şevval", "Zilkade", "Zilhicce"],
        "en": ["Muharram", "Safar", "Rabi al-Awwal", "Rabi al-Akhir", "Jumada al-Ula", "Jumada al-Akhirah", "Rajab", "Sha'ban", "Ramadan", "Shawwal", "Dhu al-Qadah", "Dhu al-Hijjah"],
        "de": ["Muharram", "Safar", "Rabi al-Awwal", "Rabi al-Achir", "Dschumada al-Ula", "Dschumada al-Achira", "Radschab", "Schaban", "Ramadan", "Schawwal", "Dhu l-Qa'da", "Dhu l-Hiddscha"],
        "ar": ["محرم", "صفر", "ربيع الأول", "ربيع الآخر", "جمادى الأولى", "جمادى الآخرة", "رجب", "شعبان", "رمضان", "شوال", "ذو القعدة", "ذو الحجة"],
        "fa": ["محرم", "صفر", "ربیع‌الاول", "ربیع‌الثانی", "جمادی‌الاول", "جمادی‌الثانی", "رجب", "شعبان", "رمضان", "شوال", "ذی‌القعده", "ذی‌الحجه"],
        "id": ["Muharram", "Safar", "Rabiul Awal", "Rabiul Akhir", "Jumadil Awal", "Jumadil Akhir", "Rajab", "Syakban", "Ramadan", "Syawal", "Zulkaidah", "Zulhijah"],
        "ms": ["Muharam", "Safar", "Rabiulawal", "Rabiulakhir", "Jamadilawal", "Jamadilakhir", "Rejab", "Syaaban", "Ramadan", "Syawal", "Zulkaedah", "Zulhijah"],
        "zh": ["穆哈兰姆月", "色法尔月", "赖比尔·敖外鲁月", "赖比尔·阿色尼月", "主马达·敖外鲁月", "主马达·阿色尼月", "赖哲卜月", "舍尔邦月", "莱麦丹月", "闪瓦鲁月", "都尔喀尔德月", "都尔黑哲月"],
        "ur": ["محرم", "صفر", "ربیع الاول", "ربیع الثانی", "جمادی الاول", "جمادی الثانی", "رجب", "شعبان", "رمضان", "شوال", "ذوالقعدہ", "ذوالحجہ"],
        "hi": ["मुहर्रम", "सफ़र", "रबीउल अव्वल", "रबीउस्सानी", "जुमादल ऊला", "जुमादस्सानी", "रजब", "शाबान", "रमज़ान", "शव्वाल", "ज़िलक़ादा", "ज़िलहिज्जा"],
    ]
    static let suffix = ["tr": "", "en": " AH", "de": " AH", "ar": " هـ", "fa": " ق", "id": " H", "ms": " H", "zh": "", "ur": " ھ", "hi": " हि."]
    static let monthKeys = ["muharrem", "safer", "rebiulevvel", "rebiulahir", "cemaziyelevvel", "cemaziyelahir", "recep", "saban", "ramazan", "sevval", "zilkade", "zilhicce"]
    // tr, en, de, ar, fa, id, ms, zh, ur, hi
    static let events: [String: [String]] = [
        "regaib": ["Bu gece Regaib Kandili", "Tonight is Laylat al-Raghaib", "Heute Nacht ist Regaib-Nacht", "الليلة ليلة الرغائب", "امشب لیلة الرغائب", "Malam ini Malam Raghaib", "Malam ini Malam Raghaib", "今夜是赖嘎伊布夜", "آج رات لیلۃ الرغائب ہے", "आज रात लैलतुर रग़ाइब है"],
        "arefe_ramazan": ["Ramazan Bayramı Arefesi", "Eve of Eid al-Fitr", "Vorabend des Ramadanfestes", "وقفة عيد الفطر", "روز پیش از عید فطر", "Sehari menjelang Idulfitri", "Sehari sebelum Aidilfitri", "开斋节前一天", "عید الفطر سے پہلے کا دن", "ईदुल फ़ित्र से पहले का दिन"],
        "new_year": ["Hicrî Yılbaşı", "Islamic New Year", "Islamisches Neujahr", "رأس السنة الهجرية", "آغاز سال نو هجری قمری", "Tahun Baru Islam", "Awal Muharam", "伊斯兰新年", "اسلامی نیا سال", "इस्लामी नव वर्ष"],
        "asure": ["Aşure Günü", "Day of Ashura", "Aschura-Tag", "يوم عاشوراء", "روز عاشورا", "Hari Asyura", "Hari Asyura", "阿舒拉日", "یوم عاشور", "आशूरा का दिन"],
        "mevlid": ["Bu gece Mevlid Kandili", "Tonight is Mawlid al-Nabi", "Heute Nacht ist Mevlid-Nacht", "الليلة ليلة المولد النبوي", "امشب شب میلاد پیامبر", "Malam ini Maulid Nabi", "Malam ini Maulidur Rasul", "今夜是圣纪之夜", "آج رات میلاد النبی کی رات ہے", "आज रात मीलादुन्नबी की रात है"],
        "three_months": ["Üç Aylar başladı", "The three holy months begin", "Die drei heiligen Monate beginnen", "بداية الأشهر الثلاثة", "آغاز ماه‌های سه‌گانه", "Awal tiga bulan mulia", "Permulaan tiga bulan mulia", "三个吉庆月开始", "تین مقدس مہینوں کا آغاز", "तीन पवित्र महीनों का आरंभ"],
        "mirac": ["Bu gece Miraç Kandili", "Tonight is Laylat al-Mi'raj", "Heute Nacht ist Miradsch-Nacht", "الليلة ليلة الإسراء والمعراج", "امشب شب معراج", "Malam ini Isra Mikraj", "Malam ini Israk dan Mikraj", "今夜是登霄夜", "آج رات شب معراج ہے", "आज रात शबे मेराज है"],
        "berat": ["Bu gece Berat Kandili", "Tonight is Laylat al-Bara'ah", "Heute Nacht ist Berat-Nacht", "الليلة ليلة البراءة", "امشب شب برات", "Malam ini Nisfu Syakban", "Malam ini Nisfu Syaaban", "今夜是拜拉特夜", "آج رات شب برات ہے", "आज रात शबे बरात है"],
        "kadir": ["Bu gece Kadir Gecesi", "Tonight is Laylat al-Qadr", "Heute Nacht ist Lailat al-Qadr", "الليلة ليلة القدر", "امشب شب قدر", "Malam ini Lailatul Qadar", "Malam ini Lailatulqadar", "今夜是盖德尔夜", "آج رات شب قدر ہے", "आज रात शबे क़द्र है"],
        "ramazan_bayram": ["Ramazan Bayramı", "Eid al-Fitr", "Ramadanfest", "عيد الفطر", "عید فطر", "Idulfitri", "Aidilfitri", "开斋节", "عید الفطر", "ईदुल फ़ित्र"],
        "arefe_kurban": ["Kurban Bayramı Arefesi", "Day of Arafah", "Tag von Arafat", "يوم عرفة", "روز عرفه", "Hari Arafah", "Hari Arafah", "阿拉法特日", "یوم عرفہ", "अरफ़ा का दिन"],
        "kurban_bayram": ["Kurban Bayramı", "Eid al-Adha", "Opferfest", "عيد الأضحى", "عید قربان", "Iduladha", "Aidiladha", "宰牲节", "عید الاضحی", "ईदुल अज़हा"],
    ]

    static func parts(_ row: DayRow?) -> (d: Int, m: Int, y: Int)? {
        guard let row = row else { return nil }
        let p = (row.hijriShort ?? "").split(separator: ".").compactMap { Int($0) }
        if p.count == 3, (1...12).contains(p[1]) { return (p[0], p[1], p[2]) }
        let words = (row.hijriLong ?? "").split(whereSeparator: { $0 == " " })
        guard words.count == 3 else { return nil }
        let month = String(words[1]).folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr"))
            .lowercased().replacingOccurrences(of: "ı", with: "i")
        guard let idx = monthKeys.firstIndex(of: month), let d = Int(words[0]), let y = Int(words[2]) else { return nil }
        return (d, idx + 1, y)
    }

    static func text(_ h: (d: Int, m: Int, y: Int)?) -> String {
        guard let h = h else { return "" }
        let lang = months[Settings.shared.language] != nil ? Settings.shared.language : "en"
        let month = months[lang]![h.m - 1]
        if lang == "zh" { return "伊历\(h.y)年\(month)\(h.d)日" }
        return "\(h.d) \(month) \(h.y)\(suffix[lang] ?? "")"
    }

    static func event(_ key: String) -> String {
        let i = L10n.languages.firstIndex(of: Settings.shared.language) ?? 1
        // events are listed tr, en, de, ar, fa, id, ms, zh, ur, hi — the same order as L10n.languages
        return events[key]![i]
    }

    static func dayOf(_ feast: String, _ day: Int) -> String {
        switch Settings.shared.language {
        case "tr": return "\(feast) (\(day). gün)"
        case "de": return "\(feast) (\(day). Tag)"
        case "ar": return "\(feast) (اليوم \(day))"
        case "fa": return "\(feast) (روز \(day))"
        case "ur": return "\(feast) (دن \(day))"
        case "id", "ms": return "\(feast) (hari ke-\(day))"
        case "zh": return "\(feast)（第\(day)天）"
        case "hi": return "\(feast) (दिन \(day))"
        default: return "\(feast) (day \(day))"
        }
    }

    static func eventFor(_ now: Date) -> String {
        let pt = PrayerTimes.shared
        guard let today = parts(pt.row(for: now)) else { return "" }
        let next = PrayerTimes.dayStart(now, plus: 1)
        let tomorrow = parts(pt.row(for: next))
        let d = today.d, m = today.m
        if let t = tomorrow, t.m == 7, t.d <= 7, Calendar.current.component(.weekday, from: next) == 6 { return event("regaib") }
        if let t = tomorrow, t.m == 10, t.d == 1 { return event("arefe_ramazan") }
        if m == 1 && d == 1 { return event("new_year") }
        if m == 1 && d == 10 { return event("asure") }
        if m == 3 && d == 11 { return event("mevlid") }
        if m == 7 && d == 1 { return event("three_months") }
        if m == 7 && d == 26 { return event("mirac") }
        if m == 8 && d == 14 { return event("berat") }
        if m == 9 && d == 26 { return event("kadir") }
        if m == 10 && (1...3).contains(d) { return dayOf(event("ramazan_bayram"), d) }
        if m == 12 && d == 9 { return event("arefe_kurban") }
        if m == 12 && (10...13).contains(d) { return dayOf(event("kurban_bayram"), d - 9) }
        return ""
    }

    static func remaining(_ target: Date, _ now: Date) -> String {
        let sec = max(0, Int(target.timeIntervalSince(now)))
        return "\(pad(sec / 3600)):\(pad((sec % 3600) / 60)):\(pad(sec % 60))"
    }

    static func ramadanLine(_ now: Date) -> String {
        let pt = PrayerTimes.shared
        let todayRow = pt.row(for: now)
        let nextDay = PrayerTimes.dayStart(now, plus: 1)
        let tomorrowRow = pt.row(for: nextDay)
        let today = parts(todayRow)
        let fastingToday = today?.m == 9
        let fastingTomorrow = parts(tomorrowRow)?.m == 9
        if !fastingToday && !fastingTomorrow { return "" }
        guard let imsak = pt.at(todayRow, "Imsak", now), let iftar = pt.at(todayRow, "Aksam", now) else { return "" }
        let head = fastingToday ? L10n.format("ramadan_day", today!.d) : L10n.s("ramadan_eve")
        if fastingToday && now < imsak { return head + "  ·  " + L10n.format("imsak_in", remaining(imsak, now)) }
        if fastingToday && now < iftar { return head + "  ·  " + L10n.format("iftar_in", remaining(iftar, now)) }
        if fastingTomorrow, let next = pt.at(tomorrowRow, "Imsak", nextDay) {
            return head + "  ·  " + L10n.format("imsak_in", remaining(next, now))
        }
        return fastingToday ? head : ""
    }

    static func kerahatLine(_ now: Date) -> String {
        let pt = PrayerTimes.shared
        let row = pt.row(for: now)
        guard let sunrise = pt.at(row, "Gunes", now), let dhuhr = pt.at(row, "Ogle", now), let sunset = pt.at(row, "Aksam", now) else { return "" }
        let k: TimeInterval = 45 * 60
        var end: Date?
        if now >= sunrise && now < sunrise.addingTimeInterval(k) { end = sunrise.addingTimeInterval(k) }
        else if now >= dhuhr.addingTimeInterval(-k) && now < dhuhr { end = dhuhr }
        else if now >= sunset.addingTimeInterval(-k) && now < sunset { end = sunset }
        guard let e = end else { return "" }
        let c = Calendar.current.dateComponents([.hour, .minute], from: e)
        return L10n.format("kerahat_until", "\(pad(c.hour!)):\(pad(c.minute!))")
    }
}

/// Friday's Dhuhr is the Friday prayer on the home screen.
func prayerName(_ key: String, _ day: Date) -> String {
    if key == "Ogle" && Calendar.current.component(.weekday, from: day) == 6 { return L10n.s("prayer_cuma") }
    return L10n.s("prayer_" + key)
}
