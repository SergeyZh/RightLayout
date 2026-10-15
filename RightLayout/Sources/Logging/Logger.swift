import Foundation
import os.log

extension Logger {
    static let app = Logger(subsystem: "com.sergeyzh.rightlayout", category: "app")
    static let engine = Logger(subsystem: "com.sergeyzh.rightlayout", category: "engine")
    static let detection = Logger(subsystem: "com.sergeyzh.rightlayout", category: "detection")
    static let events = Logger(subsystem: "com.sergeyzh.rightlayout", category: "events")
    static let inputSource = Logger(subsystem: "com.sergeyzh.rightlayout", category: "inputSource")
    static let hotkey = Logger(subsystem: "com.sergeyzh.rightlayout", category: "hotkey")
    static let profile = Logger(subsystem: "com.sergeyzh.rightlayout", category: "profile")
}
