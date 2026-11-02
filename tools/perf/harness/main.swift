// Drives the app's real ViewerWindowController, compiled from Sources/ with this file in place of
// main.swift. The window is fully transparent and click-through and the app never activates, so
// nothing appears on screen. Only non-private API is used, so it keeps building as the app changes.
// Usage: harness open|launch|pace|burst|zoom|gif <file>
// `launch` builds the viewer as AppDelegate does, decoding while the window is built.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let scenario = CommandLine.arguments[1]
// As main.swift does before the run loop.
if scenario == "launch" { ImageLoader.warmUp() }

func footprint() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

func threadCount() -> Int {
    var list: thread_act_array_t?
    var n: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list else { return -1 }
    for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, list[i]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.stride))
    return Int(n)
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

/// Milliseconds since the process started, so launch cost is included.
let processStart: Double = {
    var k = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &k, &size, nil, 0)
    return Double(k.kp_proc.p_starttime.tv_sec) + Double(k.kp_proc.p_starttime.tv_usec) / 1e6
}()
func now() -> Double { (Date().timeIntervalSince1970 - processStart) * 1000 }
let atMain = now()

func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { ($0 as? T).map { [$0] } ?? views(of: type, in: $0) }
}

/// Longest side of the largest image (CGImage or IOSurface) anywhere in the layer tree: a
/// filmstrip-sized thumbnail or the real photo, which may be stored sideways.
func longestImageSide(in layer: CALayer?) -> Int {
    guard let layer else { return 0 }
    var widest = 0
    if let contents = layer.contents {
        let type = CFGetTypeID(contents as CFTypeRef)
        if type == CGImage.typeID { widest = max((contents as! CGImage).width, (contents as! CGImage).height) }
        if type == IOSurfaceGetTypeID() { widest = max(IOSurfaceGetWidth(contents as! IOSurfaceRef), IOSurfaceGetHeight(contents as! IOSurfaceRef)) }
    }
    return max(widest, (layer.sublayers ?? []).map { longestImageSide(in: $0) }.max() ?? 0)
}

/// Number of decoded photos the controller holds, if it keeps them in a [URL: DecodedImage], directly
/// or in an object it owns.
func cachedPhotos(_ controller: AnyObject, depth: Int = 2) -> String {
    let children = Mirror(reflecting: controller).children
    for child in children where type(of: child.value) == [URL: DecodedImage].self {
        return "\((child.value as! [URL: DecodedImage]).count)"
    }
    guard depth > 0 else { return "n/a" }
    for child in children where !(child.value is NSView) {
        if type(of: child.value) is AnyClass {
            let object = child.value as AnyObject
            let n = cachedPhotos(object, depth: depth - 1)
            if n != "n/a" { return n }
        }
    }
    return "n/a"
}

func repeatEvery(_ interval: TimeInterval, times: Int, _ body: @escaping (Int) -> Void, then: @escaping () -> Void) {
    var k = 0
    Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
        guard k < times else { timer.invalidate(); then(); return }
        body(k)
        k += 1
    }
}

/// Longest gap between ticks of a 1 ms main-thread timer since the last reset: how long the main
/// thread was busy at a stretch.
final class StallMeter {
    private(set) var longest: Double = 0
    private var last = now()
    init() {
        let timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = now()
            self.longest = max(self.longest, t - self.last)
            self.last = t
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    func reset() { longest = 0; last = now() }
}

func waitUntil(_ condition: @escaping () -> Bool, then: @escaping () -> Void) {
    Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { timer in
        if condition() { timer.invalidate(); then() }
    }
}

let target = URL(fileURLWithPath: CommandLine.arguments[2])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timed out"); exit(2) }
/// Held for the whole run, as AppDelegate does; the animation callbacks only hold it weakly.
var viewer: ViewerWindowController?
let stalls = StallMeter()

DispatchQueue.main.async {
    let atRunLoop = now()
    let controller = scenario == "launch" ? ViewerWindowController(opening: [target]) : ViewerWindowController()
    viewer = controller
    let window = controller.window!
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    stalls.reset()
    let atShow = now()
    controller.show(urls: [target])
    let showMs = now() - atShow
    let canvas = views(of: ImageCanvasView.self, in: window.contentView!).first!
    let screen = window.screen ?? NSScreen.main!
    print(String(format: "screen %.0f×%.0f pt @%.0fx · launch: main %.0f ms, run loop %.0f ms · controller init %.0f ms · show(urls:) blocked main %.0f ms",
                 screen.frame.width, screen.frame.height, screen.backingScaleFactor, atMain, atRunLoop, atShow - atRunLoop, showMs))

    if scenario == "gif" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let cpu = cpuSeconds()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let f = footprint()
                print(String(format: "playing: CPU %.0f%% of one core · footprint %.0f MB · threads %d", (cpuSeconds() - cpu) / 4 * 100, f.now, threadCount()))
                exit(0)
            }
        }
        return
    }

    var firstPixels: Double?
    waitUntil({
        if firstPixels == nil, canvas.hasContents {
            firstPixels = now()
            stalls.reset()  // past the window's first frame
        }
        return longestImageSide(in: canvas.layer) >= 400
    }) {
        let f = footprint()
        print(String(format: "first pixels %.0f ms after show · sharp photo %.0f ms after show (%.0f ms after launch) · footprint %.0f MB",
                     (firstPixels ?? now()) - atShow, now() - atShow, now(), f.now))
        switch scenario {
        case "open", "launch":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let f = footprint()
                print(String(format: "1 s later (neighbours preloaded): footprint %.0f MB · peak %.0f MB · threads %d · photos held %@ · longest main-thread stall after first pixels %.0f ms",
                             f.now, f.peak, threadCount(), cachedPhotos(controller), stalls.longest))
                let label = views(of: NSTextField.self, in: window.contentView!).first { $0.stringValue.contains(" of ") }
                print("label: \(label?.stringValue.replacingOccurrences(of: "     ", with: " · ") ?? "none")")
                let strip = views(of: FilmstripView.self, in: window.contentView!).first!
                let thumbs = (strip.layer?.sublayers ?? []).compactMap { $0.contents }.map { $0 as! CGImage }
                print("filmstrip: \(thumbs.count) thumbnails, widest \(thumbs.map(\.width).max() ?? 0) px")
                exit(0)
            }
        case "zoom":
            // Actual size must show the photo's own pixels, and zooming back to fit must let them go.
            let src = CGImageSourceCreateWithURL(target as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
            let w = (props[kCGImagePropertyPixelWidth] as! NSNumber).intValue, h = (props[kCGImagePropertyPixelHeight] as! NSNumber).intValue
            let long = max(w, h)
            let fitted = longestImageSide(in: canvas.layer)
            let atZoom = now()
            stalls.reset()
            controller.actualSize(nil)
            waitUntil({ longestImageSide(in: canvas.layer) >= long || now() - atZoom > 3000 }) {
                let f = footprint()
                print(String(format: "100 %%: contents %d px on the long side, photo %d px (fitted %d px) · %.0f ms · footprint %.0f MB · longest main-thread stall %.0f ms",
                             longestImageSide(in: canvas.layer), long, fitted, now() - atZoom, f.now, stalls.longest))
                controller.zoomToFit(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let f = footprint()
                    print(String(format: "back to fit: contents %d px · footprint %.0f MB · peak %.0f MB",
                                 longestImageSide(in: canvas.layer), f.now, f.peak))
                    exit(0)
                }
            }
        case "pace":
            // → once every 0.7 s: slower than a decode, like reading or the slideshow.
            repeatEvery(0.7, times: 12, { k in
                controller.nextImage(nil)
                let f = footprint()
                print(String(format: "step %2d · footprint %5.0f MB · peak %5.0f MB · photos held %@", k + 1, f.now, f.peak, cachedPhotos(controller)))
            }, then: { exit(0) })
        case "burst":
            // Holding → for one second (key repeat at 30 Hz), then letting go for three.
            var maxThreads = threadCount()
            let cpu = cpuSeconds(), start = Date()
            repeatEvery(1.0 / 30, times: 30, { _ in
                controller.nextImage(nil)
                maxThreads = max(maxThreads, threadCount())
            }, then: {
                repeatEvery(0.25, times: 12, { _ in maxThreads = max(maxThreads, threadCount()) }, then: {
                    let f = footprint()
                    print(String(format: "after burst: peak %.0f MB · settled %.0f MB · max threads %d · CPU %.2f s in %.1f s · photos held %@",
                                 f.peak, f.now, maxThreads, cpuSeconds() - cpu, Date().timeIntervalSince(start), cachedPhotos(controller)))
                    exit(0)
                })
            })
        default:
            print("unknown scenario \(scenario)")
            exit(3)
        }
    }
}
app.run()
