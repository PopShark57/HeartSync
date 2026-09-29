import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Source colour separation")
@MainActor
struct SourceColourSeparationTests {
    private func source(
        _ id: String,
        slot: Int,
        enabled: Bool = true,
        added: TimeInterval = 0
    ) -> DataSource {
        DataSource(
            id: id,
            displayName: id,
            transport: .bluetooth,
            colorIndex: slot,
            isEnabled: enabled,
            addedAt: Date(timeIntervalSince1970: added)
        )
    }

    /// SplitMix64, so a draw is repeatable.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private var slotCount: Int { DataSource.paletteSlots.count }

    @Test("A new device takes a slot the fewest devices wear, never one already worn while another is free")
    func newDeviceTakesLeastUsedSlot() {
        let store = HealthStore(persistenceEnabled: false)
        for index in 0..<slotCount {
            store.upsert(DataSource(id: "s\(index)", displayName: "S\(index)", transport: .bluetooth))
        }
        #expect(Set(store.sources.map(\.colorIndex)).count == slotCount)

        // Removing a middle device frees its slot; the next device takes exactly that one.
        // The old rule (`sources.count % 6`) would have handed out slot 5, already worn.
        let freed = store.source(id: "s2")?.colorIndex
        _ = store.removeSourceResult(id: "s2")
        store.upsert(DataSource(id: "extra", displayName: "Extra", transport: .bluetooth))
        #expect(store.source(id: "extra")?.colorIndex == freed)
        #expect(Set(store.sources.map(\.colorIndex)).count == slotCount)
    }

    @Test("Colours are not handed out in the same order every time")
    func newDeviceColourIsRandom() {
        var generator = SeededGenerator(state: 1)
        let first = (0..<200).map { _ in DataSource.leastUsedColorIndex(among: [], using: &generator) }
        // Every slot turns up, in no fixed order.
        #expect(Set(first).count == slotCount)
        #expect(first != first.sorted())
        var other = SeededGenerator(state: 2)
        let second = (0..<200).map { _ in DataSource.leastUsedColorIndex(among: [], using: &other) }
        #expect(first != second)
    }

    @Test("Random choice is only among equals: a slot nobody wears always beats a worn one")
    func randomChoiceStaysWithinTheLeastUsed() {
        let worn = (0..<slotCount - 1).map { source("w\($0)", slot: $0) }
        var generator = SeededGenerator(state: 3)
        for _ in 0..<50 {
            #expect(DataSource.leastUsedColorIndex(among: worn, using: &generator) == slotCount - 1)
        }
    }

    @Test("One more device than there are slots shares exactly one slot")
    func overflowDeviceShares() {
        let store = HealthStore(persistenceEnabled: false)
        for index in 0...slotCount {
            store.upsert(DataSource(id: "s\(index)", displayName: "S\(index)", transport: .bluetooth))
        }
        let counts = Dictionary(grouping: store.sources, by: \.colorIndex).mapValues(\.count)
        #expect(counts.count == slotCount)
        #expect(counts.values.max() == 2)
    }

    @Test("Devices persisted onto the same slot are separated, and only the later one moves")
    func repairSeparatesDuplicates() {
        // Two on violet (3) and two on green (2), as a seventh-device overflow left them.
        let sources = [
            source("ring", slot: 0, added: 1),
            source("oura", slot: 3, added: 2),
            source("strap", slot: 2, added: 3),
            source("watch", slot: 3, added: 4),
            source("phone", slot: 2, added: 5),
        ]
        let repairs = DataSource.colorIndexRepairs(for: sources)
        #expect(repairs["ring"] == nil)
        #expect(repairs["oura"] == nil)
        #expect(repairs["strap"] == nil)
        #expect(repairs["watch"] != nil)
        #expect(repairs["phone"] != nil)

        var repaired = sources
        for index in repaired.indices {
            if let slot = repairs[repaired[index].id] { repaired[index].colorIndex = slot }
        }
        #expect(Set(repaired.map(\.colorIndex)).count == 5)
        #expect(DataSource.colorIndexRepairs(for: repaired).isEmpty)
    }

    @Test("A paused device gives way to enabled ones and never displaces them")
    func pausedDeviceYields() {
        let sources = [
            source("paused", slot: 1, enabled: false, added: 1),
            source("live", slot: 1, added: 2),
        ]
        let repairs = DataSource.colorIndexRepairs(for: sources)
        #expect(repairs["live"] == nil)
        #expect(repairs["paused"] != nil)
        #expect(repairs["paused"] != 1)
    }

    @Test("Out-of-range slots fold into the palette instead of trapping")
    func outOfRangeSlots() {
        let sources = [source("a", slot: 8, added: 1), source("b", slot: -1, added: 2)]
        let repairs = DataSource.colorIndexRepairs(for: sources)
        var repaired = sources
        for index in repaired.indices {
            if let slot = repairs[repaired[index].id] { repaired[index].colorIndex = slot }
        }
        let slots = repaired.map(\.colorIndex)
        #expect(slots.allSatisfy { (0..<DataSource.paletteSlots.count).contains($0) })
        #expect(Set(slots).count == 2)
    }

    @Test("Turning a paused device back on does not give it an enabled device's colour")
    func reenablingAvoidsSharedColour() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        store.upsert(DataSource(id: "b", displayName: "B", transport: .bluetooth))
        _ = store.setEnabled(false, forSource: "a")
        // A newcomer prefers a slot no enabled device wears, which may be a's.
        store.upsert(DataSource(id: "c", displayName: "C", transport: .bluetooth))
        _ = store.setEnabled(true, forSource: "a")
        let slots = store.enabledSources.map(\.colorIndex)
        #expect(Set(slots).count == slots.count)
    }
}
