// SPDX-License-Identifier: MIT

#if os(iOS)
import SwiftUI
import UIKit

/// The camera capture sheet for composer attachments — `UIImagePickerController` in `.camera` mode
/// (PhotosPicker has no capture path). iOS-only: macOS has no equivalent flow, and Continuity Camera
/// arrives for free through the system clipboard + the Paste action.
struct CameraPicker: UIViewControllerRepresentable {
    /// Receives the captured photo as encoded JPEG bytes (nil on cancel). The caller downscales via the
    /// same `chat.attach(imageData:)` path every other attachment source uses.
    var onCapture: @MainActor (Data?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: @MainActor (Data?) -> Void
        private var didComplete = false

        init(onCapture: @escaping @MainActor (Data?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard !didComplete else { return }
            didComplete = true
            let captured = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            let maxLongEdge = CGFloat(ImageAttachment.defaultMaxLongEdge)
            let quality = ImageAttachment.defaultQuality
            // Downscale before JPEG encoding on a background queue and notify on the next main-actor
            // turn so we avoid a 48 MP bitmap+JPEG memory spike (Jetsam OOM) and don't tear down the
            // fullScreenCover synchronously inside UIKit's delegate stack.
            Task { @MainActor [onCapture] in
                guard let captured else {
                    onCapture(nil)
                    return
                }
                let targetSize = Self.thumbnailPointSize(for: captured, maxLongEdge: maxLongEdge)
                let thumbnail = await captured.byPreparingThumbnail(ofSize: targetSize) ?? captured
                let data = await Task.detached(priority: .userInitiated) {
                    thumbnail.jpegData(compressionQuality: quality)
                }.value
                onCapture(data)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !didComplete else { return }
            didComplete = true
            Task { @MainActor [onCapture] in
                onCapture(nil)
            }
        }

        private static func thumbnailPointSize(for image: UIImage, maxLongEdge: CGFloat) -> CGSize {
            let scale = max(image.scale, 1)
            let pixelWidth = image.size.width * scale
            let pixelHeight = image.size.height * scale
            let longEdge = max(pixelWidth, pixelHeight)
            guard longEdge > maxLongEdge, longEdge > 0 else {
                return image.size
            }
            let ratio = maxLongEdge / longEdge
            return CGSize(
                width: max(1, (pixelWidth * ratio / scale).rounded()),
                height: max(1, (pixelHeight * ratio / scale).rounded())
            )
        }
    }
}
#endif
