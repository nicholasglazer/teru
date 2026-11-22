// Lists the on-screen windows owned by a process, for the macOS smoke test.
// Usage: swift macos-windows.swift <pid>. Exits 1 when there are none.
// Window owners and bounds need no Screen Recording permission.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: macos-windows.swift <pid>")
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var found = 0
for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    print("window layer=\(layer) bounds=\(bounds)")
    found += 1
}
exit(found > 0 ? 0 : 1)
