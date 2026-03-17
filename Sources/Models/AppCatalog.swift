import Foundation

/// Metadata about a known developer/AI tool
struct DeveloperApp {
    let name: String
    let bundleIdentifier: String
    let category: AppCategory
    let hasEmbeddedTerminal: Bool

    enum AppCategory: String, CaseIterable {
        case aiAssistant = "AI Assistant"
        case codeEditor = "Code Editor"
        case ide = "IDE"
        case terminal = "Terminal"
        case vimGui = "Vim/Neovim"
    }
}

/// Central catalog of all known developer and AI tools
enum AppCatalog {

    static let allApps: [DeveloperApp] = [
        // MARK: - AI Assistants (Desktop Apps)
        DeveloperApp(name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", category: .aiAssistant, hasEmbeddedTerminal: false),
        DeveloperApp(name: "ChatGPT", bundleIdentifier: "com.openai.chat", category: .aiAssistant, hasEmbeddedTerminal: false),
        DeveloperApp(name: "ChatGPT Atlas", bundleIdentifier: "com.openai.atlas", category: .aiAssistant, hasEmbeddedTerminal: false),
        DeveloperApp(name: "Codex", bundleIdentifier: "com.openai.codex", category: .aiAssistant, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Antigravity", bundleIdentifier: "com.google.antigravity", category: .aiAssistant, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Kiro", bundleIdentifier: "dev.kiro.desktop", category: .aiAssistant, hasEmbeddedTerminal: true),
        DeveloperApp(name: "LM Studio", bundleIdentifier: "ai.elementlabs.lmstudio", category: .aiAssistant, hasEmbeddedTerminal: false),
        DeveloperApp(name: "Ollama", bundleIdentifier: "com.electron.ollama", category: .aiAssistant, hasEmbeddedTerminal: false),

        // MARK: - VS Code Family
        DeveloperApp(name: "VS Code", bundleIdentifier: "com.microsoft.VSCode", category: .codeEditor, hasEmbeddedTerminal: true),
        DeveloperApp(name: "VS Code Insiders", bundleIdentifier: "com.microsoft.VSCodeInsiders", category: .codeEditor, hasEmbeddedTerminal: true),
        DeveloperApp(name: "VSCodium", bundleIdentifier: "com.vscodium", category: .codeEditor, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", category: .codeEditor, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Windsurf", bundleIdentifier: "com.exafunction.windsurf", category: .codeEditor, hasEmbeddedTerminal: true),

        // MARK: - JetBrains IDEs
        DeveloperApp(name: "IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "IntelliJ IDEA CE", bundleIdentifier: "com.jetbrains.intellij.ce", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "PyCharm", bundleIdentifier: "com.jetbrains.pycharm", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "PyCharm CE", bundleIdentifier: "com.jetbrains.pycharm.ce", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "WebStorm", bundleIdentifier: "com.jetbrains.WebStorm", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "GoLand", bundleIdentifier: "com.jetbrains.goland", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "CLion", bundleIdentifier: "com.jetbrains.CLion", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "PhpStorm", bundleIdentifier: "com.jetbrains.PhpStorm", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "RubyMine", bundleIdentifier: "com.jetbrains.rubymine", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Rider", bundleIdentifier: "com.jetbrains.rider", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "DataGrip", bundleIdentifier: "com.jetbrains.datagrip", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "DataSpell", bundleIdentifier: "com.jetbrains.dataspell", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "RustRover", bundleIdentifier: "com.jetbrains.rustrover", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Aqua", bundleIdentifier: "com.jetbrains.aqua", category: .ide, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Fleet", bundleIdentifier: "com.jetbrains.fleet", category: .ide, hasEmbeddedTerminal: true),

        // MARK: - Other IDEs
        DeveloperApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", category: .ide, hasEmbeddedTerminal: false),
        DeveloperApp(name: "Android Studio", bundleIdentifier: "com.google.android.studio", category: .ide, hasEmbeddedTerminal: true),

        // MARK: - Native Mac Editors
        DeveloperApp(name: "Zed", bundleIdentifier: "dev.zed.Zed", category: .codeEditor, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Nova", bundleIdentifier: "com.panic.Nova", category: .codeEditor, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Sublime Text", bundleIdentifier: "com.sublimetext.4", category: .codeEditor, hasEmbeddedTerminal: false),
        DeveloperApp(name: "Sublime Text 3", bundleIdentifier: "com.sublimetext.3", category: .codeEditor, hasEmbeddedTerminal: false),
        DeveloperApp(name: "BBEdit", bundleIdentifier: "com.barebones.bbedit", category: .codeEditor, hasEmbeddedTerminal: false),
        DeveloperApp(name: "TextMate", bundleIdentifier: "com.macromates.TextMate", category: .codeEditor, hasEmbeddedTerminal: false),
        DeveloperApp(name: "CotEditor", bundleIdentifier: "com.coteditor.CotEditor", category: .codeEditor, hasEmbeddedTerminal: false),

        // MARK: - Vim/Neovim GUIs
        DeveloperApp(name: "MacVim", bundleIdentifier: "org.vim.MacVim", category: .vimGui, hasEmbeddedTerminal: true),
        DeveloperApp(name: "VimR", bundleIdentifier: "com.qvacua.VimR", category: .vimGui, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Neovide", bundleIdentifier: "com.neovide.neovide", category: .vimGui, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Emacs", bundleIdentifier: "org.gnu.Emacs", category: .codeEditor, hasEmbeddedTerminal: true),

        // MARK: - Terminal Emulators
        DeveloperApp(name: "Terminal", bundleIdentifier: "com.apple.Terminal", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "kitty", bundleIdentifier: "net.kovidgoyal.kitty", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Alacritty", bundleIdentifier: "org.alacritty", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "WezTerm", bundleIdentifier: "com.github.wez.wezterm", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Hyper", bundleIdentifier: "co.zeit.hyper", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Tabby", bundleIdentifier: "org.tabby", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Rio", bundleIdentifier: "com.raphaelamorim.rio", category: .terminal, hasEmbeddedTerminal: true),
        DeveloperApp(name: "Prompt 3", bundleIdentifier: "com.panic.Prompt", category: .terminal, hasEmbeddedTerminal: true),
    ]

    /// All known bundle IDs (for quick lookup)
    static let knownBundleIDs: Set<String> = Set(allApps.map(\.bundleIdentifier))

    /// Bundle IDs that have embedded terminals (includes IDEs)
    static let terminalBundleIDs: Set<String> = Set(
        allApps.filter(\.hasEmbeddedTerminal).map(\.bundleIdentifier)
    )

    /// Bundle IDs for pure terminal emulators (not IDEs/editors with embedded terminals)
    static let pureTerminalBundleIDs: Set<String> = Set(
        allApps.filter { $0.category == .terminal }.map(\.bundleIdentifier)
    )

    /// Lookup by bundle ID
    static func app(for bundleID: String) -> DeveloperApp? {
        allApps.first { $0.bundleIdentifier == bundleID }
    }

    /// Check if bundle ID is a known dev/AI tool
    static func isKnownApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        // Exact match
        if knownBundleIDs.contains(bundleID) { return true }
        // Prefix match for JetBrains variants
        if bundleID.hasPrefix("com.jetbrains.") { return true }
        return false
    }

    /// Check if an app has terminal/command-line support (embedded terminal, AI chat, or is a terminal itself)
    static func hasTerminalSupport(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if terminalBundleIDs.contains(bundleID) { return true }
        // All JetBrains IDEs have embedded terminals
        if bundleID.hasPrefix("com.jetbrains.") { return true }
        return false
    }

    /// Get friendly category label for a bundle ID
    static func category(for bundleID: String?) -> DeveloperApp.AppCategory? {
        guard let bundleID else { return nil }
        return app(for: bundleID)?.category
    }
}
