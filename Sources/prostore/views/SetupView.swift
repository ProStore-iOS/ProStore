import SwiftUI
import UIKit

// MARK: - SetupView
struct SetupView: View {
    var onComplete: () -> Void

    @State private var currentPage = 0

    private let pages: [SetupPage] = [
        SetupPage(
            title: "Welcome to ProStore!",
            subtitle: "Before you begin, follow these steps to make sure ProStore works perfectly.",
            imageName: "star.fill"
        ),
        SetupPage(
            title: "Install ProStore Shortcut",
            subtitle: "Please install the shortcut below.",
            imageName: "shortcut"
        ),
        SetupPage(
            title: "You're finished!",
            subtitle: "Thanks for completing the setup!\nYou're now ready to use ProStore.",
            imageName: "party.popper"
        )
    ]

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            TabView(selection: $currentPage) {
                ForEach(0..<pages.count, id: \.self) { index in
                    VStack(spacing: 20) {
                        Image(systemName: pages[index].imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .foregroundColor(.accentColor)

                        Text(pages[index].title)
                            .font(.largeTitle)
                            .bold()
                            .multilineTextAlignment(.center)

                        Text(pages[index].subtitle)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .animation(.easeInOut, value: currentPage)

            Spacer()

            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation {
                            currentPage -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(currentPage == pages.count - 1 ? "Finish" : "Next") {
                    withAnimation {

                        // MARK: - Shortcut install step
                        if pages[currentPage].title == "Install ProStore Shortcut" {

                            // iCloud-hosted Shortcut URL (works 100% of the time)
                            let rawURL = "https://www.icloud.com/shortcuts/d26821cec58d42fba93e4b216b70c6d5"

                            if var components = URLComponents(string: "shortcuts://import-shortcut") {
                                components.queryItems = [
                                    URLQueryItem(name: "url", value: rawURL)
                                ]

                                if let shortcutURL = components.url {
                                    UIApplication.shared.open(shortcutURL)
                                } else {
                                    print("⚠️ Failed to build import URL")
                                }
                            }
                        }

                        // Continue navigation
                        if currentPage < pages.count - 1 {
                            currentPage += 1
                        } else {
                            onComplete()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            Spacer(minLength: 20)
        }
        .padding()
    }
}

// MARK: - SetupPage model
struct SetupPage {
    let title: String
    let subtitle: String
    let imageName: String
}
