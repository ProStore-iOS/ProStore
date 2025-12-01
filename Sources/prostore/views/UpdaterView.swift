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
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        // Add pull-to-refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.refreshWebView(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // Clear cache completely
        let dataTypes = Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeCookies])
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) {
            print("✅ WKWebView cache fully cleared!")
            // Load the request after clearing cache
            let request = URLRequest(url: self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            webView.load(request)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Reload only if URL changed
        if uiView.url != url {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            uiView.load(request)
        }
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: UpdaterWebView

        init(parent: UpdaterWebView) {
            self.parent = parent
            super.init()
            requestNotificationPermission()
        }

        // Pull-to-refresh handler
        @objc func refreshWebView(_ sender: UIRefreshControl) {
            if let webView = sender.superview as? WKWebView {
                let request = URLRequest(url: parent.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                webView.load(request)
            }
            sender.endRefreshing()
        }

        // Request notification permissions
        private func requestNotificationPermission() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if granted {
                    print("🔔 Notifications allowed!")
                }
            }
        }

        // Send local notification
        private func sendUpdateNotification() {
            let content = UNMutableNotificationContent()
            content.title = "ProStore Update"
            content.body = "ProStore will now update!"
            content.sound = .default

            let request = UNNotificationRequest(identifier: "ProStoreUpdate", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }

        // MARK: Navigation Delegate
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let reqURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = reqURL.scheme?.lowercased() ?? ""

            // 1️⃣ itms-services: open in system & send push
            if scheme == "itms-services" {
                if UIApplication.shared.canOpenURL(reqURL) {
                    UIApplication.shared.open(reqURL, options: [:], completionHandler: nil)
                    sendUpdateNotification()
                }
                decisionHandler(.cancel)
                return
            }

            // 2️⃣ target="_blank": open externally
            if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame == nil {
                UIApplication.shared.open(reqURL, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
