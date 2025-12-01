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

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Reload if needed
        let request = URLRequest(url: url)
        uiView.load(request)
    }
}