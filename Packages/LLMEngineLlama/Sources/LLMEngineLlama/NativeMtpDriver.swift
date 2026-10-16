// SPDX-License-Identifier: MIT

import Foundation
import llama

/// Dynamic linker wrapper for native MTP (Multi-Token Prediction) bridge in llama.xcframework.
/// Ensures 100% build-safety and zero-crash graceful fallback if symbols are not yet exported.
public final class NativeMtpDriver: @unchecked Sendable {
    private typealias InitFn = @convention(c) (OpaquePointer?, OpaquePointer?, Int32) -> UnsafeMutableRawPointer?
    private typealias PredictFn = @convention(c) (UnsafeMutableRawPointer?, llama_token, UnsafeMutablePointer<llama_token>?, Int32) -> Int32
    private typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias AvailFn = @convention(c) () -> Bool

    private static let isAvailableSymbol: AvailFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "llama_mtp_is_available") else { return nil }
        return unsafeBitCast(sym, to: AvailFn.self)
    }()

    private static let initSymbol: InitFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "llama_mtp_init") else { return nil }
        return unsafeBitCast(sym, to: InitFn.self)
    }()

    private static let predictSymbol: PredictFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "llama_mtp_predict") else { return nil }
        return unsafeBitCast(sym, to: PredictFn.self)
    }()

    private static let freeSymbol: FreeFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "llama_mtp_free") else { return nil }
        return unsafeBitCast(sym, to: FreeFn.self)
    }()

    /// Returns true if native MTP runtime symbols are linked in the current process.
    public static var isCompiledIn: Bool {
        isAvailableSymbol?() ?? false
    }

    private var runner: UnsafeMutableRawPointer?

    public init?(context: OpaquePointer?, model: OpaquePointer?, nDraft: Int = 2) {
        guard let initFn = Self.initSymbol,
              let r = initFn(context, model, Int32(nDraft)) else {
            return nil
        }
        self.runner = r
    }

    public func predict(lastToken: llama_token, maxDrafts: Int = 2) -> [llama_token] {
        guard let runner, let predictFn = Self.predictSymbol else { return [] }
        var drafts = [llama_token](repeating: 0, count: maxDrafts)
        let count = drafts.withUnsafeMutableBufferPointer { buf in
            predictFn(runner, lastToken, buf.baseAddress, Int32(buf.count))
        }
        if count > 0 {
            return Array(drafts.prefix(Int(count)))
        }
        return []
    }

    deinit {
        if let runner, let freeFn = Self.freeSymbol {
            freeFn(runner)
        }
    }
}
