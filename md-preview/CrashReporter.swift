import Foundation
import Sentry

enum CrashReporter {
    static func start(bundle: Bundle = .main) {
        guard let dsn = bundle.object(forInfoDictionaryKey: "SentryDSN") as? String,
              !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.enableAutoSessionTracking = false
            options.tracesSampleRate = 0
            options.profilesSampleRate = 0
            options.enableAppHangTracking = false
            options.enableNetworkTracking = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.enableSwizzling = false
            options.environment = "production"

            options.beforeSend = { event in
                // Markdown documents and their paths may be sensitive. Keep only
                // the native crash data needed to diagnose the failure.
                event.breadcrumbs = nil
                event.request = nil
                event.user = nil
                return event
            }
        }
    }
}
