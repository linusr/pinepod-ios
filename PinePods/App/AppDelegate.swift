import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        AutomationEngine.registerBackgroundTask()
        WatchBridge.shared.activate()
        return true
    }

    /// iOS relaunches the app to deliver finished background downloads.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        MainActor.assumeIsolated {
            DownloadManager.shared.backgroundEventsCompletion = completionHandler
        }
    }
}
