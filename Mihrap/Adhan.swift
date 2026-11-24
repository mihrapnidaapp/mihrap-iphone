import AVFoundation
import UIKit

/// AdhanHelper: plays the adhan for a prayer (rotating through the package's recordings),
/// then our dua after every adhan except Güneş when the setting is on.
final class AdhanPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AdhanPlayer()
    static let finished = Notification.Name("MihrapAdhanFinished")
    private var player: AVAudioPlayer?
    private var queue = [URL]()
    private(set) var key: String?
    var isPlaying: Bool { key != nil }

    /// Returns false when no recording is downloaded yet.
    @discardableResult
    func play(_ key: String) -> Bool {
        stop(notify: false)
        let tracks = Media.shared.tracks(key)
        guard !tracks.isEmpty else { return false }
        let d = UserDefaults.standard
        let rotationKey = "adhan_rotation_\(Settings.shared.azan)_\(key)"
        let index = d.integer(forKey: rotationKey) % tracks.count
        d.set(index + 1, forKey: rotationKey)
        queue = [tracks[index]]
        if Settings.shared.dua && key != "Gunes", let dua = Media.shared.dua { queue.append(dua) }
        self.key = key
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        return playNext()
    }

    private func playNext() -> Bool {
        while !queue.isEmpty {
            let url = queue.removeFirst()
            if let p = try? AVAudioPlayer(contentsOf: url) {
                p.delegate = self
                player = p
                if p.play() { return true }
            }
        }
        finish()
        return false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        _ = playNext()
    }

    func stop(notify: Bool = true) {
        queue = []
        player?.stop()
        player = nil
        if key != nil {
            key = nil
            if notify { NotificationCenter.default.post(name: AdhanPlayer.finished, object: nil) }
        }
    }

    private func finish() {
        player = nil
        key = nil
        NotificationCenter.default.post(name: AdhanPlayer.finished, object: nil)
    }
}

/// showAdhanMode: the mosque photos change every 8 seconds with their name and country;
/// a double tap or the stop button ends the adhan.
final class AdhanViewController: UIViewController {
    private let imageA = UIImageView(), imageB = UIImageView()
    private let caption = UILabel()
    private let titleLabel = UILabel()
    private let stopButton = UIButton(type: .system)
    private var visuals = [(url: URL, caption: String)]()
    private var index = 0
    private var timer: Timer?
    private let prayerKey: String

    init(key: String) {
        prayerKey = key
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
        for iv in [imageA, imageB] {
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.frame = view.bounds
            iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(iv)
        }
        imageB.alpha = 0
        let shade = GradientView()
        shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shade.frame = view.bounds
        view.addSubview(shade)

        titleLabel.font = Fonts.sans(28, bold: true)
        titleLabel.textColor = UIColor(hex: "#FFE6A0")
        titleLabel.textAlignment = .center
        titleLabel.text = prayerName(prayerKey, Date())
        caption.font = Fonts.sans(17)
        caption.textColor = .white
        caption.textAlignment = .center
        caption.numberOfLines = 2
        caption.adjustsFontSizeToFitWidth = true
        for l in [titleLabel, caption] {
            l.layer.shadowColor = UIColor.black.cgColor
            l.layer.shadowRadius = 4
            l.layer.shadowOpacity = 0.9
            l.layer.shadowOffset = CGSize(width: 0, height: 1)
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
        }
        stopButton.setTitle(L10n.s("media_browser_stop"), for: .normal)
        stopButton.titleLabel?.font = Fonts.sans(17, bold: true)
        stopButton.setTitleColor(.white, for: .normal)
        stopButton.backgroundColor = UIColor(red: 22 / 255, green: 75 / 255, blue: 104 / 255, alpha: 0.867)
        stopButton.layer.cornerRadius = 20
        stopButton.layer.borderWidth = 1.5
        stopButton.layer.borderColor = UIColor(hex: "#87C7D6").cgColor
        stopButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        view.addSubview(stopButton)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stopButton.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            stopButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            caption.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            caption.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -6),
            titleLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
        ])
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(stopTapped))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        visuals = Media.shared.adhanVisuals().shuffled()
        if visuals.isEmpty, let home = Bundle.main.url(forResource: "photo0", withExtension: "jpg", subdirectory: "home") {
            visuals = [(home, "")]
        }
        show(0, animated: false)
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.show(self.index + 1, animated: true)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(finished), name: AdhanPlayer.finished, object: nil)
    }

    private func show(_ i: Int, animated: Bool) {
        guard !visuals.isEmpty else { return }
        index = i % visuals.count
        let item = visuals[index]
        let image = UIImage(contentsOfFile: item.url.path)
        let (front, back) = imageA.alpha > 0.5 ? (imageA, imageB) : (imageB, imageA)
        back.image = image
        caption.text = item.caption
        if animated {
            UIView.animate(withDuration: 1.2) { back.alpha = 1; front.alpha = 0 }
        } else {
            back.alpha = 1; front.alpha = 0
        }
    }

    @objc private func stopTapped() { AdhanPlayer.shared.stop() }

    @objc private func finished() {
        timer?.invalidate()
        dismiss(animated: true)
    }
}

/// Dark fade at the bottom so the caption stays readable on bright photos.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let g = layer as! CAGradientLayer
        g.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor(white: 0, alpha: 0.65).cgColor]
        g.locations = [0, 0.6, 1]
    }
    required init?(coder: NSCoder) { fatalError() }
}
