import AppKit
import SwiftUI

@main
struct SteadyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var editor = WorkspaceEditor()

    var body: some Scene {
        Window("Steady", id: "main") {
            WorkspaceView(editor: editor)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.editor = editor }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: WorkspaceEditor?
    private var processingTermination = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !processingTermination }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !processingTermination else { return .terminateCancel }
        processingTermination = true
        guard editor?.prepareToTerminate() == false else { return .terminateNow }
        Task { @MainActor in
            await Task.yield()
            editor?.reopenWindow?()
            processingTermination = false
        }
        return .terminateCancel
    }
}
