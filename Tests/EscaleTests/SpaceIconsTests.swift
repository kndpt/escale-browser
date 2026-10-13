// The list of Space icons only grows: a transfer file and spaces.json name
// icons, an import drops a name it doesn't know, and a new Space takes the
// first unused one. So the icons from before stay where they were, each icon
// has one name, and each draws on this Mac.
import AppKit
import Testing
@testable import Escale

struct SpaceIconsTests {
    @Test func theFirstIconsKeepTheirPlace() {
        let before = [
            "briefcase", "building.2", "desktopcomputer", "laptopcomputer", "chevron.left.forwardslash.chevron.right", "terminal",
            "sparkles", "brain.head.profile", "lightbulb", "gamecontroller", "beach.umbrella", "cup.and.saucer",
            "music.note", "film", "paintpalette", "camera", "house", "book",
            "graduationcap", "cart", "airplane", "dumbbell", "leaf", "heart",
        ]
        #expect(Array(Spaces.icons.prefix(before.count)) == before)
    }

    @Test func everyIconHasOneNameAndDraws() {
        #expect(Spaces.iconNames.count == Spaces.icons.count)
        #expect(Set(Spaces.icons).count == Spaces.icons.count)
        #expect(Set(Spaces.iconNames).count == Spaces.iconNames.count)
        // Full rows in the new-Space grid.
        #expect(Spaces.icons.count % 6 == 0)
        for icon in Spaces.icons {
            #expect(NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil, "\(icon)")
        }
    }
}
