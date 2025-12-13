// AppDetailView.swift
import SwiftUI
import Foundation

public struct AppDetailView: View {
    let app: AltApp

    @StateObject private var downloadManager = DownloadSignManager()
    @ObservedObject private var certificatesManager = CertificatesManager.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showCertError = false

    private var latestVersion: AppVersion? {
        app.versions?.first
    }

    private func formatSize(_ size: Int?) -> String {
        guard let size = size else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString,
              let date = ISO8601DateFormatter().date(from: dateString) else {
            return "Unknown"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // App Header
                    HStack(alignment: .top, spacing: 16) {
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
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 60, height: 60)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 92, height: 92)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.title2)
                                .bold()

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

                    if let generalDesc = app.localizedDescription,
                       generalDesc != latestVersion?.localizedDescription {
                        Text(generalDesc)
                    }

                    if let latest = latestVersion,
                       let latestDesc = latest.localizedDescription,
                       latestDesc != app.localizedDescription {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What's New?")
                                .font(.headline)
                            Text(latestDesc)
                        }
                    }

                    if let latest = latestVersion {
                        VStack(alignment: .leading, spacing: 4) {
                            if let version = latest.version, !version.isEmpty {
                                HStack { Text("Version:").bold(); Text(version) }
                            }
                            if let dateString = latest.date, !dateString.isEmpty {
                                HStack { Text("Released:").bold(); Text(formatDate(dateString)) }
                            }
                            if let size = latest.size {
                                HStack { Text("Size:").bold(); Text(formatSize(size)) }
                            }
                            if let minOS = latest.minOSVersion, !minOS.isEmpty {
                                HStack { Text("Min iOS Version:").bold(); Text(minOS) }
                            }
                        }
                    }

                    if let screenshots = app.screenshotURLs, !screenshots.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(screenshots, id: \.self) { url in
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .empty: ProgressView().frame(height: 200).frame(minWidth: 120).background(Color.gray.opacity(0.08)).cornerRadius(10)
                                        case .success(let image): image.resizable().scaledToFit().frame(height: 200).cornerRadius(10)
                                        case .failure: Image(systemName: "photo").resizable().scaledToFit().frame(height: 200).frame(minWidth: 120).background(Color.gray.opacity(0.08)).cornerRadius(10)
                                        @unknown default: EmptyView()
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding()
            }

            // Floating Install Button
            if !downloadManager.isProcessing {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            if certificatesManager.selectedIdentity == nil {
                                showCertError = true
                                return
                            }
                            downloadManager.downloadAndSign(app: app)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Install")
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(25)
                            .shadow(radius: 5)
                        }
                        .disabled(certificatesManager.selectedIdentity == nil)
                        .opacity(certificatesManager.selectedIdentity == nil ? 0.6 : 1.0)
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                    }
                }
            }

            // Progress Bar
            if downloadManager.isProcessing {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .frame(height: 1)

                    VStack(spacing: 8) {
                        HStack {
                            ProgressView(value: downloadManager.progress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: downloadManager.showSuccess ? .green : .blue))
                                .scaleEffect(x: 1, y: 1.5, anchor: .center)

                            if downloadManager.showSuccess {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.title2)
                            } else {
                                Text("\(Int(downloadManager.progress * 100))%")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .frame(width: 40)
                            }
                        }

                        HStack {
                            Text(downloadManager.status)
                                .font(.caption)
                                .foregroundColor(downloadManager.showSuccess ? .green : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            if !downloadManager.showSuccess {
                                Button("Cancel") { downloadManager.cancel() }
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                    .shadow(radius: 2)
                }
                .transition(.move(edge: .bottom))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if downloadManager.isProcessing {
                    Button("Cancel") { downloadManager.cancel() }
                        .foregroundColor(.red)
                } else if app.downloadURL != nil {
                    Button {
                        if certificatesManager.selectedIdentity == nil {
                            showCertError = true
                            return
                        }
                        downloadManager.downloadAndSign(app: app)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                            Text("Download")
                        }
                    }
                    .disabled(certificatesManager.selectedIdentity == nil)
                    .opacity(certificatesManager.selectedIdentity == nil ? 0.6 : 1.0)
                }
            }
        }
        .alert("Please select a certificate first!", isPresented: $showCertError) {
            Button("OK", role: .cancel) { }
        }
        .animation(Animation.easeInOut(duration: 0.3), value: downloadManager.isProcessing)
        .animation(Animation.easeInOut(duration: 0.3), value: downloadManager.showSuccess)
    }
}