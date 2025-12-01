import SwiftUI
import WebKit

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
        // Configure the web view
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptEnabled = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Load request
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Only reload if the URL changed; avoids flicker
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: UpdaterWebView

        init(parent: UpdaterWebView) {
            self.parent = parent
        }

        // Intercept navigation actions
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let reqURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = reqURL.scheme?.lowercased() ?? ""

            // 1) Handle itms-services (install manifest) by opening in system
            if scheme == "itms-services" {
                if UIApplication.shared.canOpenURL(reqURL) {
                    UIApplication.shared.open(reqURL, options: [:], completionHandler: nil)
                }
                decisionHandler(.cancel)
                return
            }

            // 2) If the link tries to open in a new window (target="_blank"), open externally
            //    (navigationAction.targetFrame is nil for new-window links)
            if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame == nil {
                // choose: open in Safari (external), or load in same webview:
                UIApplication.shared.open(reqURL, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }

            // 3) Allow normal navigation
            decisionHandler(.allow)
        }

        // Optional: handle window.open() from JS (so target=_blank still works)
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // If the action has a URL, open externally (Safari)
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return nil
        }

        // Optional: handle JS alert/confirm/prompt if needed
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            // simple native alert fallback
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true, completion: nil)
        }
    }
}
