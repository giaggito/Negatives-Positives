import DarkroomUI
import PositivesCore
import SwiftUI

/// Presets: point at one to see it on the photo, click to apply (to every selected photo when several are
/// selected), save the current look as a new one.
struct PresetsPopover: View {
    @Bindable var model: EditorModel
    @State private var newName = ""
    @State private var scope = Preset.Scope.look
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Presets").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if model.marked.count > 1 {
                    Text("Applies to \(model.marked.count) photos").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section("Starters", model.presets.filter(\.builtIn))
                    let mine = model.presets.filter { !$0.builtIn }
                    if !mine.isEmpty { section("Yours", mine) }
                }
            }
            .frame(maxHeight: 340)
            .onHover { if !$0 { model.previewPreset = nil } }
            Divider().overlay(Theme.hairline)
            Text("Save this photo's settings as a preset").font(Theme.label).foregroundStyle(Theme.secondary)
            Segmented(options: Preset.Scope.allCases.map(\.title), selection: Binding(
                get: { Preset.Scope.allCases.firstIndex(of: scope) ?? 1 }, set: { scope = Preset.Scope.allCases[$0] }))
            Text(scope.explanation)
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("Preset name", text: $newName, onCommit: save)
                    .textFieldStyle(.roundedBorder).font(Theme.label)
                PlainTextButton(title: "Save", symbol: "plus") { save() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Point at a preset to preview it, click to apply.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
        .padding(14)
        .frame(width: 290)
        .background(Theme.panel)
        .onDisappear { model.previewPreset = nil }
    }

    private func save() {
        model.savePreset(named: newName, scope: scope)
        newName = ""
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [Preset]) -> some View {
        SectionHeader(title: title).padding(.top, 6).padding(.bottom, 2)
        ForEach(list) { p in row(p) }
    }

    private func row(_ p: Preset) -> some View {
        let previewing = model.previewPreset?.id == p.id
        return HStack(spacing: 8) {
            Image(systemName: p.scope == .film ? "film" : (p.scope == .everything ? "square.stack.3d.up" : "camera.filters"))
                .font(.system(size: 11)).frame(width: 16).foregroundStyle(Theme.tertiary)
            if renaming == p.id {
                TextField("", text: $renameText, onCommit: { model.renamePreset(p, to: renameText); renaming = nil })
                    .textFieldStyle(.plain).font(Theme.label)
            } else {
                Text(p.name).font(Theme.label).foregroundStyle(previewing ? Color.black : Theme.text).lineLimit(1)
            }
            Spacer()
            if !p.builtIn && p.scope != .look {
                Text(p.scope == .film ? "film" : "all").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(previewing ? Color.black.opacity(0.6) : Theme.tertiary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(previewing ? Color.black.opacity(0.3) : Theme.hairline))
            }
            if let s = p.look.film.stock, let look = FilmLooks.shared.look(s) {
                Text(look.shortName).font(.system(size: 10)).foregroundStyle(previewing ? Color.black.opacity(0.6) : Theme.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(previewing ? Theme.accent : Color.clear))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.previewPreset = p } else if model.previewPreset?.id == p.id { model.previewPreset = nil }
        }
        .onTapGesture { model.applyPreset(p) }
        .contextMenu {
            Button("Apply") { model.applyPreset(p) }
            if !p.builtIn {
                Button("Rename") { renameText = p.name; renaming = p.id }
                Divider()
                Button("Delete") { model.deletePreset(p) }
            }
        }
    }
}

/// "Save as Preset" (Photo menu, ⇧⌘P, and the Film page): name it and choose what it carries.
struct SavePresetSheet: View {
    @Bindable var model: EditorModel
    @Binding var isPresented: Bool
    @State var scope: Preset.Scope
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save as Preset").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            TextField("Name", text: $name, onCommit: save).textFieldStyle(.roundedBorder)
            Segmented(options: Preset.Scope.allCases.map(\.title), selection: Binding(
                get: { Preset.Scope.allCases.firstIndex(of: scope) ?? 1 }, set: { scope = Preset.Scope.allCases[$0] }))
            Text(scope.explanation).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                PlainTextButton(title: "Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                PlainTextButton(title: "Save", prominent: true) { save() }
                    .frame(width: 100)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.savePreset(named: name, scope: scope)
        model.status = "Preset “\(name.trimmingCharacters(in: .whitespaces))” saved — find it under Presets (P)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if model.status?.hasPrefix("Preset “") == true { model.status = nil } }
        isPresented = false
    }
}
