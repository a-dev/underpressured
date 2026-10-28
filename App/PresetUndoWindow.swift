import AppKit
import AppModel
import SwiftUI

/// Supplies undo for this non-document window while preserving SwiftUI's delegate.
struct PresetUndoWindow: NSViewRepresentable {
    let model: AppModel
    let manager: UndoManager?

    func makeNSView(context: Context) -> UndoView { UndoView(model: model, manager: manager) }
    func updateNSView(_ view: UndoView, context: Context) {}

    final class UndoView: NSView {
        let model: AppModel
        let manager: UndoManager
        private var undoDelegate: UndoWindowDelegate?
        private var undoResponder: PresetUndoResponder?

        init(model: AppModel, manager: UndoManager?) {
            self.model = model
            self.manager = manager ?? UndoManager()
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, undoDelegate == nil else { return }
            let delegate = UndoWindowDelegate(original: window.delegate, manager: manager)
            undoDelegate = delegate
            window.delegate = delegate
            model.presetUndoManager = delegate.manager
            let responder = PresetUndoResponder(manager: delegate.manager)
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
            undoResponder = responder
        }
    }
}

@MainActor
final class UndoWindowDelegate: NSObject, NSWindowDelegate {
    let manager: UndoManager
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?

    init(original: (any NSWindowDelegate)?, manager: UndoManager = UndoManager()) {
        self.original = original
        self.manager = manager
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { manager }

    override func responds(to selector: Selector!) -> Bool {
        let originalResponds = original?.responds(to: selector) ?? false
        return super.responds(to: selector) || originalResponds
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

/// Non-document windows need a responder for the standard Edit menu selectors.
@MainActor
final class PresetUndoResponder: NSResponder, NSMenuItemValidation {
    private let manager: UndoManager

    init(manager: UndoManager) {
        self.manager = manager
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var undoManager: UndoManager? { manager }

    @objc func undo(_ sender: Any?) { manager.undo() }
    @objc func redo(_ sender: Any?) { manager.redo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            item.title = manager.undoMenuItemTitle
            return manager.canUndo
        }
        if item.action == #selector(redo(_:)) {
            item.title = manager.redoMenuItemTitle
            return manager.canRedo
        }
        return false
    }
}

/// Uses the focused text editor's manager first, then the window's preset history.
struct PresetUndoCommands: Commands {
    @Bindable var model: AppModel

    private var manager: UndoManager? {
        _ = model.presetUndoRevision
        _ = model.presets
        return NSApp.keyWindow?.firstResponder?.undoManager ?? model.presetUndoManager
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(manager?.undoMenuItemTitle ?? String(localized: "Undo", bundle: .main)) {
                NSApp.sendAction(#selector(PresetUndoResponder.undo(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("z")
            .disabled(!(manager?.canUndo ?? false))
            Button(manager?.redoMenuItemTitle ?? String(localized: "Redo", bundle: .main)) {
                NSApp.sendAction(#selector(PresetUndoResponder.redo(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(manager?.canRedo ?? false))
        }
    }
}
