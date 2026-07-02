import SwiftUI


/// Per-app configuration for the shared browse toolbar (help text, import filters, optional extra UI).
public struct BrowseToolbarConfiguration {
    /// Help text for the Clear button.
    public let clearHelpText: String
    /// Predicate deciding whether a candidate import URL is supported.
    public let importFileFilter: @Sendable (URL) -> Bool
    /// Optional function returning the output filename suffix for an imported URL.
    public let outputSuffix: (@Sendable (URL) -> String)?
    /// Optional pre-encryption transform applied to imported file contents.
    public let fileProcessor: (@Sendable (URL) throws -> Data?)?
    /// Optional extra toolbar content placed alongside the standard items.
    public let additionalContent: (() -> AnyView)?
    /// Optional binding indicating whether an app-specific popover is currently shown.
    public let additionalPopoverShowing: Binding<Bool>?

    /// Create a configuration. Only `clearHelpText` and `importFileFilter` are required.
    public init(
        clearHelpText: String,
        importFileFilter: @escaping @Sendable (URL) -> Bool,
        outputSuffix: (@Sendable (URL) -> String)? = nil,
        fileProcessor: (@Sendable (URL) throws -> Data?)? = nil,
        additionalContent: (() -> AnyView)? = nil,
        additionalPopoverShowing: Binding<Bool>? = nil
    ) {
        self.clearHelpText = clearHelpText
        self.importFileFilter = importFileFilter
        self.outputSuffix = outputSuffix
        self.fileProcessor = fileProcessor
        self.additionalContent = additionalContent
        self.additionalPopoverShowing = additionalPopoverShowing
    }
}

/// Adds the shared browse toolbar to any `View`.
public extension View {
    /// Attach the shared browse toolbar (import, tag filter, delete, change-date, clear) to this view.
    func browseToolbar<VM: BrowseViewModelBase>(
        viewModel: VM,
        configuration: BrowseToolbarConfiguration,
        showTagSheet: Binding<Bool>
    ) -> some View {
        self.modifier(BrowseToolbarModifier(
            viewModel: viewModel,
            configuration: configuration,
            showTagSheet: showTagSheet
        ))
    }
}

private struct BrowseToolbarModifier<VM: BrowseViewModelBase>: ViewModifier {
    @Bindable var viewModel: VM
    let configuration: BrowseToolbarConfiguration
    @Binding var showTagSheet: Bool

    @State private var showTagFilter = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        Task {
                            await viewModel.showImportPanel(
                                fileFilter: configuration.importFileFilter,
                                outputSuffix: configuration.outputSuffix,
                                fileProcessor: configuration.fileProcessor
                            )
                        }
                    }) {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .help("Import files")
                }

                if let additionalContent = configuration.additionalContent {
                    ToolbarItem(placement: .automatic) {
                        additionalContent()
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        showTagFilter.toggle()
                    }) {
                        Label("Filter by Tag", systemImage: "line.3.horizontal.decrease.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help("Filter by tag")
                    .disabled(!viewModel.metadataLoaded)
                    .popover(isPresented: $showTagFilter) {
                        TagFilterView(selectedTags: $viewModel.selectedTagFilters, filterMode: $viewModel.tagFilterMode, allTags: viewModel.metadata.allTags())
                            .frame(width: 250, height: 300)
                            .padding()
                    }
                }

                ToolbarItem(placement: .automatic) {
                    if !viewModel.selectedTagFilters.isEmpty {
                        HStack(spacing: 4) {
                            Button(action: { showTagFilter = true }) {
                                Text("\(viewModel.selectedTagFilters.count)")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            Button(action: { viewModel.selectedTagFilters.removeAll() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(8)
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        viewModel.showDeleteConfirmation = true
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete selected")
                    .disabled(viewModel.selectedDates.isEmpty)
                }

                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        if let firstDate = viewModel.selectedDates.sorted().first {
                            viewModel.datePickerValue = firstDate
                        }
                        viewModel.showDatePicker = true
                    }) {
                        Label("Change Date", systemImage: "calendar")
                    }
                    .help("Change date")
                    .disabled(viewModel.selectedDates.isEmpty)
                }

                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        Task { await viewModel.exportSelected() }
                    }) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export selected")
                    .disabled(viewModel.selectedDates.isEmpty)
                }

                ToolbarItem(placement: .automatic) {
                    Button("Clear") {
                        viewModel.clearSensitiveData()
                    }
                    .help(configuration.clearHelpText)
                    .keyboardShortcut("k", modifiers: .command)
                }
            }
            .background {
                Button("") { showTagSheet = true }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(viewModel.selectedDates.isEmpty || !viewModel.metadataLoaded)
                    .hidden()
                Button("") { viewModel.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(showTagFilter || showTagSheet || (configuration.additionalPopoverShowing?.wrappedValue ?? false))
                    .hidden()
                if configuration.additionalContent == nil {
                    Button("") { showTagFilter = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .hidden()
                }
                Button("") { viewModel.showDeleteConfirmation = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(viewModel.selectedDates.isEmpty)
                    .hidden()
                Button("") { viewModel.showDeleteConfirmation = true }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0x08))), modifiers: .command)
                    .disabled(viewModel.selectedDates.isEmpty)
                    .hidden()
                Button("") { viewModel.clearSelection() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(viewModel.selectedDates.isEmpty)
                    .hidden()
            }
    }
}

