// Bundled shell integration installer. Copies zsh/bash/fish OSC 133
// hooks from the app bundle (`Resources/Shell/`) to
// `~/.config/nextterm/shell/`, then prints sourcing instructions in
// an NSAlert so users know what to add to their rc file.
//
// Salvaged pattern from zenzai-v2's `zenzai-shell-integration` crate
// per the 2026-04-22 postmortem ("zsh/bash/fish OSC 133 hooks. Works
// with any terminal that parses OSC 133").
//
// Activation flow:
//   1. User runs ⌘K → "Install Shell Integration"
//   2. Files copy to ~/.config/nextterm/shell/{nextterm.zsh,
//      nextterm.bash,nextterm.fish}
//   3. NSAlert shows the user the one-liner to add to their rc
//   4. User adds the source line; next shell restart picks it up

import AppKit
import Foundation

@MainActor
enum ShellIntegrationInstaller {

    /// Bundled-resource → on-disk destination. Source filename matches
    /// the resource name; destination filename matches; the rc snippet
    /// shown to the user pulls from the source-of-truth path.
    private static let scripts: [(resource: String, ext: String)] = [
        (resource: "nextterm", ext: "zsh"),
        (resource: "nextterm", ext: "bash"),
        (resource: "nextterm", ext: "fish"),
    ]

    /// Install destination — XDG-style. Created if missing.
    private static var destinationDir: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nextterm/shell", isDirectory: true)
    }

    /// Run the install + show the post-install instructions alert.
    /// Idempotent — re-running overwrites the previously-installed
    /// copies so users can pull in updated hooks by re-invoking.
    static func install() {
        let dest = destinationDir
        do {
            try FileManager.default.createDirectory(
                at: dest, withIntermediateDirectories: true)
        } catch {
            presentError("Couldn't create \(dest.path): \(error.localizedDescription)")
            return
        }

        var copied: [String] = []
        for entry in scripts {
            guard
                let src = Bundle.main.url(
                    forResource: entry.resource, withExtension: entry.ext)
            else {
                // Resource missing from the bundle — surface so a
                // packaging regression is visible at install time
                // rather than silently shipping a broken installer.
                presentError(
                    "Bundled resource missing: \(entry.resource).\(entry.ext). "
                        + "Reinstall SolidTerm or report the build."
                )
                return
            }
            let dst = dest.appendingPathComponent(
                "\(entry.resource).\(entry.ext)")
            // Force-overwrite: rerunning the action picks up updated
            // hooks from a newer SolidTerm version.
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                copied.append(dst.path)
            } catch {
                presentError(
                    "Couldn't write \(dst.path): \(error.localizedDescription)")
                return
            }
        }

        presentSuccess(copiedPaths: copied)
    }

    private static func presentSuccess(copiedPaths: [String]) {
        let alert = NSAlert()
        alert.messageText = "Shell integration installed"
        alert.informativeText = """
            Hook files written to ~/.config/nextterm/shell/.

            Add the snippet for your shell to its rc file:

              zsh    (~/.zshrc):
                [[ -f ~/.config/nextterm/shell/nextterm.zsh ]] && \\
                    source ~/.config/nextterm/shell/nextterm.zsh

              bash   (~/.bashrc):
                [ -f ~/.config/nextterm/shell/nextterm.bash ] && \\
                    source ~/.config/nextterm/shell/nextterm.bash

              fish   (~/.config/fish/config.fish):
                if test -f ~/.config/nextterm/shell/nextterm.fish
                    source ~/.config/nextterm/shell/nextterm.fish
                end

            Restart your shell to activate. Then SolidTerm's block
            tracking (⌘[/⌘], Copy Block, duration HUD) will work.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
            let first = copiedPaths.first
        {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: first)])
        }
    }

    private static func presentError(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install shell integration"
        alert.informativeText = msg
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}
