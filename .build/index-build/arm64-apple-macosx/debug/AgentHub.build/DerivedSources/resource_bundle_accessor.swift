import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("AgentHub_AgentHub.bundle").path
        let buildPath = "/Users/darkness/WorkSpace/TechKreator/ClaudeInstances/AgentHub/.build/index-build/arm64-apple-macosx/debug/AgentHub_AgentHub.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}