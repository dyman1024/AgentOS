import AppKit
import MachO

func loadedImages(matching s: String) -> Int {
    (0..<_dyld_image_count()).filter { String(cString: _dyld_get_image_name($0)).contains(s) }.count
}
func load(_ path: String) -> (NSView?, Double, UnsafeMutableRawPointer?) {
    let t0 = CFAbsoluteTimeGetCurrent()
    guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { print("dlopen failed:", String(cString: dlerror())); return (nil, 0, nil) }
    typealias Make = @convention(c) () -> UnsafeMutableRawPointer
    let sym = dlsym(h, "agentos_make_view")!
    let view = Unmanaged<NSView>.fromOpaque(unsafeBitCast(sym, to: Make.self)()).takeRetainedValue()
    return (view, (CFAbsoluteTimeGetCurrent() - t0) * 1000, h)
}

let mode = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
win.makeKeyAndOrderFront(nil); app.activate()

switch mode {
case "load":
    let (v1, ms1, h1) = load(CommandLine.arguments[2])
    print(String(format: "v1 dlopen+make view: %.1f ms, class=%@", ms1, NSStringFromClass(type(of: v1!))))
    win.contentView = v1
    let (v2, ms2, _) = load(CommandLine.arguments[3])
    print(String(format: "v2 (same module name, new path) dlopen+make view: %.1f ms, class=%@", ms2, NSStringFromClass(type(of: v2!))))
    let (v3, ms3, _) = load(CommandLine.arguments[4])
    print(String(format: "v3 (unique module name) dlopen+make view: %.1f ms, class=%@", ms3, NSStringFromClass(type(of: v3!))))
    win.contentView = nil
    print("dlclose(v1) =", dlclose(h1), "; v1 image still mapped:", loadedImages(matching: "native/libA1.dylib") > 0)
    exit(0)
case "crash":
    print("host alive, loading generated code…"); fflush(stdout)
    _ = load(CommandLine.arguments[2])
    print("host survived")   // never reached
    exit(0)
default: break
}
app.run()
