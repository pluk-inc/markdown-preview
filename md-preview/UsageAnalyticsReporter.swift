import Foundation

enum UsageAnalyticsReporter {
    static let eventName = "app became active"
    static let enabledDefaultsKey = "MarkdownPreview.shareAnonymousUsageAnalytics"
    static let installationIDDefaultsKey = "MarkdownPreview.analyticsInstallationID"
    static let lastCaptureDayDefaultsKey = "MarkdownPreview.analyticsLastCaptureDay"

    private static let captureURL = URL(string: "https://us.i.posthog.com/i/v0/e/")!

    static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    static var isEnabled: Bool {
        get { isEnabled(defaults: .standard) }
        set {
            setEnabled(newValue, defaults: .standard)
            if newValue {
                recordAppBecameActive()
            }
        }
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        guard let stored = defaults.object(forKey: enabledDefaultsKey) as? NSNumber else {
            return true
        }
        return stored.boolValue
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
    }

    static func installationID(defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: installationIDDefaultsKey),
           UUID(uuidString: stored) != nil {
            return stored
        }

        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: installationIDDefaultsKey)
        return generated
    }

    static func shouldCapture(on date: Date, defaults: UserDefaults) -> Bool {
        defaults.object(forKey: lastCaptureDayDefaultsKey) as? Int != utcDay(for: date)
    }

    static func markCaptureAttempt(on date: Date, defaults: UserDefaults) {
        defaults.set(utcDay(for: date), forKey: lastCaptureDayDefaultsKey)
    }

    private static func utcDay(for date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 86_400))
    }

    static func makeRequest(
        projectToken: String,
        installationID: String,
        appVersion: String,
        macOSMajorVersion: Int,
        architecture: String,
        localeRegion: String
    ) -> URLRequest? {
        let token = projectToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("phc_"), UUID(uuidString: installationID) != nil else {
            return nil
        }

        let payload: [String: Any] = [
            "api_key": token,
            "event": eventName,
            "distinct_id": installationID,
            "properties": [
                "$geoip_disable": true,
                "$process_person_profile": false,
                "app_version": appVersion,
                "macos_major_version": macOSMajorVersion,
                "architecture": architecture,
                "locale_region": localeRegion
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(url: captureURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func recordAppBecameActive(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
#if DEBUG
        return
#else
        guard isEnabled(defaults: defaults),
              shouldCapture(on: now, defaults: defaults),
              let token = bundle.object(forInfoDictionaryKey: "PostHogProjectToken") as? String,
              let request = makeRequest(
                  projectToken: token,
                  installationID: installationID(defaults: defaults),
                  appVersion: bundle.object(
                      forInfoDictionaryKey: "CFBundleShortVersionString"
                  ) as? String ?? "unknown",
                  macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                  architecture: currentArchitecture,
                  localeRegion: Locale.current.region?.identifier ?? "unknown"
              ) else {
            return
        }

        // One attempt per UTC day is sufficient for DAU and MAU, and avoids
        // sending another request every time the app is reactivated.
        markCaptureAttempt(on: now, defaults: defaults)
        session.dataTask(with: request).resume()
#endif
    }
}
