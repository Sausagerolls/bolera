import Foundation
import Network

/// The user's streaming quality choices: one for Wi-Fi/wired networks and one
/// for mobile data (cellular, Personal Hotspot, Low Data Mode).
///
/// Values are kbps; `original` (0) means "stream the source file untouched"
/// (lossless when the library is lossless). Downloads never use these.
public enum StreamQuality {
    public static let wifiKey = "bolera.quality.wifi"
    public static let mobileKey = "bolera.quality.mobile"
    /// Pre-1.4.6 single setting. It only ever applied on mobile data, so it
    /// seeds the new mobile setting.
    static let legacyKey = "bolera.maxBitrate"

    public static let original = 0

    /// Posted when the user changes either setting, so tracks already warmed
    /// at the old quality are reopened.
    public static let didChange = Notification.Name("bolera.streamQualityDidChange")

    /// Picker options, highest first.
    public static let options: [(kbps: Int, name: String)] = [
        (original, "Original (Lossless)"),
        (320, "320 kbps"),
        (256, "256 kbps"),
        (192, "192 kbps"),
        (128, "128 kbps"),
        (96, "96 kbps"),
    ]

    /// Wi-Fi default is the original file, matching earlier releases, which
    /// always direct-played on Wi-Fi.
    public static var wifi: Int {
        UserDefaults.standard.object(forKey: wifiKey) as? Int ?? original
    }

    /// Mobile default: the old setting capped at 320, else 256.
    public static var mobile: Int {
        if let v = UserDefaults.standard.object(forKey: mobileKey) as? Int { return v }
        if let old = UserDefaults.standard.object(forKey: legacyKey) as? Int { return min(old, 320) }
        return 256
    }

    /// Saves the seeded mobile value once (so it no longer depends on the
    /// legacy key) and registers the Wi-Fi default, so `@AppStorage` pickers
    /// show the values the stream builder uses. Call once at launch.
    public static func prepare() {
        let d = UserDefaults.standard
        if d.object(forKey: mobileKey) == nil { d.set(mobile, forKey: mobileKey) }
        d.register(defaults: [wifiKey: original])
        NetworkCost.start()
    }

    /// The setting for the current network.
    public static var current: Int { NetworkCost.isMetered ? mobile : wifi }
}

/// Whether the app is on mobile data right now.
///
/// `NWPath.isExpensive` alone was not reliable: with a VPN up (Tailscale is how
/// most people reach a home Jellyfin server away from home) the default path
/// is the tunnel interface, which can report not-expensive while the traffic
/// actually rides cellular. So on iOS we also watch Wi-Fi and wired paths
/// directly: when the device has a working path but neither Wi-Fi nor wired
/// is up, the traffic is going over cellular.
public final class NetworkCost: @unchecked Sendable {
    public static let shared = NetworkCost()
    /// Posted on the main queue when `isMetered` flips.
    public static let didChange = Notification.Name("bolera.networkCostDidChange")

    /// Read synchronously when building stream URLs.
    public static var isMetered: Bool { shared.lock.withLock { shared.metered } }

    private let lock = NSLock()
    private var metered = false
    private var any: NWPath?
    private var wifi: NWPath?
    private var wired: NWPath?
    private let queue = DispatchQueue(label: "com.bolera.networkcost")
    private let anyMonitor = NWPathMonitor()
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wiredMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)

    private init() {
        anyMonitor.pathUpdateHandler = { [weak self] p in self?.update { $0.any = p } }
        wifiMonitor.pathUpdateHandler = { [weak self] p in self?.update { $0.wifi = p } }
        wiredMonitor.pathUpdateHandler = { [weak self] p in self?.update { $0.wired = p } }
        anyMonitor.start(queue: queue)
        wifiMonitor.start(queue: queue)
        wiredMonitor.start(queue: queue)
    }

    /// Starts the monitors. Safe to call more than once.
    public static func start() { _ = shared }

    private func update(_ change: (NetworkCost) -> Void) {
        change(self)
        let now = Self.evaluate(any: any, wifi: wifi, wired: wired)
        let changed: Bool = lock.withLock {
            defer { metered = now }
            return metered != now
        }
        guard changed else { return }
        DebugLog.write("[NetworkCost] metered=\(now) expensive=\(any?.isExpensive ?? false) constrained=\(any?.isConstrained ?? false) wifi=\(wifi?.status == .satisfied) wired=\(wired?.status == .satisfied) ifaces=\(any?.availableInterfaces.map { $0.type } ?? [])")
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    private static func evaluate(any: NWPath?, wifi: NWPath?, wired: NWPath?) -> Bool {
        guard let any, any.status == .satisfied else { return false }
        if any.isExpensive || any.isConstrained { return true }
        let wifiUp = wifi?.status == .satisfied
        let wiredUp = wired?.status == .satisfied
        // Personal Hotspot from another phone arrives as an expensive Wi-Fi path.
        if wifiUp, wifi?.isExpensive == true { return true }
        #if os(iOS)
        if any.usesInterfaceType(.cellular) { return true }
        // Online, but no Wi-Fi and no wired link: the traffic is on cellular
        // (typically under a VPN tunnel that hides the real interface). Wait
        // for the Wi-Fi monitor's first answer before deciding.
        if wifi != nil, !wifiUp, !wiredUp { return true }
        #endif
        return false
    }
}
