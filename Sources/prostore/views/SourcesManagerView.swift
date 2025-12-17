import SwiftUI

struct SourcesManagerView: View {
    @EnvironmentObject var sourcesViewModel: SourcesViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Section {
                ForEach(sourcesViewModel.sources) { source in
                    if sourcesViewModel.editingSource?.id == source.id {
                        // Editing view
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Source URL", text: $sourcesViewModel.newSourceURL)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                                .autocapitalization(.none)

                            HStack {
                                Button("Cancel") {
                                    sourcesViewModel.editingSource = nil
                                    sourcesViewModel.newSourceURL = ""
                                }
                                .buttonStyle(.bordered)

                                Button("Save") {
                                    sourcesViewModel.updateSource(
                                        source: source,
                                        newURLString: sourcesViewModel.newSourceURL
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(sourcesViewModel.newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        SourceRow(source: source)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    if let index = sourcesViewModel.sources.firstIndex(where: { $0.id == source.id }) {
                                        sourcesViewModel.sources.remove(at: index)
                                        sourcesViewModel.saveSources()
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    sourcesViewModel.startEditing(source)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                }
                .onDelete(perform: sourcesViewModel.deleteSource)
                .onMove(perform: sourcesViewModel.moveSource)
            } header: {
                Text("Sources (\(sourcesViewModel.sources.count))")
            } footer: {
                Text("Tap and hold to reorder. Swipe left to delete or right to edit.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                if sourcesViewModel.isAddingNew {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Enter source URL", text: $sourcesViewModel.newSourceURL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .onSubmit {
                                addSource()
                            }

                        HStack {
                            Button("Cancel") {
                                sourcesViewModel.isAddingNew = false
                                sourcesViewModel.newSourceURL = ""
                            }
                            .buttonStyle(.bordered)

                            Button("Add") {
                                addSource()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(sourcesViewModel.newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        sourcesViewModel.isAddingNew = true
                    } label: {
                        Label("Add New Source", systemImage: "plus.circle.fill")
                    }
                }
            } header: {
                Text("Add Source")
            }
        }
        .navigationTitle("Sources Manager")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Load Defaults") {
                    sourcesViewModel.addDefaultSourcesIfNeeded()
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    sourcesViewModel.validateAllSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            sourcesViewModel.validateAllSources()
        }
    }

    private func addSource() {
        sourcesViewModel.addSource(urlString: sourcesViewModel.newSourceURL)
        sourcesViewModel.isAddingNew = false
        sourcesViewModel.newSourceURL = ""
    }
}