import Foundation
import AppKit

struct CalendarChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String
    let type: String
    let isWritable: Bool
    var color: NSColor? = nil
    var displayName: String { "\(sourceTitle) / \(title)" }
}
