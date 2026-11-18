import AppKit
import SwiftUI

struct SearchProfilesMenu<Configuration: Codable>: View {
    private struct Profile: Codable, Identifiable {
        let id: UUID
        let name: String
        let configuration: Configuration
    }

    @EnvironmentObject private var loc: Localizer
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage private var data: Data
    @State private var isNaming = false
    @State private var name = ""

    let configuration: Configuration
    let chooseFolder: (URL) -> Void
    let run: (Configuration) -> Void

    init(key: String, configuration: Configuration,
         chooseFolder: @escaping (URL) -> Void, run: @escaping (Configuration) -> Void) {
        _data = AppStorage(wrappedValue: Data(), key)
        self.configuration = configuration
        self.chooseFolder = chooseFolder
        self.run = run
    }

    private var profiles: [Profile] {
        (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Menu(loc.s("searchProfiles.title")) {
            Button(loc.s("searchProfiles.chooseFolder")) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                if panel.runModal() == .OK, let url = panel.url { chooseFolder(url) }
            }
            Button(loc.s("searchProfiles.save")) {
                name = ""
                isNaming = true
            }
            if !profiles.isEmpty {
                Divider()
                ForEach(profiles) { profile in
                    Button(profile.name) { run(profile.configuration) }
                }
                Menu(loc.s("searchProfiles.remove")) {
                    ForEach(profiles) { profile in
                        Button(profile.name) { write(profiles.filter { $0.id != profile.id }) }
                    }
                }
            }
        }
        .fixedSize()
        .sheet(isPresented: $isNaming) {
            VStack(alignment: .leading, spacing: 14) {
                Text(loc.s("searchProfiles.save")).font(Typo.cardTitle)
                TextField(loc.s("searchProfiles.name"), text: $name)
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button(loc.s("common.cancel")) { isNaming = false }
                        .keyboardShortcut(.cancelAction)
                    Button(loc.s("searchProfiles.saveAction"), action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .padding(Metric.inset)
            .frame(width: 360)
            .background(Palette.background)
        }
    }

    private func save() {
        guard isEnabled, !trimmedName.isEmpty else { return }
        let existing = profiles.filter { $0.name.localizedCaseInsensitiveCompare(trimmedName) != .orderedSame }
        write(existing + [Profile(id: UUID(), name: trimmedName, configuration: configuration)])
        isNaming = false
    }

    private func write(_ profiles: [Profile]) {
        if let encoded = try? JSONEncoder().encode(profiles) { data = encoded }
    }
}
