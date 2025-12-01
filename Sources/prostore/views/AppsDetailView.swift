import SwiftUI
import Foundation

public struct AppDetailView: View {
    let app: AltApp

    private var latestVersion: AppVersion? {
        app.versions?.first
    }

    private func formatSize(_ size: Int?) -> String {
        guard let size = size else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString, let date = ISO8601DateFormatter().date(from: dateString) else {
            return "Unknown"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // App Header
                HStack(alignment: .top, spacing: 16) {
                    // Reserve a fixed column for the icon to avoid shifting
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.12))
                            .frame(width: 92, height: 92)

                        if let iconURL = app.iconURL {
                            RetryAsyncImage(
                                url: iconURL,
                                size: CGSize(width: 80, height: 80),
                                maxAttempts: 3,
                                content: { image in
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                },
                                placeholder: {
                                    ProgressView()
                                        .frame(width: 80, height: 80)
                                },
                                failure: {
                                    Image(systemName: "app")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 60, height: 60)
                                        .foregroundColor(.secondary)
                                }
                            )
                        } else {
                            Image(systemName: "app")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 60, height: 60)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 92, height: 92, alignment: .top)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title2)
                            .bold()

                        // Developer name (if available) with repo name underneath.
                        if let dev = app.developerName, !dev.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dev)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                if let repo = app.repositoryName, !repo.isEmpty {
                                    Text(repo)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else if let repo = app.repositoryName, !repo.isEmpty {
                            // If developer is missing, still show the repository name under the title
                            Text(repo)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }

                // General description
                if let generalDesc = app.localizedDescription, generalDesc != latestVersion?.localizedDescription {
                    Text(generalDesc)
                }

                // What's New
                if let latest = latestVersion, let latestDesc = latest.localizedDescription,
                   latestDesc != app.localizedDescription {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What's New?")
                            .font(.headline)
                        Text(latestDesc)
                    }
                }

                // Version info
                if let latest = latestVersion {
                    VStack(alignment: .leading, spacing: 4) {
                        if let version = latest.version, !version.isEmpty {
                            HStack {
                                Text("Version:").bold()
                                Text(version)
                            }
                        }

                        if let dateString = latest.date, !dateString.isEmpty {
                            HStack {
                                Text("Released:").bold()
                                Text(formatDate(dateString))
                            }
                        }

                        if let size = latest.size {
                            HStack {
                                Text("Size:").bold()
                                Text(formatSize(size))
                            }
                        }

                        if let minOS = latest.minOSVersion, !minOS.isEmpty {
                            HStack {
                                Text("Min iOS Version:").bold()
                                Text(minOS)
                            }
                        }
                    }
                }

                // Screenshots (from general app)
                if let screenshots = app.screenshotURLs, !screenshots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(screenshots, id: \.self) { url in
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .empty:
                                        ProgressView()
                                            .frame(height: 200)
                                            .frame(minWidth: 120)
                                            .background(Color.gray.opacity(0.08))
                                            .cornerRadius(10)
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 200)
                                            .cornerRadius(10)
                                    case .failure:
                                        Image(systemName: "photo")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 200)
                                            .frame(minWidth: 120)
                                            .background(Color.gray.opacity(0.08))
                                            .cornerRadius(10)
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}