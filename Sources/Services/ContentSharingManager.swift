import Foundation
import AppKit

/// Captures window screenshots using CGWindowListCreateImage.
/// Requires Screen Recording permission (System Settings > Privacy > Screen Recording).
@MainActor
final class ContentSharingManager {

    /// Whether screen recording permission has been granted
    var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Capture a single window by its CGWindowID.
    /// Returns nil if permission not granted or window not found.
    func captureWindow(_ windowID: CGWindowID) -> NSImage? {
        // CGWindowListCreateImage is deprecated in favor of ScreenCaptureKit,
        // but SCK needs a more complex permission flow. This still works fine.
        let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Prompt the user to grant Screen Recording permission
    func requestPermission() {
        CGRequestScreenCaptureAccess()
    }
}
