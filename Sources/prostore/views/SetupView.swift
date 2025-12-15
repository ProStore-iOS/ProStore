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
            title: "Install StikDebug",
            subtitle: "Install StikDebug from the App Store [here](https://apps.apple.com/us/app/stikdebug/id6744045754).",
            imageName: "bolt.fill"
        ),
        SetupPage(
            title: "Add pairing file to StikDebug",
            subtitle: "Follow the steps [here](https://stikdebug.xyz/#guide) on your computer to place the pairing file in StikDebug.",
            imageName: "bolt.fill"
        ),
        SetupPage(
            title: "Add pairing file to ProStore",
            subtitle: "Go to 'Files', and navigate to the 'StikDebug' folder in 'On My iPad',\nthen duplicate/copy the file to the 'ProStore' folder in 'On My iPad'.\nMake sure its called 'pairingFile.plist'.",
            imageName: "p.square"
        ),
        SetupPage(
            title: "Reminder",
            subtitle: "Important: Make sure before every time you use ProStore, turn on the StikDebug VPN by either opening StikDebug or via Settings, otherwise app installs won't work!",
            imageName: "list.bullet.circle"
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

                        Text(.init(pages[index].subtitle))
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

