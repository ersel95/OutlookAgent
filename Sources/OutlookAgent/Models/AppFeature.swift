import Foundation
import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable, Hashable {
    case inbox     = "Gelen Kutusu"
    case tasks     = "Görevler"
    case calendar  = "Takvim"
    case prospects = "Prospects"
    case logs      = "Loglar"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .inbox:     return "tray.full"
        case .tasks:     return "checklist"
        case .calendar:  return "calendar"
        case .prospects: return "scope"
        case .logs:      return "doc.text.magnifyingglass"
        }
    }

    var available: Bool { true }
}
