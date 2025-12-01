import SwiftUI
import WebKit
import UserNotifications

struct UpdaterView: View {
    var body: some View {
        UpdaterWebView(url: URL(string: "https://prostore.free.nf/update.html")!)
            .edgesIgnoringSafeArea(.all)
    }
}

struct UpdaterWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.allowsInlineMediaPlayback = true
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Clear cache
        let dataTypes = Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeCookies])
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) {
            print("✅ WKWebView cache cleared!")
            let request = URLRequest(url: self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            webView.load(request)
        }

        // Setup notification delegate
        UNUserNotificationCenter.current().delegate = context.coordinator
        context.coordinator.requestNotificationPermission()

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            uiView.load(request)
        }
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, UNUserNotificationCenterDelegate {
        let parent: UpdaterWebView

        init(parent: UpdaterWebView) {
            self.parent = parent
            super.init()
        }

        // Request permission
        func requestNotificationPermission() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if granted {
                    print("🔔 Notifications allowed!")
                } else if let error = error {
                    print("❌ Notification error: \(error)")
                }
            }
        }

        // Send local notification
        private func sendUpdateNotification() {
            let content = UNMutableNotificationContent()
            content.title = "ProStore"
            content.body = "ProStore will now update! Please click 'Install'."
            content.sound = .default

            let request = UNNotificationRequest(identifier: "ProStoreUpdate", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("❌ Failed to schedule notification: \(error)")
                } else {
                    print("✅ Notification scheduled!")
                }
            }
        }

        // Show notification even if app is foreground
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler:
                                        @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }

        // MARK: Navigation Delegate
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let reqURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = reqURL.scheme?.lowercased() ?? ""

            // Handle itms-services
            if scheme == "itms-services" {
                if UIApplication.shared.canOpenURL(reqURL) {
                    UIApplication.shared.open(reqURL, options: [:]) { success in
                        if success {
                            // Minimise app
                            DispatchQueue.main.async {
                                UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                                // Small delay to ensure app is backgrounded
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    self.sendUpdateNotification()
                                }
                            }
                        }
                    }
                }
                decisionHandler(.cancel)
                return
            }

            // External links
            if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame == nil {
                UIApplication.shared.open(reqURL, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}

