struct SourceRow: View {
    let source: SourcesViewModel.Source
    @EnvironmentObject var sourcesViewModel: SourcesViewModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.urlString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                
                if let validationState = sourcesViewModel.validationStates[source.urlString] {
                    HStack {
                        Image(systemName: validationState.icon)
                            .font(.caption)
                            .foregroundColor(validationState.color)
                        Text(validationState.description)
                            .font(.caption)
                            .foregroundColor(validationState.color)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}