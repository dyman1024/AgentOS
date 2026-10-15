import AppKit
@_cdecl("agentos_make_view")
public func agentosMakeView() -> UnsafeMutableRawPointer {
    let items: [Int] = []
    _ = items[3]   // a typical generated-code bug: index out of range
    return Unmanaged.passRetained(NSView()).toOpaque()
}
