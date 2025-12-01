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
        // Create WKWebView with configuration
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.allowsInlineMediaPlayback = true
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Clear cache completely
        let dataTypes = Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeCookies])
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) {
            print("✅ WKWebView cache fully cleared!")
            let request = URLRequest(url: self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            webView.load(request)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            uiView.load(request)
        }
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: UpdaterWebView

        init(parent: UpdaterWebView) {
            self.parent = parent
            super.init()
            requestNotificationPermission()
        }

        private func requestNotificationPermission() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if granted {
                    print("🔔 Notifications allowed!")
                } else if let error = error {
                    print("❌ Notification permission error: \(error)")
                }
            }
        }

        private func sendUpdateNotification() {
            let content = UNMutableNotificationContent()
            content.title = "ProStore Update"
            content.body = "ProStore will now update!"
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
                    // Open Apple install dialog
                    UIApplication.shared.open(reqURL, options: [:]) { success in
                        if success {
                            // Minimise app to home screen
                            DispatchQueue.main.async {
                                // Trick to go home
                                UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                                // Send push notification after a tiny delay to ensure we're on Home Screen
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

            // Open external links in Safari
            if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame == nil {
                UIApplication.shared.open(reqURL, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
