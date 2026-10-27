// SPDX-License-Identifier: MIT

import SwiftUI
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

extension Image {
    /// Decode a stored attachment's encoded bytes (JPEG/PNG) into a SwiftUI `Image` for thumbnail
    /// rendering. `nil` when the bytes aren't a decodable image. Kept in the view layer (UIKit/AppKit),
    /// separate from `ImageAttachment`'s pure ImageIO downscale path.
    init?(attachmentData data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
    #elseif canImport(AppKit)
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
    #endif
}
