/// Hover preview never participates in row layout; only an explicit pin expands inline.
struct ManagementCardExpansionState: Equatable {
    private(set) var isHovering = false
    private(set) var isPreviewHovered = false
    private(set) var isPinned = false
    private(set) var isPreviewVisible = false
    private var suppressHoverPreview = false

    var isExpanded: Bool { isPinned }
    var wantsPreview: Bool { (isHovering || isPreviewHovered) && !isPinned && !suppressHoverPreview }
    var pendingHoverTarget: Bool? {
        wantsPreview == isPreviewVisible ? nil : wantsPreview
    }

    mutating func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if !hovering { suppressHoverPreview = false }
    }

    mutating func setPreviewHovered(_ hovering: Bool) { isPreviewHovered = hovering }
    mutating func setPreviewVisible(_ visible: Bool) { isPreviewVisible = visible }

    mutating func togglePinned() {
        isPinned.toggle()
        suppressHoverPreview = !isPinned && isHovering
        isPreviewVisible = false
        isPreviewHovered = false
    }

    mutating func clearHover() {
        isHovering = false
        isPreviewHovered = false
        isPreviewVisible = false
        suppressHoverPreview = false
    }
}
