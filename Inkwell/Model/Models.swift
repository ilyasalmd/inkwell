import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Colour helpers

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(UIColor(hex: hex, alpha: alpha))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

// MARK: - Node types

enum NodeKind: String, Codable {
    case folder, notebook
}

enum NodeTint: String, Codable, CaseIterable, Identifiable {
    case ink, ocean, forest, ember, rose, violet, gold, slate

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var hex: UInt32 {
        switch self {
        case .ink: return 0x1F3A5F
        case .ocean: return 0x0EA5E9
        case .forest: return 0x16A34A
        case .ember: return 0xF97316
        case .rose: return 0xE11D48
        case .violet: return 0x9333EA
        case .gold: return 0xCA8A04
        case .slate: return 0x475569
        }
    }
    var color: Color { Color(hex: hex) }
}

enum PageTemplate: String, Codable, CaseIterable, Identifiable {
    case blank, lined, squared, dotted, cornell, cornellGrid

    var id: String { rawValue }
    var title: String {
        switch self {
        case .blank: return "Blank"
        case .lined: return "Lined"
        case .squared: return "Squared"
        case .dotted: return "Dotted"
        case .cornell: return "Cornell"
        case .cornellGrid: return "Cornell Grid"
        }
    }
    /// Templates that make sense on an endless whiteboard.
    var suitsWhiteboard: Bool { self != .cornell && self != .cornellGrid }
}

enum PaperColor: String, Codable, CaseIterable, Identifiable {
    case white, cream, sky, mint, blush, charcoal

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var isDark: Bool { self == .charcoal }
    var hex: UInt32 {
        switch self {
        case .white: return 0xFFFFFF
        case .cream: return 0xFBF6E9
        case .sky: return 0xE9F2FB
        case .mint: return 0xE8F5EC
        case .blush: return 0xFBECEF
        case .charcoal: return 0x1E1F26
        }
    }
    var color: Color { Color(hex: hex) }
    var lineColor: Color {
        isDark ? Color(hex: 0x8A90A6, alpha: 0.35) : Color(hex: 0x6B7AA8, alpha: 0.30)
    }
    var accentLineColor: Color {
        isDark ? Color(hex: 0xFF7A8A, alpha: 0.55) : Color(hex: 0xE5484D, alpha: 0.45)
    }
}

struct PageInfo: Codable, Identifiable, Hashable {
    var id = UUID()
    var template: PageTemplate
    var paper: PaperColor
    /// Zero-based page of the notebook's imported PDF used as the page background.
    var pdfIndex: Int?
    /// Height ÷ width. Defaults to A4 for template pages; PDF pages keep their own shape.
    var aspect: Double?
    /// Ink shows exactly the colour it was drawn in. Pages saved before build 13 decode as nil: on dark paper their
    /// ink keeps being drawn with dark-mode colour swapping (black shows as white), so it looks as it always did,
    /// and new ink there is pre-swapped (`ToolSpec.makeTool(for:)`) so it comes out in the colour picked.
    var trueInk: Bool? = true

    /// How PencilKit should draw this page's ink.
    var inkStyle: UIUserInterfaceStyle { paper.isDark && pdfIndex == nil && trueInk != true ? .dark : .light }

    var heightRatio: CGFloat { CGFloat(aspect ?? Double(PageMetrics.height / PageMetrics.width)) }
}

/// A notebook is either a stack of pages or one large pannable whiteboard.
enum NotebookMode: String, Codable { case pages, whiteboard }

struct Node: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: NodeKind
    var parentID: UUID?
    var createdAt = Date()
    var modifiedAt = Date()
    var tint: NodeTint = .ink
    var pages: [PageInfo] = []
    var sourceEventID: String?
    var cover: CoverDesign?
    /// File name inside the Imports folder holding the imported PDF, if any.
    var pdfFile: String?
    /// Identifies the linked-folder file this notebook was imported from.
    var sourceKey: String?
    var sourceStamp: Double?
    /// nil means a normal page notebook (also how notebooks saved before whiteboards existed decode).
    var mode: NotebookMode?
    /// Set while the item sits in the Trash. Anything inside a trashed folder is hidden with it.
    var trashedAt: Date?

    var isWhiteboard: Bool { mode == .whiteboard }
    var isFolder: Bool { kind == .folder }
    var kindLabel: String { isFolder ? "Folder" : "Notebook" }
}

struct NodeRef: Codable, Transferable {
    var id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

// MARK: - Schedules

struct ScheduleRule: Identifiable, Codable, Hashable {
    enum Output: String, Codable, CaseIterable, Identifiable {
        case notebook, folder
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notebook: return "A notebook each time"
            case .folder: return "A folder each time"
            }
        }
    }

    var id = UUID()
    var title: String
    var weekdays: Set<Int> = [2]          // Calendar weekday numbers, 1 = Sunday
    var startDate = Date()
    var endDate: Date?
    var destinationID: UUID?
    var output: Output = .notebook
    var template: PageTemplate = .cornell
    var paper: PaperColor = .cream
    var tint: NodeTint = .ink
    var nameFormat = "{title} {n}"
    var leadDays = 0
    var isEnabled = true
    var generated: Set<String> = []
    var cover: CoverDesign?
    var notify = true
    var notifyHour = 8
    var notifyMinute = 0

    init(title: String) { self.title = title }

    enum CodingKeys: String, CodingKey {
        case id, title, weekdays, startDate, endDate, destinationID, output, template, paper, tint
        case nameFormat, leadDays, isEnabled, generated, cover, notify, notifyHour, notifyMinute
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? [2]
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate) ?? Date()
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        destinationID = try c.decodeIfPresent(UUID.self, forKey: .destinationID)
        output = try c.decodeIfPresent(Output.self, forKey: .output) ?? .notebook
        template = try c.decodeIfPresent(PageTemplate.self, forKey: .template) ?? .cornell
        paper = try c.decodeIfPresent(PaperColor.self, forKey: .paper) ?? .cream
        tint = try c.decodeIfPresent(NodeTint.self, forKey: .tint) ?? .ink
        nameFormat = try c.decodeIfPresent(String.self, forKey: .nameFormat) ?? "{title} {n}"
        leadDays = try c.decodeIfPresent(Int.self, forKey: .leadDays) ?? 0
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        generated = try c.decodeIfPresent(Set<String>.self, forKey: .generated) ?? []
        cover = try c.decodeIfPresent(CoverDesign.self, forKey: .cover)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        notifyHour = try c.decodeIfPresent(Int.self, forKey: .notifyHour) ?? 8
        notifyMinute = try c.decodeIfPresent(Int.self, forKey: .notifyMinute) ?? 0
    }
}

struct FolderTree: Identifiable {
    let id: UUID
    let node: Node
    let children: [FolderTree]?
}

enum SortOption: String, CaseIterable, Identifiable {
    case name, modified, created
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list
    var id: String { rawValue }
}
