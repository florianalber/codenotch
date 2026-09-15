import XCTest
@testable import Codenotch

/// Whose reading is this? Codenotch never signs in — it borrows a credential
/// another tool holds — so a ring can faithfully report an account you are not
/// thinking about. It happened: a profile that had always been a Team seat came
/// back reporting an Enterprise balance after an organisation switch elsewhere,
/// and looked entirely normal doing it.
final class AccountOnReadingTests: XCTestCase {
    private func snapshot(account: String?) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Current session", usedFraction: 0.2,
                                  resetsAt: Date(timeIntervalSince1970: 1_800_000_000))],
            headlineID: "session", account: account
        )
    }

    private func archive() -> UsageArchive {
        let name = "AccountOnReading.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UsageArchive(defaults: defaults)
    }

    /// A remembered reading is exactly when the question is hardest to answer,
    /// so the account has to survive the round trip.
    func testTheAccountSurvivesTheArchive() throws {
        let archive = archive()
        archive.save(["claude": (snapshot(account: "enterprise"), Date())])
        let restored = try XCTUnwrap(archive.load()["claude"]?.snapshot)
        XCTAssertEqual(restored.account, "enterprise")
    }

    /// Archives written before this field existed still have to decode — the
    /// alternative is every remembered reading disappearing on update.
    func testAnOlderArchiveStillLoads() throws {
        let name = "AccountOnReadingOld.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let json = """
        [{"id":"claude","displayName":"Claude","glyph":"claude","fidelity":"official",
          "windows":[{"id":"session","label":"Current session","usedFraction":0.2}],
          "fetchedAt":750000000,"headlineID":"session"}]
        """
        defaults.set(Data(json.utf8), forKey: "lastGoodReadings")

        let restored = try XCTUnwrap(UsageArchive(defaults: defaults).load()["claude"]?.snapshot)
        XCTAssertEqual(restored.windows.count, 1)
        XCTAssertNil(restored.account, "no claim where the archive never carried one")
    }

    /// A provider that says nothing about its account says nothing in the
    /// tooltip either, rather than inventing a plan for it.
    func testNoAccountMakesNoClaim() {
        XCTAssertNil(snapshot(account: nil).account)
    }
}
