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
    let config = WKWebViewConfiguration()
    config.preferences.javaScriptEnabled = true
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true

    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    webView.load(request)
    return webView
}

func updateUIView(_ uiView: WKWebView, context: Context) {
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    uiView.load(request)
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
    }
}

