import Foundation

/// One selectable carrier profile. `plistName` points at a bundled
/// `carrier.plist` payload; `bundleName` / `bundleIdentifier` are the identity
/// the Overlay copy is published under, which is what CommCenter matches on.
struct IPCCCarrier: Identifiable, Hashable, Sendable {
    let id: String              // "46000"
    let displayName: String     // "中国移动"
    let plistName: String       // "46000.plist"
    let bundleName: String      // "CMCC_cn.bundle"
    let bundleIdentifier: String
    let supportedSIMs: [String]

    var shortName: String { bundleName.replacingOccurrences(of: ".bundle", with: "") }
}

enum IPCCCarrierCatalog {
    /// The bundled template is a real Apple-signed IPCC payload. Only
    /// `carrier.plist` gets replaced; `signatures/` and every `*.der.pri`
    /// stay byte-identical, which is what keeps the signature valid.
    static let templateIPCC = "O2_Germany.ipcc"
    static let templateBundle = "O2_Germany.bundle"

    static let deviceRoot = "/var/mobile/Library/Carrier Bundles/iPhone"

    static let all: [IPCCCarrier] = [
        IPCCCarrier(id: "46000", displayName: "中国移动", plistName: "46000.plist",
                    bundleName: "CMCC_cn.bundle", bundleIdentifier: "com.apple.Carrier_CMCC_cn",
                    supportedSIMs: ["46000", "46002", "46007", "46008"]),
        IPCCCarrier(id: "46001", displayName: "中国联通", plistName: "46001.plist",
                    bundleName: "Unicom_cn.bundle", bundleIdentifier: "com.apple.Carrier_Unicom_cn",
                    supportedSIMs: ["46001", "46009"]),
        IPCCCarrier(id: "46011", displayName: "中国电信", plistName: "46011.plist",
                    bundleName: "ChinaTelecom_USIM_cn.bundle",
                    bundleIdentifier: "com.apple.Carrier_ChinaTelecom_USIM_cn",
                    supportedSIMs: ["46011"]),
        IPCCCarrier(id: "46015", displayName: "中国广电", plistName: "46015.plist",
                    bundleName: "CBN_cn.bundle", bundleIdentifier: "com.apple.Carrier_CBN_cn",
                    supportedSIMs: ["46015"]),
    ]

    /// Extra MCC/MNC payloads that ship in the bundle but collapse onto an
    /// existing bundle identity above.
    static let aliases: [String: String] = [
        "46002": "46000", "46007": "46000", "46008": "46000",
        "46003": "46011", "46005": "46011",
        "46006": "46001", "46009": "46001",
    ]

    static func carrier(for id: String) -> IPCCCarrier? {
        all.first { $0.id == id }
    }

    static func resourceURL(_ name: String, ext: String, subdirectory: String? = nil) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        if let sub = subdirectory,
           let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: sub) {
            return url
        }
        return nil
    }
}
