import XCTest

final class SceneEntryUITests: XCTestCase {
    struct Scene: Decodable {
        let id, title: String
        let titleEN: String?
        var name: String { titleEN ?? title }
    }

    @MainActor func testColdEntryExitAndReentry() throws {
        let catalog = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scenes", withExtension: "json"))
        let scenes = try JSONDecoder().decode([Scene].self, from: Data(contentsOf: catalog))
        let first = try XCTUnwrap(scenes.first { $0.id == "02-waterfall" } ?? scenes.first)
        let next = scenes.first { $0.id != first.id } ?? first
        let app = XCUIApplication()
        app.launchArguments = ["-displayLanguage", "en", "-selectedPhotoScene", first.id]
        app.launch()
        let interruption = addUIInterruptionMonitor(withDescription: "Tracking permission") { alert in
            for name in ["Allow", "OK", "Continue", "允许", "好"] where alert.buttons[name].exists {
                alert.buttons[name].tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(interruption) }
        func open(_ label: String) throws {
            let button = app.buttons[label].firstMatch
            guard button.waitForExistence(timeout: 20) else {
                XCTFail("Entry button missing: " + label)
                throw CocoaError(.coderValueNotFound)
            }
            button.tap()
            XCTAssertTrue(app.buttons["Exit"].waitForExistence(timeout: 20))
        }
        func expectLoaded(_ scene: Scene) {
            let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Loaded · " + scene.name + " ·")).firstMatch
            if !ready.waitForExistence(timeout: 4) { app.staticTexts["PinchDrop"].firstMatch.tap() }
            XCTAssertTrue(ready.waitForExistence(timeout: 45), app.debugDescription)
        }
        func leave() {
            app.buttons["Exit"].tap()
            XCTAssertTrue(app.buttons["Pick up from phone"].waitForExistence(timeout: 20))
        }

        try open("Preview reveal")
        expectLoaded(first)
        let distanceReadout = app.staticTexts["depth-readout"]
        let previousDistance = distanceReadout.label
        let closer = app.buttons["Move ten centimeters closer"]
        let farther = app.buttons["Move ten centimeters farther"]
        let startOnNearSide = previousDistance.hasPrefix("Closer ")
        (startOnNearSide ? farther : closer).tap()
        XCTAssertNotEqual(distanceReadout.label, previousDistance)
        (startOnNearSide ? closer : farther).tap()
        XCTAssertEqual(distanceReadout.label, previousDistance)
        leave()
        try open("Pick up from phone")
        leave() // Close as soon as the controls appear, without waiting for readiness.
        if next.id != first.id {
            app.buttons["scene-picker"].tap()
            let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", next.name)).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 8), app.debugDescription)
            choice.tap()
        }
        try open("Pick up from phone")
        // Switching the controls during startup must leave the compositor able to present.
        app.buttons["Preview reveal"].tap()
        app.buttons["Back to pickup"].tap()
        app.buttons["Preview reveal"].tap()
        expectLoaded(next)
        app.buttons["Back to pickup"].tap()
        expectLoaded(next)
        leave()
        try open("Preview reveal")
        expectLoaded(next)

        // Terminate with the space open. A new process must use a new compositor session.
        app.terminate()
        app.launch()
        try open("Preview reveal")
        expectLoaded(first)
    }
}
