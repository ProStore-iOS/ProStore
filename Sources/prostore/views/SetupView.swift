import SwiftUI

struct SetupView: View {
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Text("Welcome to ProStore!")
                .font(.largeTitle)
                .bold()
                .multilineTextAlignment(.center)

            Text("Let's set things up before you start using the app.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
            
            Button("Continue") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .font(.title2)
            .padding()
            
            Spacer()
        }
        .padding()
    }
}