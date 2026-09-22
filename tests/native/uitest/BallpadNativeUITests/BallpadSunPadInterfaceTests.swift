import XCTest
import UIKit

/// Real-touch acceptance for the vendored SunPad interface running inside the native
/// Strikers port (doc 36 R1; stages N4-C and N4-D).
///
/// The app under test is the CMake-built BallpadStrikers.app that
/// scripts/native/run-uitests.sh installs on the Simulator. It is addressed by bundle
/// identifier, so this bundle carries no target application of its own, and the only
/// input used is a real tap, drag, switch flip or slider move delivered through the
/// app's own accessibility tree. Nothing here can pass without the app consuming that
/// input, because every claim is read back from the app afterwards.
final class BallpadSunPadInterfaceTests: XCTestCase {

    private static let bundleIdentifier = "com.ballpad.strikers"

    /// The orientation every frame reading below is taken in, and the reason it is set rather than
    /// inherited from whatever the device happened to be left in.
    ///
    /// The app is landscape-only and `UIRequiresFullScreen`, but XCUITest publishes element
    /// frames in the *device's* orientation space rather than the interface's. With the device left
    /// in portrait, the accessibility server aspect-fits the app's 1180x820 window into the
    /// 820x1180 screen: measured on `uitest-pad-f06-pad-r3`, every control came back at exactly
    /// 0.6949x with a +305.1pt y offset, which is 820/1180 = 0.69492 and (1180-569.8)/2 = 305.1 --
    /// the window's own 1.439 aspect fitted into the portrait screen, centred. The app was not in
    /// that state: its own `host ui: geometry` line, copied into the run's `app-runtime.log`,
    /// reports the window, its screen and its scene all at 1180x820 with an identity transform, and
    /// the R control's conversion through all three spaces unchanged. The distorted ruler is the
    /// harness's, so the harness is where it is corrected, and no assertion is loosened to match it.
    ///
    /// What the distortion cost, which is why this is worth stating at length: read in the fitted
    /// space, the layout editor's per-control size slider topped out at 98.0% from all four of the
    /// drive's mechanisms in one run -- `adjust->98.0 edge->98.0 drag->98.0 tap->98.0` -- and that
    /// is exactly what `S.f06.size-extremes` failed on, while the panel's own slider reached 100%
    /// in the same space because its track is short and central and the error stayed inside the
    /// thumb's own inset. The same row on the same binary reads `adjust->100.0` once the device is
    /// landscape (`uitest-pad-pad-geom1`).
    private static let deviceOrientation: UIDeviceOrientation = .landscapeLeft

    /// The order the panel actually ships, which is the vendored -buildMenu order with only the
    /// changes doc 36's R1 list sanctions: the experimental performance row does not ship at all
    /// (R1 row 12), so it is absent rather than present-and-inert, and the slot it held carries
    /// Ballpad's Experimental submenu instead; that submenu is where the port's two instruments
    /// live -- the frame-rate limiter that kept the vendored row's place under Ballpad's own title
    /// (R1 row 11) and the audio recording row that took the retired row's slot (R2) -- so the
    /// vendored 60 FPS row's own slot is spent rather than duplicated; and About & Credits closes
    /// the panel as a Ballpad addition (R1 row 15). Every other row is the vendored row, untouched,
    /// in place.
    private static let vendoredMenuRows = [
        "Display",
        "Controls",
        "Experimental",
        "Game Data & Saves",
        "Report a Problem…",
        "About & Credits…",
    ]

    /// The touch-control settings surface, by its vendored accessibility labels.
    private static let vendoredSettingsControls = [
        "Render resolution",
        "Control opacity",
        "Control size",
        "Hide touch controls when controller connected",
        "Modern C-stick left and right",
        "Move touch controls",
    ]

    /// The layout editor is a separate vendored surface, not a row of the panel: enabling
    /// "Move touch controls" hides the settings panel and raises this bar instead. Its size
    /// slider is the control whose label the vendored code rewrites to "<control> size" once a
    /// control is tapped, so the resting form is only observable before a selection.
    private static let vendoredEditorControls = [
        "Drag controls • tap one to resize",
        "Selected control size",
        "Hide selected control",
        "Finish moving touch controls",
    ]

    private static let renderScaleSegments = ["1×", "2×", "3×", "4×"]

    /// The overlay's whole control set, by the labels SunPad publishes, for the rotation row: the
    /// claim there is that the turn leaves every one of them drawn and hittable, so the list is the
    /// set the overlay draws rather than a sample of it.
    private static let rotationControls = [
        "move", "c", "D_U", "D_D", "D_L", "D_R", "A", "B", "X", "Y", "Z", "Start", "L", "R",
    ]

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Before the launch rather than after it: the app comes up into whatever orientation the
        // device is already in, so establishing it here is what keeps every row's frames in the
        // interface's own space instead of the device's. See -deviceOrientation for the measurement.
        XCUIDevice.shared.orientation = Self.deviceOrientation
        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
    }

	/// The engine needs its disc image and a writable user/cache directory. The wrapper
	/// script passes them as build settings, which Xcode expands into this bundle's
	/// Info.plist: xcodebuild does not forward command-line build settings into the test
	/// runner's own environment, so the plist is the channel that actually carries them.
	/// An inherited environment of the same name still wins, so a manual run can override.
	private static func launchEnvironment() -> [String: String] {
		let host = ProcessInfo.processInfo.environment
		let bundled = Bundle(for: BallpadSunPadInterfaceTests.self)
		func path(_ hostKey: String, _ infoKey: String) -> String? {
			if let value = host[hostKey], !value.isEmpty { return value }
			guard let value = bundled.object(forInfoDictionaryKey: infoKey) as? String,
			      !value.isEmpty, !value.hasPrefix("$(") else { return nil }
			return value
		}
		// The scene log names the front end's own scene, and the consumption log is the F04 row's
		// reading: what the *engine's* pad held while the overlay drew a control. Both are the port's
		// STRIKERS_LOG_* convention and both are off unless asked for, because the frame loop is not
		// a place to write a line a frame.
		var env: [String: String] = ["STRIKERS_LOG_SCENES": "1", "STRIKERS_LOG_CONSUME": "1",
		                             "STRIKERS_SEED": "12345"]
		if let iso = path("BALLPAD_UITEST_ISO", "BallpadUITestDiscImage") { env["STRIKERS_DATA"] = iso }
		if let user = path("BALLPAD_UITEST_USER_DIR", "BallpadUITestUserDir") {
			env["STRIKERS_USER_DIR"] = user
		}
		if let cache = path("BALLPAD_UITEST_CACHE_DIR", "BallpadUITestCacheDir") {
			env["STRIKERS_CACHE_DIR"] = cache
		}
		return env
	}

    // MARK: - Harness helpers

    private var menuButton: XCUIElement { app.buttons["Menu"] }

    private func attach(_ name: String) {
        let image = XCUIScreen.main.screenshot().image
        let upright = Self.bakedUpright(image)
        let attachment = XCTAttachment(image: upright)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // The fix is only checkable from the bundle if its input is recorded, so the screenshot's
        // own geometry lands beside the image rather than staying in an annotator's head.
        attachNote(name + "-orientation",
                   "source \(Int(image.size.width))x\(Int(image.size.height)) @\(image.scale)x "
                   + "orientation \(Self.orientationName(image.imageOrientation)) -> "
                   + "baked \(Int(upright.size.width))x\(Int(upright.size.height)) as \(name).png")
    }

    /// The app's screenshot, re-rendered so that its own orientation is baked into the pixels.
    ///
    /// `XCTAttachment(screenshot:)` keeps the screenshot's `imageOrientation` on the image and does
    /// not carry it into the exported PNG, so on a landscape device the file a reader gets is a
    /// rotated buffer. Measured on the iPad bundle `uitest-pad-pad-f06d`: the three F06 attachments
    /// only read after an external 90 degree rotation, and after it they are a portrait canvas
    /// holding an off-centre region. Doc 34 asks for the F06 screenshots to be visually inspected in
    /// their actual orientation, so the rotation belongs in the pixels here rather than in the
    /// reader's head, and the same fix makes every other row's screenshots readable.
    ///
    /// The canvas has to be the *display* size, not `image.size`: a screenshot of a landscape
    /// interface is a portrait pixel buffer carrying a rotation, and UIKit reports `size` as that
    /// raw buffer -- measured here as `820x1180 @2.0x orientation left` on the iPad. Drawing it into
    /// a canvas of its own raw size is what produced the portrait, off-centre frames, so the axes
    /// are swapped for the four quarter-turn orientations. `UIImage.draw(in:)` applies the
    /// orientation itself, so the aspect ratios then agree and the fit is exact.
    private static func bakedUpright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        // UIImage.size already reflects the screenshot orientation. Swapping it
        // again stretches a landscape capture into a portrait canvas.
        let size = image.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The size the image occupies once its orientation is honoured: a quarter-turn orientation
    /// swaps the axes, and the upright ones leave them alone.
    private static func displaySize(of image: UIImage) -> CGSize {
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: image.size.height, height: image.size.width)
        default:
            return image.size
        }
    }

    private static func orientationName(_ orientation: UIImage.Orientation) -> String {
        switch orientation {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .upMirrored: return "upMirrored"
        case .downMirrored: return "downMirrored"
        case .leftMirrored: return "leftMirrored"
        case .rightMirrored: return "rightMirrored"
        @unknown default: return "unknown(\(orientation.rawValue))"
        }
    }

    private func attachNote(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

	/// The element tree exactly as the runner saw it, kept as text next to the screenshot.
	/// A row that is missing from a claim needs the interface's own published hierarchy as
	/// evidence, because "not in the tree" and "below the fold" look identical from a
	/// boolean existence check and lead to opposite conclusions.
	private func attachHierarchy(_ name: String) {
		let attachment = XCTAttachment(string: app.debugDescription)
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}

    /// Launches the app and waits for the host overlay. A missing three-dot button after a
    /// generous bounded wait is a real failure: it means the overlay never reached the screen.
    ///
    /// `extraEnvironment` is the caller's own additions on top of the shared launch environment, and
    /// it exists for the one row that has to launch the app the way a pad-producing run does -- the
    /// F12 scripted controller and its per-frame log. It is additive on purpose: the disc, the
    /// writable directories and the log gates every other row relies on stay exactly as they are.
    private func launchAndWaitForOverlay(timeout: TimeInterval = 240,
                                         extraEnvironment: [String: String] = [:]) {
        // The interface rows judge the overlay over a running game, so they hand the engine the
        // disc and the writable directories they were built with. F01/F03's import rows are the
        // opposite case and launch without them, which is why this is here and not in setUp.
        var environment = Self.launchEnvironment()
        environment.merge(extraEnvironment) { _, addition in addition }
        app.launchEnvironment = environment
        app.launch()
        XCTAssertTrue(menuButton.waitForExistence(timeout: timeout),
                      "the SunPad three-dot menu button is on screen")
        waitForTheFrameSpaceToBeTheAppsOwn()
    }

    /// The display's long side in points, measured once from a screenshot rather than assumed from a
    /// device name: the check below has no device-specific number in it, and this is the number that
    /// makes that possible.
    private static let displayLongSide: CGFloat = {
        let display = XCUIScreen.main.screenshot().image.size
        return max(display.width, display.height)
    }()

    /// Waits until the frames the rows below will read are in the app's own coordinate space, and
    /// fails naming both sides if they never are.
    ///
    /// The app is landscape-only and full-screen, so its window is the whole display and the window's
    /// width is the display's *long* side. That is the whole check, and it is exact in both directions:
    /// in the interface's own space the width is the long side, and in the fitted space described at
    /// -deviceOrientation it is the short one -- 820 where the display is 1180. The display's own size
    /// is read from a screenshot so the check carries no device constant, and the screenshot is taken
    /// the way -attach takes one: a landscape interface on the iPad arrives as a portrait buffer
    /// carrying a rotation, so the long side is the maximum of the two and not the width.
    ///
    /// It is a wait rather than a single read because the orientation set in -setUpWithError is
    /// applied to a device that may not have finished turning, and a frame read across that turn would
    /// be a frame from the wrong space -- which is the fault this whole helper exists to keep from
    /// being reported as a mis-placed control. A launch that never arrives is failed here with the
    /// hierarchy it judged and both numbers.
    private func waitForTheFrameSpaceToBeTheAppsOwn(timeout: TimeInterval = 20) {
        let longSide = Self.displayLongSide
        let deadline = Date().addingTimeInterval(timeout)
        var window = app.windows.firstMatch.frame
        repeat {
            if app.windows.firstMatch.exists {
                window = app.windows.firstMatch.frame
                if abs(window.width - longSide) <= 1.0 {
                    attachNote("frame-space",
                               "device " + Self.orientationName(of: Self.deviceOrientation)
                               + "; window " + NSCoder.string(for: window)
                               + "; display long side " + String(format: "%.1f", longSide)
                               + " -- in the interface's own space, so the frames below are read "
                               + "where the app lays out. The app's own window bounds are the "
                               + "host ui: geometry line in app-runtime.log.")
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        attachHierarchy("frame-space-is-not-the-apps-own")
        XCTFail("the interface's frames are read in the app's own coordinate space: the window is "
                + NSCoder.string(for: window) + " where this landscape-only full-screen app's window "
                + "width is the display's long side, " + String(format: "%.1f", longSide)
                + " -- a window narrower than that is the accessibility server fitting the "
                + "interface into the device's orientation rather than the app laying it out there")
    }

    /// A UIDeviceOrientation as the word the run's notes should carry, for the same reason the
    /// screenshot orientation is named rather than numbered: a reader of the bundle should not have
    /// to hold the enum's raw values in their head to read which side the device was on.
    private static func orientationName(of orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        default: return "unknown(\\(orientation.rawValue))"
        }
    }

    /// The vendored menu mounts through UIKit's menu machinery, so a row is not guaranteed
    /// to land in one particular element collection. The label is the claim, so any honest
    /// query type that carries it is accepted.
    private func overlayElement(_ label: String) -> XCUIElement? {
        let candidates = [app.buttons[label], app.cells[label], app.staticTexts[label],
                          app.menuItems[label], app.otherElements[label],
                          app.switches[label], app.sliders[label], app.segmentedControls[label]]
        for candidate in candidates where candidate.exists { return candidate }
        return nil
    }

    @discardableResult
    private func waitForOverlayElement(_ label: String, timeout: TimeInterval = 20) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = overlayElement(label) { return element }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    private func openMenu() {
        XCTAssertTrue(menuButton.waitForExistence(timeout: 30), "the three-dot menu button")
        menuButton.tap()
        XCTAssertNotNil(waitForOverlayElement(Self.vendoredMenuRows[0], timeout: 30),
                        "tapping the three-dot button opens the vendored menu")
    }

	/// The vendored menu is a UIKit `UIMenu`, so iOS owns its presentation and the two form
	/// factors differ in a way that is not the overlay's doing. At the iPad's regular height the
	/// whole nine-row list fits in the panel and every row is published at once. On the iPhone
	/// the same list is taller than the panel iOS grants it (322 pt of a 390 pt screen), so it is
	/// a two-page collection view and the cells past the fold are not in the accessibility tree
	/// until they are scrolled into it -- measured, not assumed: the phone run's captured tree
	/// carries "Vertical scroll bar, 2 pages" and stops after the fifth row. The rows themselves
	/// are the vendored ones in either case; only the reading needs a scroll.
	@discardableResult
	private func scrollMenuDown() -> Bool {
		let panel = app.collectionViews.firstMatch
		guard panel.exists else { return false }
		panel.swipeUp()
		return true
	}

	/// Looks for `label`, scrolling the open menu when it is not published yet. Bounded on
	/// purpose: a row that is genuinely absent from the menu still fails rather than scrolling
	/// forever, and the bounded scroll is what the phone form factor needs.
	@discardableResult
	private func scrollMenuForElement(_ label: String, maxScrolls: Int = 6,
	                                  timeout: TimeInterval = 5) -> XCUIElement? {
		for pass in 0...maxScrolls {
			if let element = waitForOverlayElement(label, timeout: timeout) { return element }
			if pass == maxScrolls { break }
			guard scrollMenuDown() else { break }
		}
		return nil
	}

    private func openTouchSettings() {
        if let controls = overlayElement("Controls") { controls.tap() }
        guard let row = scrollMenuForElement("Touch Control Settings…", timeout: 30) else {
            XCTFail("the Touch Control Settings row is present in the menu")
            return
        }
        row.tap()
        XCTAssertNotNil(waitForOverlayElement("Render resolution", timeout: 30),
                        "the touch control settings panel opens")
    }

    private func renderScaleSegment(_ title: String) -> XCUIElement {
        app.segmentedControls["Render resolution"].buttons[title]
    }

    private func selectedRenderScaleTitle() -> String? {
        for title in Self.renderScaleSegments {
            let segment = renderScaleSegment(title)
            if segment.exists && segment.isSelected { return title }
        }
        return nil
    }

    /// The port's own display read-back, parsed out of the FPS counter's text. The counter is
    /// Ballpad's label (the vendored component has none of its own) and its first field is
    /// `WxH @scale aspect value window|pinned logical N blend T`, built from the same port accessors
    /// the display bridge writes through; the frame statistics follow it after a separator, so only
    /// the first field is read here. Parsing rather than comparing the string verbatim is what lets a
    /// row compare two readings: the numbers move with the window, and the claims below are about
    /// their relations.
    private struct DisplayReadBack: CustomStringConvertible {
        var width: Int
        var height: Int
        var scale: Double
        var aspect: Double
        var followsWindow: Bool
        /// The width of the game's own logical frame, straight from the port: the coordinate space its
        /// viewport, scissor and 2D projections are set from, and the field that says an aspect change
        /// actually reached the renderer. The target above is scaled to the *window*, so it reads the
        /// same at every aspect and cannot answer that question -- which is why it is not asked.
        var logicalWidth: Int
        /// How far the gameplay camera has been carried from its 4:3 tuning toward its widescreen one:
        /// 0 at 4:3, 1 at 16:9, and continuing linearly past it on a window wider than 16:9.
        var blend: Double

        /// The shape of the target the port presents into, derived rather than reported. It is the
        /// surface's shape at the render scale, so the claim this is here for is that the aspect rows
        /// leave it alone rather than that it matches the shape they pin.
        var renderedAspect: Double { height > 0 ? Double(width) / Double(height) : 0 }

        var description: String {
            "\(width)x\(height) @\(scale)x aspect \(aspect) \(followsWindow ? "window" : "pinned")"
                + " logical \(logicalWidth) blend \(blend)"
        }
    }

    private func displayReadBack() -> DisplayReadBack? {
        guard let element = identifierElement("BallpadFPSCounter") else { return nil }
        // The value, falling back to the label. The card drew the whole reading until build 2
        // reduced it to the rate, which left this helper parsing "60 fps" and the row failing on
        // every build since; the reading is published as the card's accessibility value now, where
        // it does not change what the card draws or what VoiceOver announces.
        let text = (element.value as? String) ?? element.label
        let pattern = #"(\d+)x(\d+) @([0-9.]+)x aspect ([0-9.]+) (window|pinned) logical (\d+) blend ([0-9.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let width = group(1).flatMap(Int.init),
              let height = group(2).flatMap(Int.init),
              let scale = group(3).flatMap(Double.init),
              let aspect = group(4).flatMap(Double.init),
              let marker = group(5),
              let logicalWidth = group(6).flatMap(Int.init),
              let blend = group(7).flatMap(Double.init)
        else { return nil }
        return DisplayReadBack(width: width, height: height, scale: scale, aspect: aspect,
                               followsWindow: marker == "window", logicalWidth: logicalWidth,
                               blend: blend)
    }

    /// Waits for a reading that satisfies `predicate`, because the counter is refreshed once a frame
    /// and a pin applied by a menu row lands on the frame after the tap. A reading that never
    /// arrives fails the row and attaches the tree, so a mismatch is diagnosable from the bundle.
    @discardableResult
    private func waitForDisplay(_ what: String, timeout: TimeInterval = 20,
                                where predicate: (DisplayReadBack) -> Bool) -> DisplayReadBack? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: DisplayReadBack?
        repeat {
            if let reading = displayReadBack() {
                last = reading
                if predicate(reading) { return reading }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        attachHierarchy("display-readback-missing-" + what)
        XCTFail("the port's display read-back did not reach " + what + "; last reading: "
                + (last.map { String(describing: $0) } ?? "none"))
        return nil
    }

    /// Opens the menu when it is not already open. Tapping the three-dot button while the menu is up
    /// dismisses it, so the state is read first -- the first page's own headings are the answer -- and
    /// the loop is bounded: the one case that needs a second tap is a menu left open with a submenu in
    /// front of it, where the first tap closes everything.
    private func ensureMenuOpen() {
        for _ in 0..<3 {
            if overlayElement("Display") != nil { return }
            menuButton.tap()
            if waitForOverlayElement("Display", timeout: 15) != nil { return }
        }
        attachHierarchy("menu-would-not-open")
        XCTFail("the three-dot menu opens")
    }

    /// One top-level row, opened and tapped by label. A missed tap is a missing row rather than a
    /// failure somewhere further down.
    private func tapMenuRow(_ row: String) {
        ensureMenuOpen()
        if ["Render Resolution", "Aspect Ratio", "Show FPS Counter"].contains(row) {
            overlayElement("Display")?.tap()
        } else if ["Touch Control Settings…", "Controller Button Mapping…"].contains(row) {
            overlayElement("Controls")?.tap()
        }
        guard let element = scrollMenuForElement(row, timeout: 20) else {
            attachHierarchy("missing-menu-row")
            XCTFail("the " + row + " row is in the menu")
            return
        }
        element.tap()
    }

    /// One leaf row, reached through the submenu that holds it. The submenu is opened by the same
    /// label-addressed tap, so the whole walk is the player's own walk.
    private func chooseMenuRow(_ row: String, from submenu: String) {
        tapMenuRow(submenu)
        guard let leaf = scrollMenuForElement(row, timeout: 20) else {
            attachHierarchy("missing-submenu-row")
            XCTFail("the " + row + " row is in the " + submenu + " submenu")
            return
        }
        leaf.tap()
    }

    /// The FPS counter's setting, which the display read-back is carried by. It is a toggle rather
    /// than a switch, so "on" is read back from the label itself and a tap that did not land is
    /// retried once -- the same idiom the layout row uses for a switch XCUITest had to scroll to.
    private func setFPSCounter(_ on: Bool) {
        for _ in 0..<2 {
            if (identifierElement("BallpadFPSCounter") != nil) == on { return }
            tapMenuRow("Show FPS Counter")
            let deadline = Date().addingTimeInterval(12)
            repeat {
                if (identifierElement("BallpadFPSCounter") != nil) == on { return }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline
        }
        XCTFail("the Show FPS Counter row turns the counter " + (on ? "on" : "off"))
    }

    /// The vendored layout reset, driven through the settings panel and its confirmation alert.
    ///
    /// Every row in this suite that changes the layout persists what it changed: the panel's size
    /// scale, the per-control sizes and the placements all live in NSUserDefaults and survive a
    /// relaunch, which is exactly what the persistence rows assert. A row whose claim is about the
    /// *layout* rather than about persistence therefore has to establish the default it is judging,
    /// or it inherits whatever its neighbour left behind, and the row then reports a property of the
    /// previous row's state as though the app had produced it during this one.
    ///
    /// That is measured rather than hypothetical. In run uitest-phone-r1-audit-phone-1 the rotation
    /// row inherited a per-control size of 1.73 for Z from the rows before it; at that size the
    /// containment clamp raises A until it covers X's centre, and the row's hittability claim failed
    /// on a tree the turn had not touched -- the before and after hierarchies are identical. The
    /// reset is what makes the claim be about the turn.
    private func resetTouchControlLayout() {
        openMenu()
        openTouchSettings()
        let reset = app.buttons["Reset This Device Layout"]
        guard reset.waitForExistence(timeout: 15) else {
            attachHierarchy("reset-button-missing")
            XCTFail("the vendored reset button is on the settings panel")
            return
        }
        reset.tap()
        let alert = app.alerts["Reset Touch Control Layout?"]
        guard alert.waitForExistence(timeout: 10) else {
            attachHierarchy("reset-alert-missing")
            XCTFail("the vendored reset asks for confirmation before it clears the layout")
            return
        }
        alert.buttons["Reset"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 5), "Reset dismisses the alert")
        // The reset leaves the panel up, and the menu button *toggles* it, so a row that went on to
        // tap the menu button would close the panel instead of opening the menu. The panel's own
        // close button is the way back to the overlay.
        let close = app.buttons["Close touch control settings"]
        if close.waitForExistence(timeout: 10) { close.tap() }
        waitForTheControlSetToSettle()
    }

    private func framesDiffer(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
    }

    private func assertFrameClose(_ actual: CGRect, _ expected: CGRect,
                                  accuracy: CGFloat = 3, _ what: String) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, what + " x")
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, what + " y")
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, what + " width")
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, what + " height")
    }

    private func overlayATitle() -> XCUIElement { app.buttons["A"] }

    // MARK: - The three-dot menu

    func testThreeDotMenuAdoptsTheVendoredRowsInOrder() throws {
        launchAndWaitForOverlay()
        openMenu()

		attachHierarchy("menu-hierarchy-top")
		attach("menu-open")

		// R1 row 12: the experimental performance row does not ship at all. "Show FPS Counter"
		// and the frame-rate row are both on this first page, so the vendored row that sat
		// between them being absent here is a real reading rather than an off-screen artefact.
		XCTAssertNil(overlayElement("Experimental Performance Mode (Restart Required)"),
		             "the experimental performance row is not shipped (R1 row 12)")

		// Walk the menu one panel-page at a time. A sighting is the first pass in which a row is
		// published, together with where it sat; the walking order is what the order claim is
		// read from, so a row that only appears after a scroll still has to appear in its place.
		var sightings: [(row: String, minY: CGFloat)] = []
		var seen = Set<String>()
		for pass in 0...6 {
			var onScreen: [(row: String, minY: CGFloat)] = []
			for row in Self.vendoredMenuRows where !seen.contains(row) {
				guard let element = waitForOverlayElement(row, timeout: 5) else { continue }
				seen.insert(row)
				sightings.append((row, element.frame.minY))
				onScreen.append((row, element.frame.minY))
			}
			XCTAssertEqual(onScreen.map(\.minY), onScreen.map(\.minY).sorted(),
			               "rows visible together keep their vendored vertical order (pass \(pass))")
			if seen.count == Self.vendoredMenuRows.count { break }
			if pass == 6 { break }
			guard scrollMenuDown() else { break }
		}

		let missing = Self.vendoredMenuRows.filter { !seen.contains($0) }
		XCTAssertTrue(missing.isEmpty, "every vendored row is reachable in the menu; missing: "
			+ missing.joined(separator: ", "))
		XCTAssertEqual(sightings.map(\.row), Self.vendoredMenuRows,
		               "the rows are first sighted in the vendored order")
		attachHierarchy("menu-hierarchy-walked")
		attach("menu-open-after-walk")
    }

    // MARK: - The touch control settings surface

    func testTouchSettingsPanelExposesTheVendoredControls() throws {
        launchAndWaitForOverlay()
        openMenu()
        openTouchSettings()

        for control in Self.vendoredSettingsControls {
            XCTAssertNotNil(waitForOverlayElement(control, timeout: 5),
                            "settings control present: " + control)
        }
        XCTAssertTrue(app.buttons["Reset This Device Layout"].waitForExistence(timeout: 5),
                      "the layout reset button is present")
        XCTAssertTrue(app.buttons["Close touch control settings"].exists,
                      "the panel close button is present")
        attach("touch-settings-panel")
		attachHierarchy("touch-settings-panel-hierarchy")

        // The layout editor, reached the way the vendored code reaches it: the switch is
        // flipped through the UI and the bar it raises has to answer for itself.
        let moveSwitch = app.switches["Move touch controls"]
        XCTAssertTrue(moveSwitch.waitForExistence(timeout: 10), "the Move touch controls switch")
        if (moveSwitch.value as? String) != "1" { moveSwitch.tap() }

        for control in Self.vendoredEditorControls {
            XCTAssertNotNil(waitForOverlayElement(control, timeout: 10),
                            "layout editor control present: " + control)
        }
        XCTAssertNil(waitForOverlayElement("Render resolution", timeout: 3),
                     "raising the layout editor hides the settings panel")
        attach("layout-editor")

        // Hiding a control, which is the other half of "hide and rearrange": the vendored editor
        // moves a control with its pan and resizes it with its slider, and has no answer at all for
        // taking one out of the picture -- its one visibility switch is global and belongs to the
        // controller. So Ballpad adds one row to the editor's own bar, beside the size slider and
        // Done, and it acts on whichever control the editor has selected.
        //
        // The selection is made the way a player makes it -- a tap on the control, which is what both
        // of the vendored edit gestures route through -- and the row is read back through its own
        // accessibility value, which is the state the tap acts on rather than the title it draws.
        let hideRow = app.buttons["Hide selected control"]
        XCTAssertTrue(hideRow.waitForExistence(timeout: 10), "the editor's hide row is up with the bar")
        XCTAssertEqual(hideRow.value as? String, "none",
                       "the hide row waits for a selection before it acts on one")

        let hiddenControl = overlayATitle()
        XCTAssertTrue(hiddenControl.waitForExistence(timeout: 10), "the overlay's A button")
        hiddenControl.tap()
        // Self-healing rather than assumed: this row ends with the control it hid shown again, so a
        // state left behind by an interrupted earlier pass is cleared here instead of cascading into
        // every row after this one, which needs the A button to press.
        if (hideRow.value as? String) == "hidden" { hideRow.tap() }
        XCTAssertEqual(hideRow.value as? String, "shown",
                       "tapping a control in the editor selects it, which is what the hide row acts on")
        XCTAssertNotNil(waitForOverlayElement("A size", timeout: 5),
                        "the vendored editor names the control it has selected")

        hideRow.tap()
        XCTAssertEqual(hideRow.value as? String, "hidden",
                       "pressing the row hides the control the editor has selected")
        XCTAssertNotNil(waitForOverlayElement("A", timeout: 5),
                        "a hidden control stays drawn while the editor is up, so it can be selected again")
        attach("layout-editor-control-hidden")

        // Done ends editing without reopening the panel, so the panel is expected to stay
        // down until the menu button raises it again -- and the control the row just hid is expected
        // to be gone from the surface, which is the half the drawn tree can decide and no stored
        // value can.
        app.buttons["Finish moving touch controls"].tap()
        XCTAssertNil(waitForOverlayElement("Selected control size", timeout: 5),
                     "finishing the layout editor takes its bar away")
        XCTAssertNil(waitForOverlayElement("Render resolution", timeout: 3),
                     "the vendored Done button leaves the settings panel hidden")
        XCTAssertNil(waitForOverlayElement("A", timeout: 5),
                     "the control the row hid is gone from the overlay once editing ends")
        openMenu()
        openTouchSettings()
        XCTAssertNotNil(waitForOverlayElement("Render resolution", timeout: 15),
                        "the settings panel opens again once editing has ended")

        // And back, through the state the control was left in rather than a fresh one: the hidden
        // control is the one the editor must still be able to select, which is why a hidden control
        // is drawn faint and stays hittable while the bar is up instead of disappearing with the
        // picture. The row is left as this test found it, for the reason above.
        let backSwitch = app.switches["Move touch controls"]
        XCTAssertTrue(backSwitch.waitForExistence(timeout: 10), "the Move touch controls switch")
        if (backSwitch.value as? String) != "1" { backSwitch.tap() }
        if !app.buttons["Finish moving touch controls"].waitForExistence(timeout: 12) {
            attachHierarchy("editor-reopen-after-first-tap")
            if backSwitch.exists && backSwitch.isHittable { backSwitch.tap() }
        }
        XCTAssertTrue(app.buttons["Finish moving touch controls"].waitForExistence(timeout: 20),
                      "the editor comes back up over the control it hid")
        attachHierarchy("editor-reopened-over-a-hidden-control")
        overlayATitle().tap()
        XCTAssertEqual(hideRow.value as? String, "hidden",
                       "the reopened editor reads the control as hidden, which is what its row acts on")
        hideRow.tap()
        XCTAssertEqual(hideRow.value as? String, "shown", "the row shows the control again")
        app.buttons["Finish moving touch controls"].tap()
        XCTAssertNotNil(waitForOverlayElement("A", timeout: 10),
                        "the control the row showed again is drawn on the overlay")
        attach("control-shown-again")
    }

    // MARK: - Settings persistence

    func testRenderScaleSelectionPersistsAcrossRelaunch() throws {
        launchAndWaitForOverlay()
        openMenu()
        openTouchSettings()

        let existing = selectedRenderScaleTitle()
        let target = existing == "3×" ? "2×" : "3×"
        renderScaleSegment(target).tap()
        XCTAssertEqual(selectedRenderScaleTitle(), target,
                       "the tap selected render scale " + target)

        // A fresh process reading the same domain is the only honest persistence proof:
        // in-process state cannot survive app.terminate().
        app.terminate()
        launchAndWaitForOverlay()
        openMenu()
        openTouchSettings()
        XCTAssertEqual(selectedRenderScaleTitle(), target,
                       "render scale " + target + " survived a termination and a fresh launch")
        attach("render-scale-after-relaunch")
    }

    // MARK: - Layout editing and layout reset

    func testMovedControlPersistsAndResetRestoresTheDefault() throws {
        launchAndWaitForOverlay()
        openMenu()
        openTouchSettings()

        let aButton = overlayATitle()
        XCTAssertTrue(aButton.waitForExistence(timeout: 30), "the overlay A button is on screen")
        let defaultFrame = aButton.frame

        // SunPad installs its edit gestures disabled and enables them from the panel's own
        // "Move touch controls" switch, so the switch is flipped first, through the UI.
        let moveSwitch = app.switches["Move touch controls"]
        XCTAssertTrue(moveSwitch.waitForExistence(timeout: 10), "the Move touch controls switch")
        if (moveSwitch.value as? String) != "1" { moveSwitch.tap() }
        // Turning the switch on hides the settings panel, so once the editor is up the switch is
        // gone from the tree and can no longer be read back. That makes the panel's own state the
        // read-back: if it is still up, the tap did not land -- which is what a first run of this
        // row measured, on a switch XCUITest had to scroll into view first. One retry distinguishes
        // a consumed tap from a missed one instead of reporting the second as a broken editor.
        if !app.buttons["Finish moving touch controls"].waitForExistence(timeout: 12) {
            attachHierarchy("move-controls-after-first-tap")
            // Only a switch the panel is still showing can be a missed tap: once editing is on the
            // panel is hidden, and re-tapping the switch in that state would turn editing back off.
            if moveSwitch.exists && moveSwitch.isHittable {
                moveSwitch.tap()
            }
        }
        attachHierarchy("move-controls-editor")
        XCTAssertTrue(app.buttons["Finish moving touch controls"].waitForExistence(timeout: 30),
                      "the layout editor bar appears once moving is on")

        let start = aButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: -110, dy: -150)))
        let movedFrame = overlayATitle().frame
        XCTAssertTrue(framesDiffer(movedFrame, defaultFrame),
                      "the drag moved the A button (default " + String(describing: defaultFrame)
                      + ", moved " + String(describing: movedFrame) + ")")
        attach("a-button-moved")

        app.buttons["Finish moving touch controls"].tap()
        XCTAssertFalse(app.buttons["Finish moving touch controls"].exists,
                       "finishing editing leaves the layout editor")

        // The normalized origin is written to the settings domain, so it must survive a
        // relaunch, and the panel must show it back.
        app.terminate()
        launchAndWaitForOverlay()
        let relaunchedFrame = overlayATitle().frame
        assertFrameClose(relaunchedFrame, movedFrame, "the moved A button after relaunch")

        // Now the reset, through the alert the vendored code raises.
        openMenu()
        openTouchSettings()
        let resetButton = app.buttons["Reset This Device Layout"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 10), "the reset button")
        resetButton.tap()
        let alert = app.alerts["Reset Touch Control Layout?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the reset confirmation alert")
        XCTAssertTrue(alert.buttons["Cancel"].exists, "the alert offers Cancel")
        XCTAssertTrue(alert.buttons["Reset"].exists, "the alert offers Reset")
        attach("reset-alert")
        alert.buttons["Reset"].tap()

        XCTAssertFalse(alert.waitForExistence(timeout: 3), "Reset dismisses the alert")
        assertFrameClose(overlayATitle().frame, defaultFrame, "the A button back at its default")

        app.terminate()
        launchAndWaitForOverlay()
        assertFrameClose(overlayATitle().frame, defaultFrame,
                         "the reset layout survived a relaunch")
        attach("a-button-after-reset")
    }

    // MARK: - The planted stick zone (KartPad's shape)

    /// The analog stick stops being a target the size of its own face, which is the shape KartPad
    /// uses: a thumb that comes down in the area around a stick picks the stick up, the stick moves
    /// under the thumb, and the value is read from how far the thumb has travelled since it landed
    /// rather than from where it landed. That is the accuracy half -- a thumb knows its own
    /// displacement far better than it knows a circle it cannot see.
    ///
    /// What this row decides is the half a test process can honestly see, and it is the half that
    /// would be a defect if the plant leaked. The touch is *taken* by the zone rather than falling
    /// through to nothing, the stick is drawn back where the layout put it once the thumb lifts, and
    /// the plant is transient: a fresh process still draws the stick at its default frame, so nothing
    /// about a landing reached the layout store that the move-and-reset row reads.
    ///
    /// The other half is the app's own read-back, which is where a claim about a held touch belongs:
    /// the run's `planted zone:` family is the geometry the zone was drawn at and `plant:` is what a
    /// landing did with it, including the reading the plant started from. Neither is visible to a
    /// test process -- a synthetic touch is held for the duration of one blocking call, so there is
    /// no moment at which a query could read a stick mid-plant -- so the run script requires both
    /// rather than this row pretending to.
    func testTouchInTheRingAroundTheMainStickPlantsItAndLeavesNoLayout() throws {
        launchAndWaitForOverlay()

        let stick = app.otherElements["move"]
        guard stick.waitForExistence(timeout: 30) else {
            attachHierarchy("planted-zone-stick-missing")
            XCTFail("the overlay's main stick is on screen to be planted")
            return
        }
        let resting = stick.frame

        // A real touch in the ring around the stick rather than on the stick: 15% of the face above
        // its top edge, which is inside the ring -- whose margin is 30% of the face on every edge --
        // and the same distance clear of the ring's own edge, so the landing cannot be on the wrong
        // one of the two. A vector's y component is measured from the element's origin like its x,
        // so 15% above the top edge is -0.15 and not -(1 + 0.15): the latter lands 65% of a face
        // clear of the stick, which is outside the ring entirely and plants nothing. The drag that
        // follows is the travel the value is read from, and both holds are long enough for the
        // port's per-frame poll to see them rather than only the frames around a tap.
        let plant = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.15))
        plant.press(forDuration: 0.4, thenDragTo: plant.withOffset(CGVector(dx: 100, dy: 0)),
                    withVelocity: .default, thenHoldForDuration: 1.5)
        attach("planted-from-the-ring")

        // The stick comes back when the thumb lifts. The vendored pass re-places every control from
        // the stored normalized origin and the plant is not a stored origin, so the two agree.
        assertFrameClose(stick.frame, resting, "the main stick back at its layout position")

        app.terminate()
        launchAndWaitForOverlay()
        assertFrameClose(app.otherElements["move"].frame, resting,
                         "the main stick after a relaunch")
    }

    func testFloatingMovementAndGroupedMenus() throws {
        launchAndWaitForOverlay()
        let area = app.otherElements["MovementTouchArea"]
        XCTAssertTrue(area.waitForExistence(timeout: 30))
        XCTAssertFalse(app.otherElements["move"].exists, "movement artwork is invisible at rest")
        let left = app.buttons["L"]
        XCTAssertTrue(left.exists)
        XCTAssertGreaterThan(left.frame.midY, app.frame.height * 0.45)
        XCTAssertLessThan(left.frame.midY, app.frame.height * 0.80)
        let right = app.buttons["R"]
        XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 2)
        attach("floating-idle-and-shoulders")
        // Land close to the screen edge: this previously displaced the origin and
        // jumped on the first move. The app log records the actual plant and release.
        let origin = area.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.82))
                         .withOffset(CGVector(dx: 4, dy: 0))
        origin.press(forDuration: 0.3,
                     thenDragTo: origin.withOffset(CGVector(dx: 45, dy: -20)),
                     withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertEqual(area.value as? String, "idle")
        XCTAssertFalse(app.otherElements["move"].exists)
        attach("floating-released")
        openMenu()
        XCTAssertNotNil(overlayElement("Controls"))
        XCTAssertNil(overlayElement("Render Resolution"))
        overlayElement("Display")?.tap()
        XCTAssertNotNil(waitForOverlayElement("Render Resolution", timeout: 10))
        XCTAssertNotNil(overlayElement("Aspect Ratio"))
        XCTAssertNotNil(overlayElement("Show FPS Counter"))
        attach("display-submenu")
        ensureMenuOpen()
        openTouchSettings()
        XCTAssertTrue(app.sliders["Control opacity"].exists)
        attach("controls-settings")
    }

    func testSettingsRefinementsAndReportPreparation() throws {
        launchAndWaitForOverlay()
        let ids = ["A", "B", "X", "Y", "Z", "Start", "L", "R"]
        var frames: [String: CGRect] = [:]
        for id in ids { frames[id] = app.buttons[id].frame }
        openMenu()
        openTouchSettings()
        let move = app.switches["Move touch controls"]
        move.tap()
        for id in ids {
            assertFrameClose(app.buttons[id].frame, frames[id]!, "entering Move preserves " + id)
        }
        attach("editor-preserves-gameplay-layout")
        app.buttons["Finish moving touch controls"].tap()
        for id in ids {
            assertFrameClose(app.buttons[id].frame, frames[id]!, "leaving Move preserves " + id)
        }
        tapMenuRow("Controller Button Mapping…")
        let binding = app.cells["BallpadMappingBind.A"]
        XCTAssertTrue(binding.waitForExistence(timeout: 10))
        attach("controller-settings")
        binding.tap()
        tapMappingChoice("B", inSheetTitled: "Bind GameCube A to")
        XCTAssertEqual(binding.value as? String, "B")
        app.buttons["BallpadMappingReset"].tap()
        XCTAssertEqual(binding.value as? String, "A")
        app.buttons["BallpadMappingClose"].tap()
        tapMenuRow("Experimental")
        XCTAssertNotNil(waitForOverlayElement("Uncapped Frame Rate", timeout: 10))
        XCTAssertNil(overlayElement("Record Audio"))
        XCTAssertNil(overlayElement("Record Audio…"))
        tapMenuRow("Report a Problem…")
        let problem = app.textFields["What went wrong?"]
        XCTAssertTrue(problem.waitForExistence(timeout: 10))
        problem.tap()
        problem.typeText("Local Simulator report verification")
        app.buttons["Prepare GitHub Report"].tap()
        XCTAssertTrue(app.alerts["Report Ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open GitHub"].exists)
        XCTAssertTrue(app.buttons["Share Log…"].exists)
        attach("report-ready-with-log")
        app.alerts["Report Ready"].buttons["Done"].tap()
    }

    func testReadableCreditsNavigation() throws {
        launchAndWaitForOverlay()
        openAbout()
        XCTAssertTrue(app.cells["BallpadAboutVersion"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["BallpadAboutLink.discord"].exists)
        XCTAssertTrue(app.cells["BallpadAboutLink.ballpad"].exists)
        attach("about-grouped-overview")
        let table = app.tables["BallpadAboutScroll"]
        let sunpad = app.cells["BallpadAboutProject.sunpad"]
        for _ in 0..<5 { if sunpad.isHittable { break }; table.swipeUp() }
        XCTAssertTrue(sunpad.isHittable)
        sunpad.tap()
        if !app.cells["BallpadAboutLink.sunpad"].waitForExistence(timeout: 2) { sunpad.tap() }
        attach("credits-after-project-tap")
        attachHierarchy("credits-after-project-tap")
        XCTAssertTrue(app.cells["BallpadAboutLink.sunpad"].waitForExistence(timeout: 10))
        attach("about-project-detail")
        let notice = app.cells.matching(identifier: "BallpadNotice.sunpad/LICENSE").firstMatch
        if notice.exists { notice.tap() }
        else {
            let license = app.cells.containing(.staticText, identifier: "sunpad/LICENSE").firstMatch
            XCTAssertTrue(license.exists)
            license.tap()
        }
        XCTAssertTrue(app.textViews["BallpadNoticeBody"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["BallpadNoticeBody"].value.debugDescription.contains("GNU"))
        attach("about-offline-license")
        app.buttons["BallpadNoticeClose"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["BallpadAboutClose"].tap()
    }

    func testReportKeyboardAndCompactFPS() throws {
        launchAndWaitForOverlay()
        setFPSCounter(true)
        guard let badge = waitForIdentifier("BallpadFPSCounter", timeout: 10) else {
            XCTFail("FPS badge is visible"); return
        }
        XCTAssertLessThanOrEqual(badge.frame.height, 44)
        XCTAssertGreaterThanOrEqual(badge.frame.width, 100)
        attach("compact-fps-badge")
        tapMenuRow("Report a Problem…")
        let summary = app.textFields["What went wrong?"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        summary.tap()
        summary.typeText("Intro has rendering artifacts\n")
        XCTAssertTrue(app.buttons["Prepare GitHub Report"].isHittable)
        let details = app.textViews["Steps and details"]
        attach("report-before-details")
        details.typeText("At 2x resolution, the Palace stadium intro has visible artifacts.\nReproduce by starting a grudge match.")
        XCTAssertGreaterThan(details.frame.height, 120)
        XCTAssertGreaterThan(details.frame.width, 400)
        XCTAssertTrue(app.buttons["Prepare GitHub Report"].isHittable)
        attach("report-with-ipad-keyboard")
        app.buttons["Prepare GitHub Report"].tap()
        XCTAssertTrue(app.alerts["Report Ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open GitHub"].exists)
        app.alerts["Report Ready"].buttons["Done"].tap()
        setFPSCounter(false)
    }

    func testRightTriggerCanMoveAndPersists() throws {
        launchAndWaitForOverlay()
        let right = app.buttons["R"]
        let original = right.frame
        let left = app.buttons["L"].frame
        openMenu()
        openTouchSettings()
        app.switches["Move touch controls"].tap()
        let start = right.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2,
                    thenDragTo: start.withOffset(CGVector(dx: -160, dy: 90)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let moved = right.frame
        XCTAssertLessThan(moved.midX, original.midX - 100, "R follows the editor drag")
        XCTAssertGreaterThan(moved.midY, original.midY + 50)
        assertFrameClose(app.buttons["L"].frame, left, "moving R leaves L alone")
        attach("right-trigger-moved")
        app.buttons["Finish moving touch controls"].tap()
        assertFrameClose(right.frame, moved, "Done retains R's custom placement")
        app.terminate()
        launchAndWaitForOverlay()
        assertFrameClose(right.frame, moved, "R placement survives relaunch")
        right.press(forDuration: 0.4)
        // Verify dragging back in the opposite direction also works.
        openMenu()
        openTouchSettings()
        app.switches["Move touch controls"].tap()
        let restore = right.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        restore.press(forDuration: 0.2,
                      thenDragTo: restore.withOffset(CGVector(dx: original.midX - moved.midX,
                                                             dy: original.midY - moved.midY)),
                      withVelocity: .slow, thenHoldForDuration: 0.3)
        let returned = right.frame
        XCTAssertGreaterThan(returned.midX, moved.midX + 100)
        XCTAssertLessThan(returned.midY, moved.midY - 50)
        app.buttons["Finish moving touch controls"].tap()
        assertFrameClose(right.frame, returned, "Done also retains the return drag")
    }

    // MARK: - Lifecycle

    func testBackgroundAndForegroundKeepTheOverlay() throws {
        launchAndWaitForOverlay()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()

        XCTAssertTrue(menuButton.waitForExistence(timeout: 90),
                      "the overlay is back on screen after resume")
        openMenu()
        // The row this used to look for is inside the Controls group, and scrollMenuForElement only
        // scrolls the level it is given -- so this assertion could not pass once the menu was
        // grouped into Display and Controls, and had been failing on every build since. What it is
        // for is that the menu is open and populated after a resume, which is the group itself;
        // reaching the row behind it is openTouchSettings' job on the next line, and it taps
        // Controls first exactly because the row is not published until it does.
        XCTAssertNotNil(scrollMenuForElement("Controls", timeout: 20),
                        "the menu still opens after resume")
        openTouchSettings()
        XCTAssertNotNil(waitForOverlayElement("Render resolution", timeout: 20),
                        "the settings panel still opens after resume")
        attach("after-resume")
    }

    // MARK: - About & Credits and the surfaces it opens (doc 34 F13; doc 35)

    /// The manifest components whose About row carries an http(s) destination, in manifest order.
    /// The last manifest component is deliberately absent: its `upstream` field names a file inside
    /// the port rather than a URL, and the screen publishes a link only where there is somewhere to
    /// go, so `aurora-vendored-libs` must not have a row. Asserting identifiers rather than display
    /// names is the point: the names are prose that may be reworded, the identifiers are the
    /// inventory.
    private static let aboutLinkComponentIDs = [
        "strikers", "smstrikers-decomp", "aurora", "dawn", "sdl3",
        "musyx", "ode", "ffmpeg", "googletest",
    ]

    /// The engine revision the shipped inventory pins. The About screen quotes the pin out of
    /// `notices/manifest.json` instead of carrying a typed string, so this constant is the upstream
    /// commit the app was built from and a build made from any other revision fails here.
    private static let enginePinRevision = "22649cb12c112454a34217429296c95bb181af8a"

    /// The first data row of the generated `notices/resources.txt`, and the notice the notice test
    /// opens. Pinned by name because "the bundled notices are readable offline" needs an actual
    /// notice file, not just a heading that claims one exists.
    private static let firstNoticePath = "strikers/README.upstream.md"

    /// Sentences the About paragraph must not contain. Doc 35 forbids the claims this app is not
    /// entitled to make on a contributor's behalf, so the check runs in the direction that cannot
    /// be satisfied by a substring accident: an unsupported claim appearing anywhere is a failure.
    /// Each phrase is chosen so the correct paragraph cannot contain it -- the disclaimer's own
    /// "unaffiliated with and not endorsed by Nintendo" must not trip a check like "endorsed by
    /// nintendo", which is why these name the claim rather than the noun.
    private static let unsupportedCreditClaims = [
        "all code is cc0", "public domain", "no rights reserved",
        "affiliation with nintendo", "endorsement from nintendo",
    ]

    /// The disclaimer the paragraph has to carry, verbatim from doc 35's text. Without this the
    /// "does not claim" checks above would also pass for a paragraph that says nothing at all.
    private static let requiredCreditDisclaimer =
        "unaffiliated with and not endorsed by Nintendo or Next Level Games"

    /// An identifier-addressed surface element. About mixes labels, buttons and a text view, and the
    /// accessibility type each one publishes is not uniform, so the type is discovered here rather
    /// than assumed by the caller.
    private func identifierElement(_ identifier: String) -> XCUIElement? {
        let candidates = [app.staticTexts[identifier], app.buttons[identifier],
                          app.textViews[identifier], app.otherElements[identifier],
                          app.scrollViews[identifier], app.cells[identifier]]
        for candidate in candidates where candidate.exists { return candidate }
        return nil
    }

    @discardableResult
    private func waitForIdentifier(_ identifier: String,
                                   timeout: TimeInterval = 20) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = identifierElement(identifier) { return element }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// The text an element publishes. A label carries its text in `label`; a text view carries it in
    /// `value` and a button's published destination is its `value` too. Reads whichever one has
    /// content, so a claim about text does not depend on which UIKit class renders it.
    private func publishedText(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    private func identifierQuery(_ prefix: String) -> XCUIElementQuery {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        return app.descendants(matching: .any).matching(predicate)
    }

    /// Opens About & Credits from the three-dot menu. The row is last, so on the phone it is on the
    /// menu's second page and the bounded scroll is what reaches it; on the iPad it publishes at once.
    private func openAbout() {
        openMenu()
        guard let row = scrollMenuForElement("About & Credits…", timeout: 25) else {
            attachHierarchy("about-row-missing")
            XCTFail("the About & Credits row is present in the menu")
            return
        }
        row.tap()
        XCTAssertNotNil(waitForIdentifier("BallpadAboutTitle", timeout: 30),
                        "the About & Credits screen opens")
    }

    /// Scrolls the About stack down. Bounded by the caller, because a row that is genuinely absent
    /// has to fail rather than scroll forever.
    private func scrollAboutDown() {
        let scroll = app.scrollViews["BallpadAboutScroll"]
        guard scroll.exists else { return }
        scroll.swipeUp()
    }

    @discardableResult
    private func revealNotice(_ relative: String, maxScrolls: Int = 8) -> XCUIElement? {
        let identifier = "BallpadNotice." + relative
        for pass in 0...maxScrolls {
            if let element = waitForIdentifier(identifier, timeout: 3) { return element }
            if pass == maxScrolls { break }
            scrollAboutDown()
        }
        return nil
    }

    /// F13. The About screen has to name upstream in the words doc 35 fixes, quote the revision
    /// this build was actually made from, offer a destination for every component that has one,
    /// and list the notices the bundle really carries. Every claim below is read back out of the
    /// app's own text; nothing here leaves the app, because tapping a link would open Safari and
    /// the destination is published as the row's value precisely so it can be read without that.
    func testAboutScreenNamesUpstreamContributorsAndTheirNotices() throws {
        launchAndWaitForOverlay()
        openAbout()
        attachHierarchy("about-hierarchy-top")

        guard let bodyElement = waitForIdentifier("BallpadAboutBody", timeout: 20) else {
            attachHierarchy("about-body-missing")
            XCTFail("the About screen carries the credit paragraph")
            return
        }
        let body = publishedText(bodyElement)
        XCTAssertGreaterThan(body.count, 200, "the credit paragraph is real prose")
        for required in ["new-coke/strikers", "Yannick Suter", "Aurora", Self.requiredCreditDisclaimer,
                         "The project grants no rights to redistribute game assets or disc images",
                         "unofficial", "Supply your own lawfully obtained game data"] {
            XCTAssertTrue(body.contains(required),
                          "the credit paragraph names " + required + "; saw: " + body)
        }
        let lowered = body.lowercased()
        for claim in Self.unsupportedCreditClaims {
            XCTAssertFalse(lowered.contains(claim),
                           "the credit paragraph does not claim " + claim + "; saw: " + body)
        }

        // The pin is quoted from the shipped manifest, so this is also the assertion that the
        // interface and the provenance inventory agree about which upstream commit is running.
        guard let pin = waitForIdentifier("BallpadAboutEnginePin", timeout: 20) else {
            XCTFail("the About screen quotes the engine pin")
            return
        }
        let pinText = publishedText(pin)
        XCTAssertTrue(pinText.contains(Self.enginePinRevision),
                      "the engine pin carries the upstream revision; saw: " + pinText)
        XCTAssertTrue(pinText.contains("v1.1.1"),
                      "the engine pin carries the upstream version; saw: " + pinText)

        XCTAssertNotNil(waitForIdentifier("BallpadAboutRevisions", timeout: 10),
                        "the About screen lists the pinned revisions")

        // One row per component with a destination, and the row says where it goes.
        for component in Self.aboutLinkComponentIDs {
            let identifier = "BallpadAboutLink." + component
            guard let link = waitForIdentifier(identifier, timeout: 5) else {
                attachHierarchy("about-link-missing-" + component)
                XCTFail("the About screen offers a destination for " + component)
                continue
            }
            let destination = (link.value as? String) ?? ""
            XCTAssertTrue(destination.hasPrefix("http"),
                          "the " + component + " row publishes its destination; saw: " + destination)
        }
        XCTAssertNil(identifierElement("BallpadAboutLink.aurora-vendored-libs"),
                     "a component whose upstream is not a URL does not get a link row")

        // The notice inventory is the bundle's inventory: the heading's own count has to be the
        // real number, no row may name a file the bundle does not carry, and every row that is
        // published has to name a path inside the notices folder.
        let heading = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Bundled notices (")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the About screen lists bundled notices")
        let headingText = heading.label
        let declared = Int(headingText.dropFirst("Bundled notices (".count).prefix(while: \.isNumber)) ?? 0
        XCTAssertGreaterThanOrEqual(declared, 17,
                                    "the bundled notices are counted, not summarised; saw: " + headingText)

        let noticeRows = identifierQuery("BallpadNotice.")
        XCTAssertGreaterThan(noticeRows.count, 0, "the About screen lists at least one notice")
        XCTAssertLessThanOrEqual(noticeRows.count, declared,
                                 "the screen never lists more notices than it declares")
        XCTAssertNil(identifierElement("BallpadNotice.path"),
                     "the generated list's column header is not rendered as a notice")
        for index in 0..<noticeRows.count {
            let identifier = noticeRows.element(boundBy: index).identifier
            let relative = String(identifier.dropFirst("BallpadNotice.".count))
            XCTAssertTrue(relative.contains("/") || relative == "README.md",
                          "every notice row names a file in the notices folder; saw: " + relative)
        }

        // The row the notice test opens has to exist after scrolling, or "the notices are
        // readable" would be a claim about a heading rather than about a file.
        XCTAssertNotNil(revealNotice(Self.firstNoticePath),
                        "the first bundled notice is present in the list")
        attachHierarchy("about-hierarchy-walked")
    }

    /// F13. A notice opens in full, offline, with the file's own text: the row's title is the path
    /// it stands for, the body is the notice rather than a placeholder, and closing it leaves About
    /// where it was. The body assertion is a token that exists in the notice itself, so a screen
    /// that rendered "could not be read" would fail here.
    func testAboutNoticeOpensInFullOffline() throws {
        launchAndWaitForOverlay()
        openAbout()

        guard let row = revealNotice(Self.firstNoticePath) else {
            attachHierarchy("notice-row-missing")
            XCTFail("the notice " + Self.firstNoticePath + " is listed")
            return
        }
        row.tap()

        guard let title = waitForIdentifier("BallpadNoticeTitle", timeout: 20) else {
            attachHierarchy("notice-would-not-open")
            XCTFail("tapping a notice opens it")
            return
        }
        XCTAssertEqual(title.label, Self.firstNoticePath,
                       "the opened notice names the file it is showing")

        guard let bodyElement = waitForIdentifier("BallpadNoticeBody", timeout: 20) else {
            XCTFail("the notice shows its body")
            return
        }
        let body = publishedText(bodyElement)
        XCTAssertGreaterThan(body.count, 500,
                             "the notice is the file's text, not a one-line placeholder")
        for required in ["Super Mario Strikers", "Yannick Suter", "Licensing"] {
            XCTAssertTrue(body.contains(required),
                          "the notice carries its own words (" + required + ")")
        }
        attach("notice-" + Self.firstNoticePath.replacingOccurrences(of: "/", with: "-"))

        let close = app.buttons["BallpadNoticeClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "the notice offers a way back")
        close.tap()
        XCTAssertFalse(app.staticTexts["BallpadNoticeTitle"].waitForExistence(timeout: 5),
                       "closing the notice dismisses it")
        XCTAssertNotNil(identifierElement("BallpadAboutTitle"),
                        "closing a notice leaves About where it was")

        app.buttons["BallpadAboutClose"].tap()
        XCTAssertFalse(app.staticTexts["BallpadAboutTitle"].waitForExistence(timeout: 5),
                       "closing About dismisses it")
        // The overlay is what was under the sheet, and the three-dot button is how the overlay
        // says so: the menu rows are inside the menu, so looking for one of those here would be
        // asking the wrong surface whether it came back.
        XCTAssertTrue(menuButton.waitForExistence(timeout: 15),
                      "the overlay is underneath again")
    }

    /// The physical button the panel currently binds `gameButton` to, read off the row it drew for
    /// it. The row reads `Z  ←  Left Shoulder`, so the whole row is returned rather than the
    /// right-hand name: assigning is a swap, and two rows moving is what tells a swap from a write.
    private func mappingRowText(_ gameButton: String) -> String? {
        guard let row = identifierElement("BallpadMappingBind." + gameButton) else { return nil }
        return publishedText(row)
    }

    /// Taps one of the panel's rebind rows, scrolling the panel when the row is below the sheet's
    /// fold. The panel is a page sheet on both form factors and its content is taller than the
    /// phone's sheet, so a row one wants can be published and not yet on screen.
    private func tapMappingBindRow(_ gameButton: String) {
        guard let row = identifierElement("BallpadMappingBind." + gameButton) else {
            attachHierarchy("mapping-bind-" + gameButton + "-missing")
            XCTFail("the panel draws a rebind row for " + gameButton)
            return
        }
        if !row.isHittable {
            // The presented sheet's own scroll view, which is what a person swipes to reach a row
            // past the fold. Bounded, so a row that is genuinely unreachable fails below instead of
            // scrolling until the budget runs out.
            let panel = app.scrollViews.firstMatch
            for _ in 0..<6 where !row.isHittable {
                guard panel.exists else { break }
                panel.swipeUp()
            }
        }
        XCTAssertTrue(row.isHittable, "the " + gameButton + " rebind row is reachable in the panel")
        row.tap()
    }

    /// Taps a choice in the action sheet a rebind row raises. The sheet is a `UIAlertController`, so
    /// the choice is named by its title and the surface it lands on is what varies: an action sheet is
    /// a popover on the iPad and a sheet on the phone, and the presenting panel is itself a page
    /// sheet. The two titled surfaces are asked first so the choice cannot be confused with a control
    /// of the panel or of the overlay underneath, and the whole-app query is only reached for when
    /// neither surface is on screen at all.
    private func tapMappingChoice(_ title: String, inSheetTitled sheetTitle: String) {
        let owners: [XCUIElement] = [app.sheets[sheetTitle], app.alerts[sheetTitle],
                                     app.sheets.firstMatch, app.alerts.firstMatch]
        for owner in owners where owner.exists {
            let choice = owner.buttons[title]
            if choice.waitForExistence(timeout: 5) {
                choice.tap()
                return
            }
        }
        let bare = app.buttons[title]
        if bare.waitForExistence(timeout: 5) && bare.isHittable {
            bare.tap()
            return
        }
        attachHierarchy("mapping-choice-" + title)
        XCTFail("the sheet titled \"" + sheetTitle + "\" offers " + title)
    }

    /// Opens the mapping panel from the three-dot menu. The row is on the menu's second page on the
    /// phone, so the bounded scroll is what reaches it on both form factors.
    private func openMappingPanel() {
        openMenu()
        guard let row = scrollMenuForElement("Controller Button Mapping…", timeout: 25) else {
            attachHierarchy("mapping-row-missing")
            XCTFail("the Controller Button Mapping row is present in the menu")
            return
        }
        row.tap()
        XCTAssertNotNil(waitForIdentifier("BallpadMappingTitle", timeout: 30),
                        "the mapping panel opens")
    }

    /// The launch a pad-producing run has: the shared environment every other row uses, plus the F12
    /// scripted controller and the per-frame chain it logs. Named once so the two scripted launches
    /// below cannot drift apart in what they ask the app to do.
    private static let scriptedPadLaunch: [String: String] = [
        "STRIKERS_FAKE_PAD": "controller", "STRIKERS_LOG_CONTROLLER": "1",
    ]

    /// R1 item 7's editable half, and F12 taken from the interface's side. The five rows under the
    /// panel's bridge heading are the vendored A/B/X/Y/Z store, which is the map the app's own bridge
    /// reads once per sample when it translates a controller; assigning is a swap, so the five
    /// physical buttons stay a permutation and no row can leave another unbound. This row drives that
    /// edit through the panel's real taps and reads the result back off the panel every time it
    /// opens, twice across a termination, and then puts the interface's default back through the
    /// panel's own Reset. Every launch is a fresh process, which is what makes a reading a read of
    /// the store rather than of the edit this process made.
    ///
    /// The two scripted launches are the half a label cannot prove: with the scripted pad running the
    /// app's own log carries the map the *bridge* read at start-up and the bits it published for the
    /// script's own press-y -- a press of the physical Y button -- on every step it ran. The
    /// S.f13.mapping-applied row fails unless that press travelled through the swapped map, which is
    /// the one thing this panel claims about the game rather than about itself.
    func testControllerMappingPanelRebindIsTheMapTheBridgeApplies() throws {
        launchAndWaitForOverlay()
        openMappingPanel()

        XCTAssertNotNil(identifierElement("BallpadMappingBridgeHeading"),
                        "the panel says which map its editable rows are")
        XCTAssertNotNil(identifierElement("BallpadMappingBridgeNote"),
                        "the panel states what a rebind does to the button it swaps with")

        // Read per button rather than as one string: assigning is a swap, so the pair of rows that
        // move is what tells a swap from a write.
        XCTAssertEqual(mappingRowText("A"), "A  ←  A", "the store starts at the interface's default")
        XCTAssertEqual(mappingRowText("B"), "B  ←  B", "the store starts at the interface's default")
        XCTAssertEqual(mappingRowText("X"), "X  ←  X", "the store starts at the interface's default")
        XCTAssertEqual(mappingRowText("Y"), "Y  ←  Y", "the store starts at the interface's default")
        XCTAssertEqual(mappingRowText("Z"), "Z  ←  Left Shoulder",
                       "the store starts at the interface's default")
        attach("mapping-before-rebind")

        tapMappingBindRow("Z")
        tapMappingChoice("Y", inSheetTitled: "Bind GameCube Z to")

        XCTAssertEqual(mappingRowText("Z"), "Z  ←  Y",
                       "choosing a physical button for Z binds Z to it")
        XCTAssertEqual(mappingRowText("Y"), "Y  ←  Left Shoulder",
                       "and the row that held Z's binding takes the one it swapped with")
        attach("mapping-after-rebind")

        app.terminate()
        launchAndWaitForOverlay(extraEnvironment: Self.scriptedPadLaunch)
        openMappingPanel()
        XCTAssertEqual(mappingRowText("Z"), "Z  ←  Y",
                       "the rebind survived a termination and a fresh launch")
        XCTAssertEqual(mappingRowText("Y"), "Y  ←  Left Shoulder",
                       "the swap survived with it, so the stored map is still a permutation")
        attach("mapping-after-relaunch")

        app.terminate()
        launchAndWaitForOverlay()
        openMappingPanel()
        XCTAssertEqual(mappingRowText("Z"), "Z  ←  Y",
                       "the store still holds the rebind before the default is asked for")
        guard let reset = identifierElement("BallpadMappingReset") else {
            attachHierarchy("mapping-reset-missing")
            XCTFail("the panel offers the interface's own default")
            return
        }
        reset.tap()
        XCTAssertEqual(mappingRowText("Z"), "Z  ←  Left Shoulder",
                       "Reset restores the interface's default")
        XCTAssertEqual(mappingRowText("Y"), "Y  ←  Y",
                       "and puts every row it moved back")
        attach("mapping-after-reset")

        app.terminate()
        launchAndWaitForOverlay(extraEnvironment: Self.scriptedPadLaunch)
        openMappingPanel()
        XCTAssertEqual(mappingRowText("Z"), "Z  ←  Left Shoulder",
                       "the default survived a termination and a fresh launch")
        XCTAssertEqual(mappingRowText("Y"), "Y  ←  Y",
                       "so the next session starts where the interface's default says it does")

        app.buttons["BallpadMappingClose"].tap()
        XCTAssertFalse(app.staticTexts["BallpadMappingTitle"].waitForExistence(timeout: 5),
                       "closing the panel dismisses it")
        XCTAssertTrue(menuButton.waitForExistence(timeout: 15),
                      "the overlay is underneath again")
    }


    /// F13/item 7. The Controller Button Mapping row opens a panel that reports the port's own map
    /// for its port, or the port's own reason there is none. The panel is read-only on purpose, so
    /// what is judged is that the reading is the port's and that Refresh re-reads it rather than
    /// that a row edits anything. Returns a description of the failure, or nil when the reading is
    /// one of the two honest ones.
    private func mappingReadingIsHonest() -> String? {
        guard let device = waitForIdentifier("BallpadMappingDevice", timeout: 10) else {
            return "the panel says which device it asked about"
        }
        let deviceText = publishedText(device)
        let rows = identifierQuery("BallpadMappingRow.")
        let noMap = deviceText.range(of: "reports no pad map for port [0-9]+",
                                     options: .regularExpression) != nil
        if noMap {
            return rows.count == 0
                ? nil
                : "a port with no map reports no rows, not " + String(rows.count)
        }
        guard rows.count > 0 else {
            return "a named device comes with the rows it maps; saw only: " + deviceText
        }
        for index in 0..<rows.count {
            let text = publishedText(rows.element(boundBy: index))
            if !text.contains("→") {
                return "every row maps a GameCube control to something; saw: " + text
            }
        }
        return nil
    }

    func testControllerMappingPanelReportsThePortsOwnMap() throws {
        launchAndWaitForOverlay()
        openMenu()
        guard let row = scrollMenuForElement("Controller Button Mapping…", timeout: 25) else {
            attachHierarchy("mapping-row-missing")
            XCTFail("the Controller Button Mapping row is present in the menu")
            return
        }
        row.tap()

        XCTAssertNotNil(waitForIdentifier("BallpadMappingTitle", timeout: 30),
                        "the mapping panel opens")
        XCTAssertNotNil(identifierElement("BallpadMappingHeading"),
                        "the panel states what its rows map from")
        XCTAssertNotNil(identifierElement("BallpadMappingNote"),
                        "the panel states that it only reports")

        let first = mappingReadingIsHonest()
        attachHierarchy("mapping-panel-hierarchy")
        XCTAssertNil(first, first ?? "")

        // Refresh re-asks the port. Nothing about the panel is cached across a re-read, so the same
        // reading has to survive it -- which is what makes the panel a read of the port's table
        // rather than a snapshot taken once when the view loaded.
        let refresh = app.buttons["BallpadMappingRefresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15), "the panel offers a re-read")
        refresh.tap()
        let second = mappingReadingIsHonest()
        attachHierarchy("mapping-panel-after-refresh")
        XCTAssertNil(second, second ?? "")

        app.buttons["BallpadMappingClose"].tap()
        XCTAssertFalse(app.staticTexts["BallpadMappingTitle"].waitForExistence(timeout: 5),
                       "closing the panel dismisses it")
        XCTAssertTrue(menuButton.waitForExistence(timeout: 15),
                      "the overlay is underneath again")
    }

    /// R1 item 5, the FPS row. The vendored row persists a setting and nothing else; the numbers on
    /// screen are Ballpad's own, filled once a frame from the port's benchmark. So the row is proved
    /// by the label appearing when it is on and going away when it is off -- the label's text is not
    /// asserted, because on a title screen the rate is not the claim, existence is.
    func testFrameStatisticsRowDrivesTheCountersItClaims() throws {
        launchAndWaitForOverlay()
        openMenu()
        XCTAssertNil(identifierElement("BallpadFPSCounter"),
                     "the counter is not on screen while the setting is off")
        guard let row = scrollMenuForElement("Show FPS Counter", timeout: 15) else {
            attachHierarchy("fps-row-missing")
            XCTFail("the Show FPS Counter row is present in the menu")
            return
        }
        row.tap()
        XCTAssertNotNil(waitForIdentifier("BallpadFPSCounter", timeout: 30),
                        "turning the row on puts the port's own counters on screen")
        attach("fps-counter-on")

        // The menu stays open across a re-read of the panel on the iPad, so closing it is what this
        // waits on rather than assuming a tap dismissed it.
        openMenu()
        guard let again = scrollMenuForElement("Show FPS Counter", timeout: 15) else {
            XCTFail("the Show FPS Counter row is present when the menu reopens")
            return
        }
        again.tap()
        var gone = false
        let deadline = Date().addingTimeInterval(20)
        repeat {
            if identifierElement("BallpadFPSCounter") == nil { gone = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        XCTAssertTrue(gone, "turning the row off takes the counters away again")
    }

    // MARK: - The frame-rate row (R1 item 11)

    /// Taps the frame-rate row and returns the alert's own message: the limiter the port says it now
    /// has, its display rate, and whether vsync is pacing as well, all read by the row's handler
    /// immediately after it calls PortSetFrameLimit.
    private func tapFrameRateRow() -> String {
        chooseMenuRow("Uncapped Frame Rate", from: "Experimental")
        let alert = app.alerts["Frame Rate Limit"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "the frame-rate row raises its alert")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        alert.buttons["OK"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 5), "OK dismisses the alert")
        return message
    }

    /// R1 item 11's row stands where the vendored "Experimental 60 FPS (Restart Required)" row was.
    /// A native port has no emulated clock to speed up and no boot mode to change, so what the row
    /// does is tell the port's own limiter what to cap to, and the alert it raises reports the limiter
    /// the port says it now has rather than restating the row's title. The two taps below are read off
    /// that live period -- "uncapped" and "capped to N Hz" are opposite answers derived from
    /// PortFrameLimitInfo -- so a row that changed nothing could not produce both. The relaunch proves
    /// the other half: the choice is stored under Ballpad's own key and re-applied by PortHostUIStart,
    /// so a value that did not survive the fresh process would make the second tap uncapped again.
    func testFrameRateLimitRowReachesThePortsLimiter() throws {
        launchAndWaitForOverlay()
        let first = tapFrameRateRow()
        XCTAssertTrue(first.contains("uncapped"),
                      "the first tap lifts the cap, and the port says so: " + first)
        attach("frame-limit-uncapped")

        app.terminate()
        launchAndWaitForOverlay()
        let second = tapFrameRateRow()
        XCTAssertTrue(second.contains("capped to"),
                      "one more tap after a relaunch caps again, so the choice survived and was "
                      + "re-applied at start: " + second)
        attach("frame-limit-capped")
    }

    // MARK: - The display rows, read back from the renderer

    /// R1 item 5's other half. The menu's Render Resolution and Aspect Ratio rows are the vendored
    /// rows re-bound to Ballpad handlers in -buildMenu, and this row is what says they reach the port
    /// rather than only the settings store: every number below is read out of the renderer's own
    /// read-back. It is asserted relationally on purpose -- the window's size belongs to the
    /// Simulator, so the claims are that 4× is four times the height of 1× at the same shape, that a
    /// pinned shape survives that change, that the three aspect rows end at three different
    /// destinations, and that the frame the port draws the game into is the 480 design height times
    /// the shape it reports. The absolutes are 4:3's 640 and the two ratios themselves, within the
    /// port's own rounding.
    ///
    /// The render target is deliberately not one of the things an aspect row is allowed to move: the
    /// port presents one buffer scaled to the surface and fits the picture inside it by moving the
    /// game's logical frame and the gameplay camera. So the aspect rows are checked through those two
    /// fields, and the target's shape is checked to stay put.
    func testDisplayRowsReachTheRenderer() throws {
        launchAndWaitForOverlay()
        setFPSCounter(true)
        guard let baseline = waitForDisplay("at launch", where: { $0.scale > 0 }) else { return }
        XCTAssertTrue(baseline.followsWindow,
                      "a fresh install has no stored aspect, so the port follows the window's shape")
        attach("display-baseline")

        chooseMenuRow("1× (Native)", from: "Render Resolution")
        guard let native = waitForDisplay("at 1×", where: { abs($0.scale - 1.0) < 0.01 }) else { return }
        chooseMenuRow("4×", from: "Render Resolution")
        guard let four = waitForDisplay("at 4×", where: { abs($0.scale - 4.0) < 0.01 }) else { return }
        XCTAssertEqual(four.height, native.height * 4,
                       "4× is four times 1× in the target's height (" + String(describing: native)
                       + " then " + String(describing: four) + ")")
        XCTAssertGreaterThan(four.width, native.width, "4× is wider than 1×")
        XCTAssertEqual(four.aspect, native.aspect, accuracy: 0.01,
                       "the resolution row leaves the shape alone")
        XCTAssertEqual(four.followsWindow, native.followsWindow,
                       "the resolution row leaves the shape's owner alone")
        attach("display-4x")

        // The aspect row moves the shape and nothing else: same height, pinned, and 4:3 exactly.
        chooseMenuRow("Original 4:3", from: "Aspect Ratio")
        guard let fourThree = waitForDisplay("at 4:3", where: { !$0.followsWindow }) else { return }
        XCTAssertEqual(fourThree.height, four.height,
                       "the aspect row leaves the target's height alone")
        XCTAssertEqual(fourThree.aspect, 4.0 / 3.0, accuracy: 0.01, "the 4:3 row pins 4:3")
        XCTAssertEqual(Double(fourThree.logicalWidth), 640.0, accuracy: 1.0,
                       "and the renderer draws the game into the console's own 640-unit frame ("
                       + String(describing: fourThree) + ")")
        XCTAssertEqual(fourThree.blend, 0.0, accuracy: 0.02,
                       "with the gameplay camera left at its 4:3 tuning")
        attach("display-43")

        chooseMenuRow("16:9 (Experimental)", from: "Aspect Ratio")
        guard let wide = waitForDisplay("at 16:9", where: { abs($0.aspect - 16.0 / 9.0) < 0.01 })
        else { return }
        XCTAssertFalse(wide.followsWindow, "16:9 is a pinned shape too")
        XCTAssertGreaterThan(wide.aspect, fourThree.aspect, "16:9 is wider than 4:3")
        XCTAssertGreaterThan(wide.logicalWidth, fourThree.logicalWidth,
                             "and the frame the renderer draws the game into is wider at that height")
        // The relation the port keeps by construction, and why the number is not a constant: the width
        // is 480 * aspect, dropped to even because GXSetFogRangeAdj and friends take a half-width.
        // 16:9 is 853.33 and so lands on 852, which is what the accuracy leaves room for.
        XCTAssertEqual(Double(wide.logicalWidth), 480.0 * wide.aspect, accuracy: 2.0,
                       "the logical frame is the design height times the pinned shape ("
                       + String(describing: wide) + ")")
        XCTAssertEqual(wide.blend, 1.0, accuracy: 0.02,
                       "16:9 is where the camera blend reaches its widescreen knot")
        XCTAssertEqual(wide.height, four.height, "still the height the resolution row asked for")
        attach("display-169")

        // Fill Screen hands the shape back to the window, which is what it means on a device whose
        // window is not 16:9: the read-back has to name the window again, and the ratio has to be the
        // one the run started with, whatever that is on this form factor.
        chooseMenuRow("Fill Screen (Experimental)", from: "Aspect Ratio")
        guard let filled = waitForDisplay("at Fill Screen", where: { $0.followsWindow }) else { return }
        XCTAssertEqual(filled.aspect, baseline.aspect, accuracy: 0.01,
                       "Fill Screen is the window's shape, which is where the run started")
        XCTAssertEqual(filled.blend, baseline.blend, accuracy: 0.02,
                       "so the camera blend is the one the run started with")
        XCTAssertEqual(Double(filled.logicalWidth), Double(baseline.logicalWidth), accuracy: 1.0,
                       "and so is the frame the renderer draws the game into")
        attach("display-fill")

        let readings = [("launch", baseline), ("1×", native), ("4×", four),
                        ("4:3", fourThree), ("16:9", wide), ("Fill Screen", filled)]

        // What the aspect rows are not allowed to touch: the target is scaled to the surface, and the
        // surface did not move. A port that letterboxed by shrinking its buffer would fail here, and
        // that is the point -- the picture is fitted by the game's own frame, not by the buffer's.
        for reading in [fourThree, wide, filled] {
            XCTAssertEqual(reading.renderedAspect, four.renderedAspect, accuracy: 0.01,
                           "the aspect rows leave the presented target's shape alone ("
                           + String(describing: reading) + ")")
        }
        for (name, reading) in readings {
            XCTAssertEqual(Double(reading.logicalWidth), 480.0 * reading.aspect, accuracy: 2.0,
                           "the logical frame is the design height times the shape the port reports, "
                           + "at " + name + " (" + String(describing: reading) + ")")
        }

        // The counter goes back off because the row that owns it reads its absence first; this row is
        // a guest on that setting, and it is the only reason the setting is touched here at all.
        setFPSCounter(false)
        XCTAssertNil(identifierElement("BallpadFPSCounter"), "the counter is off again")
    }

    // MARK: - The touch-control settings that move drawn controls (R1 item 5)

    /// A slider's own reading, as a percentage of *that slider's own range*.
    ///
    /// These sliders publish the thumb's position along their own track rather than the setting they
    /// hold, and the ranges in play are not the same one: the panel's Control size slider is 0.70-1.35
    /// and reads 46% at its 1.00 default, the opacity slider is 0.25-1.0 and reads 76% at its 0.82
    /// default, and the layout editor's per-control slider is 0.60-1.75 (SunPadGameOverlay.mm,
    /// `_selectedSizeSlider`). Two readings are therefore percentages of two different ranges, and two
    /// 100%s are not the same gesture: the editor's track tops out at size 1.75 while the panel's tops
    /// out at 1.35, and a reading the editor calls 99% is size 1.7385, which is *not* the 1.75 ceiling
    /// the store clamps to (SunPadSettings.mm, `setSizeScale:`). Each is exactly (value - minimum) /
    /// (maximum - minimum), which is the same scale `adjust(toNormalizedSliderPosition:)` speaks, so a
    /// reading and a drag address one scale and a value can be put back exactly. Nil rather than zero
    /// when the control is absent, because "not on screen" and "at the bottom of its track" must not
    /// compare equal.
    private func sliderPercent(_ label: String) -> Double? {
        let slider = app.sliders[label]
        guard slider.exists, let raw = slider.value as? String else { return nil }
        return Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    private func requireSliderPercent(_ label: String, _ what: String) -> Double {
        guard let value = sliderPercent(label) else {
            attachHierarchy("slider-not-readable")
            XCTFail("the " + label + " slider reads back its own value " + what)
            return -1
        }
        return value
    }

    /// A one-line description of a slider's live state, for a message that has to say *why* a drive
    /// stopped short rather than only how far it got.
    ///
    /// A drive that cannot reach the top of a track has three different causes that read alike from
    /// the value alone: the control is disabled, the touch is not delivered to it, or its travel is
    /// shorter than its frame. The neighbouring button is named as well, because a slider whose frame
    /// shares its right end with another control is the case where a touch aimed at the top of the
    /// track lands on something else instead.
    private func sliderDiagnostics(_ label: String) -> String {
        let slider = app.sliders[label]
        guard slider.exists else { return "[" + label + " is not on screen]" }
        let done = app.buttons["Finish moving touch controls"]
        return "[" + label
            + " enabled " + (slider.isEnabled ? "1" : "0")
            + " hittable " + (slider.isHittable ? "1" : "0")
            + " value " + String(describing: slider.value)
            + " frame " + NSCoder.string(for: slider.frame)
            + " next-to " + (done.exists ? NSCoder.string(for: done.frame) : "nothing")
            + "]"
    }

    /// Every reading the last drive took, one entry per mechanism per round.
    ///
    /// A drive that stops short of the top has three mechanisms that read alike from the single value
    /// it returns: the assertion can only say where the thumb ended. Recording what each path asked for
    /// and what came back is what tells a plateau the geometry imposes -- all three agreeing on one
    /// value -- apart from a mechanism that is simply the wrong one for this control.
    private var driveTrail: [String] = []

    private func readingText(_ value: Double?) -> String {
        guard let value = value else { return "unreadable" }
        return String(format: "%.1f", value)
    }

    /// One real touch along `label`'s own track, dragged from its middle to the far end of the
    /// element, and the reading it leaves behind.
    ///
    /// The element's own frame is the scale a synthetic touch is expressed in, so a drive that stops
    /// short leaves one question the value cannot answer: whether the top of the track lies past the
    /// element's own right edge, or is not reachable by any touch at all. A drag that ends exactly on
    /// that right edge answers it without touching anything else -- a reading of the maximum afterwards
    /// means the top is addressable and a plateau is the drive's own fault, while a reading below it
    /// means the element's last percent is not part of its own track.
    ///
    /// Taps *past* the right edge were measured and are deliberately not used here. The editor bar is a
    /// `SunPadPassThroughView`, whose hitTest hands a touch back to whatever is drawn behind it unless
    /// the touch lands on one of its own subviews, and the `Finish moving touch controls` button
    /// neighbours the editor's slider with only about a dozen points between them. A sweep that walked
    /// past the slider's edge therefore closed the editing session partway -- measured, as a failure to
    /// resolve the slider at all rather than as a value -- which is a state the rest of the row cannot
    /// continue from.
    @discardableResult
    private func dragToTheRightEdgeOfTheTrack(_ label: String) -> Double? {
        let slider = app.sliders[label]
        guard slider.exists else { return nil }
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        return settledSliderPercent(label)
    }

    /// One real touch along `label`'s track, to `percent` of it, returning what the control reads
    /// afterwards. The drag is the vendored control's own gesture path: the sliders are the bytes
    /// this project does not touch, so a value that arrives is a value UIKit delivered to them.
    @discardableResult
    private func setSliderTrackPercent(_ label: String, to percent: Double) -> Double? {
        let slider = app.sliders[label]
        guard slider.exists else { return nil }
        let normalized = CGFloat(min(max(percent / 100.0, 0.0), 1.0))
        slider.adjust(toNormalizedSliderPosition: normalized)
        return settledSliderPercent(label)
    }

    /// The reading a slider settles on, waited for rather than taken at the first opportunity.
    ///
    /// A slider applies a touch on a later turn of the app's own run loop, so a read taken in the same
    /// breath as the gesture can be the value from *before* it -- and a drive that reads its own request
    /// back would then conclude the slider had already reached the top when it had not. Two equal
    /// readings in a row are what "settled" means: the first read is the one that can be stale, and the
    /// second is the one that agrees with it. A slider that is not there at all reads nil, which is not
    /// the same answer as a slider at the bottom of its track.
    private func settledSliderPercent(_ label: String, timeout: TimeInterval = 8) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: Double?
        repeat {
            guard let now = sliderPercent(label) else { return previous }
            if now == previous { return now }
            previous = now
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return previous
    }

    /// One tap on the far end of `label`'s track, and what the slider reads afterwards.
    ///
    /// `adjust(toNormalizedSliderPosition: 1.0)` synthesizes a *drag* from wherever the thumb is to the
    /// track's own end, and that path is what the layout can move out from under: the same call that
    /// reads a clean 100% on the iPhone 17e has stopped at 93% on the iPad, with the app's own log
    /// showing the drag ending at size 1.30 of the vendored 0.70-1.35 range, and repeating the identical
    /// call walks a little further and then plateaus in the nineties. A tap has no path -- it is one
    /// touch at one point -- and a slider jumps its thumb to the point it is touched, so a tap at the
    /// end of the element's own bounds asks the slider for the top of its track directly.
    ///
    /// That iPad plateau was since measured to be the *ruler* and not the layout, which is why the
    /// drive is now preceded by -waitForTheFrameSpaceToBeTheAppsOwn rather than given a fifth
    /// mechanism: with the device left in portrait the accessibility server reports every control at
    /// 0.6949x of where the app drew it, so a path computed from a frame in that space ends short of a
    /// track that is in fact reachable. Measured across the two runs: `uitest-pad-f06-pad-r3` read
    /// `adjust->98.0` from the editor's slider in the fitted space, and `uitest-pad-pad-geom1`
    /// read `adjust->100.0` from the same slider in the same binary once the device was landscape.
    /// The mechanisms below are kept because they are still the four ways a track can be addressed, and
    /// the trail they leave is what would show a genuine short travel if one appeared.
    ///
    /// A tap is also the only fallback that cannot disturb the tree if it misses. The drag released
    /// *past* the end of the slider was tried first and does reach the top of the panel's slider, but on
    /// the layout editor's slider it took hold of the surface behind the editor and moved a control with
    /// it: measured on the iPad, the selected control's slider fell to 35% and the right shoulder was
    /// left 12pt off its row. A tap that misses reads a value it did not change and nothing else moves.
    @discardableResult
    private func tapTheEndOfTheTrack(_ label: String) -> Double? {
        let slider = app.sliders[label]
        guard slider.exists else { return nil }
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        return settledSliderPercent(label)
    }

    /// One drag that begins inside `label` and ends past the far end of the element, and the reading it
    /// leaves behind.
    ///
    /// This mechanism exists because the other two address a point *inside* the element's own frame, and
    /// on this form factor the frame's mapping is what the ninth tenths of the track is worth. Measured
    /// on the iPhone 17e: the editor's per-control slider reads 97.0% after both `adjust` and a tap at
    /// [0.99, 0.5] of its frame, while the panel's slider reaches 100% from `adjust` alone on the same
    /// run. A touch that lands *past* the right edge of the element is the one the geometry cannot hold
    /// short: UIKit clamps the value at the slider's own maximum rather than at whichever position the
    /// frame's outer hundredth maps to.
    ///
    /// The press has to be inside the element, and that is the whole of the safety argument. It begins
    /// at the middle rather than at the element's left end, because the editor bar draws its own hint
    /// label across that end of the row. A gesture
    /// recognizer is handed a touch only when it begins inside the view that owns it, so a drag that
    /// starts on the slider cannot be taken away from it by the editor's control-drag pans even though
    /// its path and its release both leave the slider's bounds -- which is exactly how this differs from
    /// the drag past the end that was tried first, whose press landed beyond the slider, was handed to
    /// whatever control was behind the editor, and moved one (the iPad measurement: the selected
    /// control's slider fell to 35% and the right shoulder was left 12pt off its row).
    @discardableResult
    private func dragPastTheEndOfTheTrack(_ label: String) -> Double? {
        let slider = app.sliders[label]
        guard slider.exists else { return nil }
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 1.10, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        return settledSliderPercent(label)
    }

    /// Drives `label` to the top of its track and returns the reading of the state it leaves behind.
    ///
    /// Four mechanisms, in the order of how much of the slider's own geometry each one depends on.
    /// `adjust(toNormalizedSliderPosition:)` is the mechanism a slider answers on its own, and it is
    /// tried first because on one form factor it is the whole of the drive: measured on the iPhone 17e,
    /// the panel's `Control size` slider reads 100% from the first call. The drag that ends past the
    /// A single real touch ending on the element's own right edge is second, and it is the mechanism
    /// that separates "the top of the track is not inside the element" from "the drive chose badly":
    /// it places exactly the touch the sweep past the edge was meant to place, without the taps beyond
    /// the edge that closed the editor. The drag that ends *past* the element's far edge is third,
    /// because it is the one mechanism the frame's own mapping cannot stop short of the maximum. The
    /// tap on the end of the track is fourth, as the cheap second opinion. They are alternated until
    /// one of them reports the top or a whole round improves on nothing.
    ///
    /// Every mechanism's reading is taken after it, and what comes back is always the slider's own
    /// current state rather than a high-water mark it has since fallen back from. That distinction is
    /// the drive's own correctness condition rather than a courtesy: a `max` over the round's readings
    /// can report a value the slider is not at, which would hand the caller's assertion a 100% it could
    /// pass on while the tree underneath held something else. What the caller's assertion decides is
    /// whether the reading *is* the top; this drive's job is only to make it the best one it can reach
    /// and to say truthfully where it stopped.
    @discardableResult
    private func driveSliderToItsTop(_ label: String, attempts: Int = 3) -> Double? {
        driveTrail = []
        guard var reading = setSliderTrackPercent(label, to: 100.0) else { return nil }
        driveTrail.append("adjust->" + readingText(reading))
        if reading >= 99.5 { return reading }
        // One real touch ending on the element's own right edge, asked before anything is asked of the
        // geometry past it: this is the cheapest mechanism that can disagree with `adjust`, and it is
        // the one that says whether the top of the track is inside the element at all.
        if let edged = dragToTheRightEdgeOfTheTrack(label) { reading = edged }
        driveTrail.append("edge->" + readingText(reading))
        if reading >= 99.5 { return reading }
        var previous: Double?
        for _ in 0..<attempts {
            previous = reading
            // Past the end of the element: the one mechanism whose reading cannot be capped by where
            // the frame's own hundredth points land.
            if let dragged = dragPastTheEndOfTheTrack(label) { reading = dragged }
            driveTrail.append("drag->" + readingText(reading))
            if reading >= 99.5 { return reading }
            // Then the tap on the end of the track.
            if let tapped = tapTheEndOfTheTrack(label) { reading = tapped }
            driveTrail.append("tap->" + readingText(reading))
            if reading >= 99.5 { return reading }
            // Then the adjust again, from wherever that left the slider.
            if let again = setSliderTrackPercent(label, to: 100.0) { reading = again }
            driveTrail.append("adjust->" + readingText(reading))
            if reading >= 99.5 { return reading }
            // A whole round that improved on nothing ends the drive: what comes back is the state the
            // slider is in, never a high-water mark it has since fallen back from.
            if let before = previous, reading <= before + 0.01 { return reading }
        }
        return reading
    }

    /// Waits for the drawn A button's frame to satisfy `predicate`. A slider applies on the next
    /// layout pass rather than inside the touch, so the reading has to be waited for; a frame that
    /// never arrives is attached and failed rather than compared in silence.
    @discardableResult
    private func waitForDrawnAFrame(_ what: String, timeout: TimeInterval = 20,
                                    where predicate: (CGRect) -> Bool) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var last = app.buttons["A"].frame
        repeat {
            last = app.buttons["A"].frame
            if predicate(last) { return last }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        attachHierarchy("a-frame-never-changed")
        XCTFail("the drawn A button did not change " + what + "; it stayed at "
                + NSCoder.string(for: last))
        return nil
    }

    /// Waits for the drawn control's frame to satisfy `predicate`, returning the frame it is drawn
    /// at when the wait ends. Bounded, and it returns rather than fails: the assertions after it are
    /// what report a control that never moved or never came back, so a control the app has stopped
    /// drawing at all is the only case this helper speaks to on its own.
    @discardableResult
    private func waitForDrawnFrame(_ label: String, timeout: TimeInterval = 20,
                                   where predicate: (CGRect) -> Bool) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = overlayElement(label), predicate(element.frame) { return element.frame }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return overlayElement(label)?.frame
    }

    /// A real touch on the overlay's camera stick: a sustained press at its centre, dragged to its
    /// right edge. The vendored stick view reads `touchesBegan`/`touchesMoved`, so a press that
    /// moves is what produces a nonzero axis, and the press is held long enough that the port's
    /// per-frame poll sees it rather than only the frames around a tap.
    private func dragCameraStickRight() {
        let stick = app.otherElements["c"]
        guard stick.exists else {
            attachHierarchy("camera-stick-missing")
            XCTFail("the overlay's camera stick is on screen to be dragged")
            return
        }
        let start = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.8, thenDragTo: end)
    }

    /// R1 item 5, for the three settings whose only honest proof is a control that was drawn or a
    /// pad the port was handed, rather than a value in the store.
    ///
    /// Control size is decided here and now: the on-screen A button is measured before and after
    /// the drag, so a slider that reached only the store would leave the frame where it was, and a
    /// button that changed size is a button drawn at the new size. The direction is chosen from the
    /// reading rather than assumed, and the sequence is the panel's low end then its high end, so
    /// the two frames are compared with each other as well as with the resting one.
    ///
    /// Control opacity cannot move a frame -- it is a paint property -- so the half this row can
    /// decide is the negative one, that the geometry stays put; the positive half is the app's own
    /// read-back of the overlay it drew, which the run's settings row requires (an `overlay:` line
    /// per settled state, naming every control's alpha as drawn), and the alpha it names is the one
    /// this drag produced.
    ///
    /// The C-stick switch is the third: the drag makes the axis nonzero, and the app's `c-stick:`
    /// read-back prints the mixer's own value beside the value the port's pad was handed, so the run
    /// can require that the two agree with the switch off and disagree with it on.
    ///
    /// Both stored values are then read out of a fresh process, because in-process state cannot
    /// survive `app.terminate()` and a setting that came back would have had to be written down.
    func testTouchSettingsReachTheDrawnOverlay() throws {
        launchAndWaitForOverlay()
        openMenu()
        openTouchSettings()

        let aButton = overlayATitle()
        XCTAssertTrue(aButton.waitForExistence(timeout: 30), "the overlay A button is on screen")
        let resting = aButton.frame
        XCTAssertGreaterThan(resting.width, 0, "the A button is drawn with a real size")
        attach("touch-controls-at-rest")

        // -- Control size: the drawn control follows the track -----------------------------------
        let sizeAtRest = requireSliderPercent("Control size", "before anything is dragged")
        let smallFirst = sizeAtRest < 50.0
        setSliderTrackPercent("Control size", to: smallFirst ? 100.0 : 0.0)
        let sizeAfter = requireSliderPercent("Control size", "after the drag")
        XCTAssertNotEqual(sizeAfter, sizeAtRest, accuracy: 0.5,
                          "the size drag landed on the vendored slider")
        let resized = waitForDrawnAFrame("with the Control size slider") { frame in
            smallFirst ? frame.width > resting.width + 1.0 : frame.width < resting.width - 1.0
        }
        if let resized {
            XCTAssertNotEqual(resized.width, resting.width, accuracy: 0.5,
                              "the drawn A button is a different width at the new size ("
                              + NSCoder.string(for: resting) + " then "
                              + NSCoder.string(for: resized) + ")")
        }
        attach("control-size-changed")

        // -- Control opacity: the drawn control keeps its geometry -------------------------------
        let opacityAtRest = requireSliderPercent("Control opacity", "before anything is dragged")
        let frameBeforeOpacity = app.buttons["A"].frame
        setSliderTrackPercent("Control opacity", to: 0.0)
        let opacityAfter = requireSliderPercent("Control opacity", "after the drag")
        XCTAssertNotEqual(opacityAfter, opacityAtRest, accuracy: 0.5,
                          "the opacity drag landed on the vendored slider")
        assertFrameClose(app.buttons["A"].frame, frameBeforeOpacity, accuracy: 1.0,
                         "opacity is a paint setting, so the drawn A button stays put")
        attach("control-opacity-changed")

        // -- The camera stick's own axis, turned under both conventions ---------------------------
        let modernSwitch = app.switches["Modern C-stick left and right"]
        XCTAssertTrue(modernSwitch.waitForExistence(timeout: 10),
                      "the Modern C-stick left and right switch is present")
        if (modernSwitch.value as? String) != "0" { modernSwitch.tap() }
        dragCameraStickRight()
        if (modernSwitch.value as? String) != "1" { modernSwitch.tap() }
        dragCameraStickRight()
        attach("c-stick-both-conventions")
        if (modernSwitch.value as? String) != "0" { modernSwitch.tap() }

        // -- Both stored values survive a fresh process -------------------------------------------
        app.terminate()
        launchAndWaitForOverlay()
        openMenu()
        openTouchSettings()
        XCTAssertEqual(requireSliderPercent("Control size", "after a relaunch"), sizeAfter,
                       accuracy: 1.0,
                       "the size the drag chose survived a termination and a fresh launch")
        XCTAssertEqual(requireSliderPercent("Control opacity", "after a relaunch"), opacityAfter,
                       accuracy: 1.0, "and so did the opacity")
        attach("touch-settings-after-relaunch")

        // Put back what this row moved. The suite's other rows read these controls, so the panel is
        // left where the earlier rows found it.
        setSliderTrackPercent("Control size", to: sizeAtRest)
        setSliderTrackPercent("Control opacity", to: opacityAtRest)
    }

    // MARK: - Each shoulder draws its own press (R1 item 5, the L/R half of the interface gate)

    /// The claim this row decides is the one a screenshot alone leaves ambiguous: pressing one
    /// shoulder draws that shoulder's own outline and nothing on the other. The overlay paints the
    /// vendored trigger's *detent* as a thicker border (3.0 against 2.0 below the detent), so "which
    /// shoulder is drawn at its detent" is a value the app can print, and the run's
    /// `shoulder outline:` lines are where it prints it.
    ///
    /// The press lands near the control's edge rather than at its centre, and that is the vendored
    /// behaviour rather than a convenience: `SunPadTriggerButton -updateFromTouch:` decides `_fullPress`
    /// from the touch's *position* across the control's width (the detent starts at 0.75 of the width,
    /// `SunPadTriggerDetentEnter`), and "position >= detent" is exactly the state the thicker border
    /// draws. A press at the centre therefore renders no press indicator at all, and a row that pressed
    /// there would be measuring nothing. 0.95 of the width clears the detent with margin.
    ///
    /// What the test itself reads is the other half: a press is a paint property, so neither shoulder
    /// may move, and both must be on screen and hittable for the press to have landed on them at all.
    /// The screenshots are the human-readable side of the same claim, and the run fails its read-back
    /// row if the log never shows a pair that differs, or shows a pair where both shoulders carry the
    /// press width at once -- the fault this row exists to catch.
    func testShoulderPressDrawsOnOneShoulderOnly() throws {
        launchAndWaitForOverlay()

        let left = app.buttons["L"]
        let right = app.buttons["R"]
        XCTAssertTrue(left.waitForExistence(timeout: 30), "the overlay's L shoulder is on screen")
        XCTAssertTrue(right.waitForExistence(timeout: 30), "the overlay's R shoulder is on screen")
        XCTAssertTrue(left.isHittable, "L is hittable, so the press below reaches it")
        XCTAssertTrue(right.isHittable, "R is hittable, so the press below reaches it")

        let leftAtRest = left.frame
        let rightAtRest = right.frame
        XCTAssertGreaterThan(leftAtRest.width, 0, "L is drawn with a real width")
        XCTAssertEqual(leftAtRest.width, rightAtRest.width, accuracy: 1.0,
                       "the two shoulders are drawn the same width at rest ("
                       + NSCoder.string(for: leftAtRest) + " and "
                       + NSCoder.string(for: rightAtRest) + ")")

        // The operator's claim is that R looks like the left shoulder, and the *placement* is the
        // half a width comparison cannot see: the pair matched in size, corner and border while R
        // was still drawn on its own row and its own distance from the edge, which is what a second,
        // differently-positioned copy of the same shape looks like. The repair places R from L's own
        // live frame on the surface, so the surface's two gaps are equal and the two shoulders share
        // a row. The reading is taken here in screen points against the window the surface fills, and
        // the app's own `shoulder:` read-back states the same relation in the surface's coordinates,
        // where the numbers are computed beside the repair that applies them.
        let surface = app.windows.firstMatch.frame
        let leftGap = leftAtRest.minX - surface.minX
        let rightGap = surface.maxX - rightAtRest.maxX
        XCTAssertEqual(leftGap, rightGap, accuracy: 2.0,
                       "R is placed as L's mirror across the surface, so the gap from the left edge "
                       + "to L (" + String(Double(leftGap)) + ") is the gap from R to the right edge ("
                       + String(Double(rightGap)) + ")")
        XCTAssertEqual(leftAtRest.minY, rightAtRest.minY, accuracy: 1.0,
                       "and the two shoulders are drawn on the same row ("
                       + String(Double(leftAtRest.minY)) + " against "
                       + String(Double(rightAtRest.minY)) + ")")
        attach("shoulders-at-rest")

        left.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press(forDuration: 0.5)
        attach("left-shoulder-pressed")
        Thread.sleep(forTimeInterval: 0.5)
        assertFrameClose(left.frame, leftAtRest, accuracy: 1.0,
                         "a press is paint, so L stays where it was")
        assertFrameClose(right.frame, rightAtRest, accuracy: 1.0,
                         "and pressing L leaves R where it was")

        right.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press(forDuration: 0.5)
        attach("right-shoulder-pressed")
        Thread.sleep(forTimeInterval: 0.5)
        assertFrameClose(left.frame, leftAtRest, accuracy: 1.0,
                         "and pressing R leaves L where it was")
        assertFrameClose(right.frame, rightAtRest, accuracy: 1.0,
                         "R keeps its own frame through its own press too")

        // Both presses have been made, and the run reads the app's own outline lines from them. The
        // pause lets the overlay settle back to rest, so the last state the log records is the
        // resting one and the differing pair the run requires is not buried under a later frame.
        Thread.sleep(forTimeInterval: 1.0)
        attach("shoulders-after-both-presses")
    }

    // MARK: - The rotated relayout (F06)

    /// F06's rotation half. This app is landscape-only, so the orientation it can be turned to is the
    /// *other* landscape side, and that is the transition worth exercising: it is the moment the
    /// surface is laid out again, so it is where a layout can drop a control, push one off the
    /// screen, or leave the two shoulders mismatched. Editing, resizing, opacity, reset and their
    /// persistence are the neighbouring rows; what is unexercised without this one is the relayout.
    ///
    /// What is claimed after the turn is that the layout still *fits*: the whole control set is still
    /// drawn, every control is still hittable and still inside the window, the two shoulders are
    /// still each other's mirror about the surface's vertical axis, and the port's display read-back
    /// still reports the same render target -- a turn that rebuilt the surface would show up there
    /// rather than in a control's arithmetic.
    ///
    /// What is deliberately *not* claimed is that any control moved. Measured from the app's side of
    /// the boundary, in the run's own `layout:` line, this device publishes the same view-space safe
    /// inset on both landscape sides -- `safe 47.0,0.0,47.0,20.0` on the phone, symmetrically, in
    /// each -- so UIKit hands the overlay the same safe rect either way and the correct placement of
    /// every control is the same coordinate. An assertion that a control had moved would therefore
    /// be an assertion of a defect. The containment verdict lives where the insets actually are: the
    /// app writes the rect it was handed, and every drawn control's rect against it, and the runner
    /// judges those lines rather than taking this process's word for arithmetic it cannot see.
    func testTurnToTheOtherLandscapeSideKeepsEveryControlInsideAndHittable() throws {
        launchAndWaitForOverlay()
        // Judged against the app's own default layout, established here rather than inherited: the
        // rows before this one persist the sizes they drive, and the turn is what this row is about.
        // See -resetTouchControlLayout for the measurement that made this necessary.
        resetTouchControlLayout()
        // The counter's label is where the port publishes its display read-back, so turning it on is
        // what makes the drawable readable from out here as well as in the app's log.
        setFPSCounter(true)

        guard waitForIdentifier("BallpadFPSCounter", timeout: 20) != nil else {
            attachHierarchy("fps-counter-missing-before-rotation")
            XCTFail("the FPS counter is drawn, so the port's display read-back is readable")
            return
        }

        XCTAssertTrue(waitForOverlayElement("L", timeout: 30) != nil, "L is on screen before the turn")

        let displayBefore = displayReadBack()
        XCTAssertNotNil(displayBefore, "the port's display read-back is readable before the turn")
        attach("rotation-before")
        attachHierarchy("rotation-before-hierarchy")

        // The turn. `landscapeRight` is the opposite side of the default `landscapeLeft`, and the
        // app declares both, so iOS performs a real rotation rather than refusing it.
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = .landscapeLeft }

        // Waited for by the tree settling rather than by a sleep: the surface is laid out again over
        // the frames that follow the turn, so the readings below are taken only once the whole
        // control set has answered with the same frames twice in a row.
        waitForTheControlSetToSettle()
        attach("rotation-after")
        attachHierarchy("rotation-after-hierarchy")

        // The whole control set, not only the pair: a rotation that dropped a control would otherwise
        // pass on a screenshot that looks plausible.
        var frames: [String: CGRect] = [:]
        for control in Self.rotationControls {
            // Resolved by label across the collections the overlay publishes into, because the set is
            // mixed: the two analog sticks are plain views and the buttons are buttons, and the claim
            // here is about the control rather than about which collection it lands in.
            guard let element = waitForOverlayElement(control, timeout: 10) else {
                XCTFail("the " + control + " control is drawn after the turn")
                continue
            }
            frames[control] = element.frame
            // A control that is not hittable is named together with whatever covers it, because the
            // two are different findings and should not read alike: a control the turn misplaced is a
            // relayout defect, while a control covered by one the tree has drawn over it is a property
            // of the sizes, which is the neighbour rows' subject and not this one's.
            let covered = element.isHittable ? "" : " covered-by " + (frames
                .filter { $0.key != control && $0.value.contains(element.frame) }
                .keys.sorted().joined(separator: ","))
            XCTAssertTrue(element.isHittable,
                          "the " + control + " control is still hittable after the turn; it is drawn at "
                          + NSCoder.string(for: element.frame) + "." + covered)
        }
        XCTAssertEqual(frames.count, Self.rotationControls.count,
                       "every control in the overlay's set survived the turn")

        // Inside the window: the surface is the window, so a control drawn outside it is drawn off
        // the screen however correct its inset arithmetic was.
        let surface = app.windows.firstMatch.frame
        for (control, frame) in frames {
            XCTAssertTrue(surface.contains(frame) || surface.insetBy(dx: -1, dy: -1).contains(frame),
                          "the " + control + " control is drawn inside the window after the turn: "
                          + NSCoder.string(for: frame) + " against " + NSCoder.string(for: surface))
        }

        // And the pair is still L's twin on the other side of the surface, which is the relation the
        // shoulder row reads at rest: a turn that re-placed one shoulder while keeping the other's
        // old frame would leave them mismatched on exactly one landscape side.
        let leftAfter = frames["L"] ?? .zero
        let rightAfter = frames["R"] ?? .zero
        XCTAssertEqual(leftAfter.minX - surface.minX, surface.maxX - rightAfter.maxX, accuracy: 2.0,
                       "the shoulders keep their mirrored placement after the turn")
        XCTAssertEqual(leftAfter.minY, rightAfter.minY, accuracy: 1.0,
                       "and they are still on the same row after the turn")

        // The engine is still the one engine: the port's display read-back is still readable and the
        // render target keeps its shape, so the turn did not lose the drawable or bring up a second
        // surface. The counter's own text moving is the "still running" half.
        let running = waitForDisplay("a reading after the turn", timeout: 20) { _ in true }
        XCTAssertEqual(running?.width, displayBefore?.width,
                       "the render target keeps its width across the turn")
        XCTAssertEqual(running?.height, displayBefore?.height,
                       "and its height, so the drawable was not recreated at another shape")
    }

    /// A bounded wait for a layout in flight to stop changing, so that what is read afterwards
    /// describes one tree rather than two frames of a moving one -- whether the tree is moving
    /// because the device was turned or because a size was changed. It returns as soon as the whole
    /// control set has answered with the same frames twice in a row, and it is what lets the app's
    /// own settled-layout read-back write a line for the state being judged.
    ///
    /// A timeout is deliberately not asserted here: an unsettled tree is what the assertions after
    /// the wait are for, and failing here as well would report the same defect twice. The wait is
    /// still bounded, so a tree that never settles costs a report rather than a hang.
    private func waitForTheControlSetToSettle(timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [String: CGRect] = [:]
        repeat {
            var current: [String: CGRect] = [:]
            for control in Self.rotationControls {
                if let element = overlayElement(control) { current[control] = element.frame }
            }
            if current.count == Self.rotationControls.count && current == previous { return }
            previous = current
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
    }

    // MARK: - The size extremes (F06)

    /// F06's resizing half, driven to the largest size the panel can produce and held there.
    ///
    /// The claim this row is about is containment -- that no control is drawn outside the region the
    /// surface itself calls safe -- and the only process that can decide it is the app: the safe rect
    /// is UIKit's answer to the overlay's own `-safeAreaInsets`, and a test process is never told it.
    /// So this test puts the tree into the state the claim is *about*, waits for the layout to stop
    /// moving so that the app writes a settled `layout:` line for it, and leaves the judging to the
    /// run's containment clauses over those lines.
    ///
    /// That state is the size extremes, and it is not incidental coverage. A vendored default is a
    /// normalized centre captured at a size scale of 1.0, so a control whose default sits on the safe
    /// edge at 1.0 grows straight out of the safe rect when the scale is raised, and nothing in the
    /// vendored default pass clamps a control it was never given a saved origin for. Measured on the
    /// iPhone 17e before the containment repair, Z was drawn 7.5pt past the safe rect's right edge
    /// with the panel's slider at its maximum -- and because the scale is persisted, that reading
    /// survived a relaunch. Both size controls are driven here because they are two different paths
    /// into the layout: the panel's slider scales the whole set through `-sizeChanged:`, and the
    /// editor's scales one control through `-selectedSizeChanged:` and runs to a larger factor.
    ///
    /// The row ends with the vendored reset, which is what makes the two claims one claim: the size
    /// driven to its maximum has to come back to the default the layout started at, and the control
    /// with it. The starting state is normalized to that default first, so "at the default" is a
    /// frame this test measured rather than one it assumed.
    ///
    /// One flake is on record and it is not unexplained: `uitest-pad-pad-final-r1` read this row
    /// short of its band once, before the orientation pin above was in the bundle, and it passed on
    /// the immediate re-run and on every run since (`pad-final-r2`, `phone-final-r1`). The band was
    /// left where it was; the fix was the ruler, per the note at the top of this file.
    func testTheLargestControlSizeThePanelOffersIsStillInsideTheSafeArea() throws {
        launchAndWaitForOverlay()
        openMenu()
        openTouchSettings()

        // The vendored default, as the slider's own percentage: 0.70 + 0.4615 * 0.65 = 1.00. Pinning
        // it here makes the frame below a reading of the default rather than of whatever an earlier
        // row left in the store.
        setSliderTrackPercent("Control size", to: 46.0)
        guard let zAtDefault = overlayElement("Z")?.frame else {
            attachHierarchy("z-missing-before-the-size-drag")
            XCTFail("the overlay's Z button is drawn before any size is driven")
            return
        }

        // -- The panel's slider, at its maximum: the whole set grows, edge control included -------
        attachNote("control-size-before-the-drive", sliderDiagnostics("Control size"))
        let panelMaximum = driveSliderToItsTop("Control size")
        attachNote("control-size-drive-trail",
                   driveTrail.joined(separator: " ") + " || " + sliderDiagnostics("Control size"))
        XCTAssertEqual(panelMaximum ?? -1.0, 100.0, accuracy: 0.5,
                       "the Control size slider is at its maximum; it stopped at "
                       + String(format: "%.1f", panelMaximum ?? -1.0) + "% -- "
                       + driveTrail.joined(separator: " "))
        let atPanelMaximum = waitForDrawnFrame("Z") { $0.width > zAtDefault.width + 1.0 }
        XCTAssertNotNil(atPanelMaximum, "Z is still drawn with the Control size slider at its maximum")
        if let grown = atPanelMaximum {
            XCTAssertGreaterThan(grown.width, zAtDefault.width + 1.0,
                                 "Z is drawn larger with the slider at its maximum ("
                                 + NSCoder.string(for: zAtDefault) + " then "
                                 + NSCoder.string(for: grown) + ")")
        }
        waitForTheControlSetToSettle()
        attach("control-size-maximum")

        // -- The editor's per-control slider, which overrides that for a single control ----------
        let moveSwitch = app.switches["Move touch controls"]
        XCTAssertTrue(moveSwitch.waitForExistence(timeout: 10), "the Move touch controls switch")
        if (moveSwitch.value as? String) != "1" { moveSwitch.tap() }
        if !app.buttons["Finish moving touch controls"].waitForExistence(timeout: 12) {
            attachHierarchy("move-controls-after-first-tap")
            if moveSwitch.exists && moveSwitch.isHittable { moveSwitch.tap() }
        }
        XCTAssertTrue(app.buttons["Finish moving touch controls"].waitForExistence(timeout: 30),
                      "the layout editor bar appears once moving is on")

        guard let z = overlayElement("Z") else {
            attachHierarchy("z-missing-in-the-editor")
            XCTFail("Z is on screen to be selected for resizing")
            return
        }
        z.tap()
        // Selecting re-labels the editor's slider after the control it now sizes, so this is also the
        // read-back that the selection landed: it is the control's own name that appears.
        let selectedSize = app.sliders["Z size"]
        XCTAssertTrue(selectedSize.waitForExistence(timeout: 10),
                      "tapping Z selects it and the editor sizes that control")
        attachNote("z-size-before-the-drive", sliderDiagnostics("Z size"))
        let zMaximum = driveSliderToItsTop("Z size")
        let zTrail = driveTrail.joined(separator: " ")
        attachNote("z-size-drive-trail", zTrail + " || " + sliderDiagnostics("Z size"))
        XCTAssertEqual(zMaximum ?? -1.0, 100.0, accuracy: 0.5,
                       "the selected control's size slider is at its maximum; it stopped at "
                       + String(format: "%.1f", zMaximum ?? -1.0) + "% -- " + zTrail
                       + " || " + sliderDiagnostics("Z size"))
        let atLargest = waitForDrawnFrame("Z") { $0.width > (atPanelMaximum?.width ?? 0) + 1.0 }
        XCTAssertNotNil(atLargest, "Z is still drawn with its own size slider at its maximum")
        if let grown = atLargest, let previous = atPanelMaximum {
            XCTAssertGreaterThan(grown.width, previous.width + 1.0,
                                 "Z is drawn larger again with its own size at its maximum ("
                                 + NSCoder.string(for: previous) + " then "
                                 + NSCoder.string(for: grown) + ")")
            // On screen is the weaker claim and is checked here rather than left to the run: the
            // window is a larger rectangle than the safe rect, so this cannot stand in for the
            // containment clause, but a control drawn off the screen entirely would be a different
            // failure from a control drawn under the notch and the two should not look alike.
            let surface = app.windows.firstMatch.frame
            XCTAssertTrue(surface.contains(grown),
                          "Z is still drawn inside the window at its largest ("
                          + NSCoder.string(for: grown) + " against " + NSCoder.string(for: surface) + ")")
        }
        waitForTheControlSetToSettle()
        attach("z-size-maximum")
        app.buttons["Finish moving touch controls"].tap()
        XCTAssertFalse(app.buttons["Finish moving touch controls"].exists,
                       "finishing editing leaves the layout editor")

        // -- The vendored reset returns both scales, and the control with them -------------------
        openMenu()
        openTouchSettings()
        let resetButton = app.buttons["Reset This Device Layout"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 10), "the reset button")
        resetButton.tap()
        let alert = app.alerts["Reset Touch Control Layout?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the reset confirmation alert")
        alert.buttons["Reset"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 3), "Reset dismisses the alert")
        waitForTheControlSetToSettle()
        XCTAssertEqual(requireSliderPercent("Control size", "after the reset"), 46.0, accuracy: 1.0,
                       "the reset put the control size back at the vendored default")
        if let zNow = overlayElement("Z")?.frame {
            assertFrameClose(zNow, zAtDefault,
                             "Z is back at the default the reset restored, having been drawn at its "
                             + "largest twice")
        } else {
            attachHierarchy("z-missing-after-the-reset")
            XCTFail("Z is still drawn after the layout reset")
        }
        attach("z-after-reset")
    }

    // MARK: - What the engine's own pad held (F04)

    /// A real touch on the overlay's main stick, dragged to its right edge and *held* there. The
    /// hold is the whole point of the variant used: the port reads the pad once a frame and the
    /// engine's own pad is the sample one assembly boundary later, so a displacement that exists for
    /// a single frame can be gone before the reading that has to see it. The vendored stick view
    /// resets its axis in `-touchesEnded`, so a finger that is still down keeps the axis where it
    /// left it, and the drag is held for a second after it arrives.
    private func holdMainStickRight() {
        let stick = app.otherElements["move"]
        guard stick.exists else {
            attachHierarchy("move-stick-missing")
            XCTFail("the overlay's main stick is on screen to be dragged")
            return
        }
        let start = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .default,
                    thenHoldForDuration: 1.0)
    }

    /// F04, the half a screenshot cannot decide. A press that the overlay *draws* is proven by the
    /// screenshot; a press the *game read* is a different fact, and doc 34 asks for the second one.
    /// Every control the row names is therefore pressed as a real touch on the real surface, held
    /// long enough for the port's per-frame poll to carry it, and the run's `consume:` read-back
    /// family is where the verdict lives: those lines are the port's own report of what
    /// `PadStatus::s_Current[0]` -- the sample `cPlatPad::IsPressed` and the game's own tasks read --
    /// held, printed beside what the host offered for the same frame.
    ///
    /// The main stick and the C-stick are driven the same way, each as a real drag that is held
    /// off-centre rather than a synthetic axis, because a stick is the control whose value a press
    /// cannot stand in for. Both shoulders are included: L is the vendored button and R is the
    /// trigger with BallPad's own wiring onto it, and the row is where the two are checked to reach
    /// the same pad.
    ///
    /// What this row does *not* claim, stated rather than left to a reader to notice: XCUIAutomation's
    /// public headers expose no multi-touch, so the main stick and an action button cannot be held at
    /// the same instant by two real touches here. Simultaneity is a property of the merge boundary
    /// (one `SunPadInputState` carrying both the buttons and the axes, and one port pad built from
    /// it), it is exercised directly at that boundary by the port's own control channel, and the
    /// physical-controller half of it stays F12 until there is a controller to hold.
    func testEveryControlReachesTheEnginesOwnPad() throws {
        launchAndWaitForOverlay()

        // Every control doc 34 names, in the overlay's own identifiers. The D-pad's four keys are
        // separate controls in the drawn overlay and separate bits in the pad, so they are separate
        // presses; a single pass at the middle of the D-pad would leave three of the four unread.
        let controls = ["A", "B", "X", "Y", "Z", "Start", "D_U", "D_D", "D_L", "D_R", "L", "R"]
        attach("controls-before-the-sweep")
        for name in controls {
            let control = app.buttons[name]
            guard control.waitForExistence(timeout: 60) else {
                attachHierarchy("control-\(name)-missing")
                XCTFail("the overlay's \(name) control is on screen to be pressed")
                return
            }
            XCTAssertTrue(control.isHittable, "\(name) is hittable, so the press below reaches it")
            let resting = control.frame
            // Near the control's edge rather than at its centre, because that is where the vendored
            // trigger's detent begins and where the *drawn* press is; the bit the engine reads is set
            // for a touch anywhere on the control, so the same press answers both questions. It is
            // held for half a second, which is dozens of frames at the front end's rate and is the
            // same order as a deliberate player press.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
                .press(forDuration: 0.5)
            Thread.sleep(forTimeInterval: 0.3)
            // A press is a paint property: the control stays where it was drawn, so anything that
            // moved here is a layout fault rather than a press, and it would also mean the frame the
            // row compared next was not the one it started from.
            assertFrameClose(control.frame, resting, accuracy: 1.0,
                             "pressing \(name) leaves it where it was drawn")
        }
        attach("controls-after-the-sweep")

        holdMainStickRight()
        attach("main-stick-held-right")
        Thread.sleep(forTimeInterval: 0.3)

        dragCameraStickRight()
        attach("camera-stick-dragged-right")
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Every row of the panel is a row that does something (R1 rows 5, 11, 12; R2)

    /// The three submenus, in the vendored order, with every leaf each of them must publish. The
    /// list is the audit's whole expectation, and it is written as an equality rather than a
    /// membership test for one reason: a menu row that ships with no label, or a placeholder row
    /// left where a removed one was, is a row a player cannot read and cannot use, and both of
    /// those are what an exact match catches and a subset check does not.
    ///
    /// What this row does *not* claim is that each leaf works. That is what the leaves' own rows
    /// are for, and each one has one: the two aspect rows and the resolution rows are driven and
    /// read back in testDisplayRowsReachTheRenderer, the frame-rate row in
    /// testFrameRateLimitRowReachesThePortsLimiter, and the audio row, which is the one that
    /// replaced the vendored performance row, in testAudioRecordingRowReportsTheMixersOwnState.
    /// The render scale leaves come from the one constant the scale row already owns, so the label
    /// spelling is not repeated here.
    private static let vendoredSubmenuLeaves: [(submenu: String, leaves: [String])] = [
        ("Render Resolution", [BallpadSunPadInterfaceTests.renderScaleSegments[0] + " (Native)",
                               BallpadSunPadInterfaceTests.renderScaleSegments[1],
                               BallpadSunPadInterfaceTests.renderScaleSegments[2],
                               BallpadSunPadInterfaceTests.renderScaleSegments[3]]),
        ("Aspect Ratio", ["Original 4:3", "16:9 (Experimental)", "Fill Screen (Experimental)"]),
        ("Experimental", ["Uncapped Frame Rate", "Record Audio (Experimental)"]),
        ("Game Data & Saves", ["Import or Reimport Game Data", "Import from BallPad Folder",
                               "Remove Stored Game Data"]),
    ]

    /// Every row the open panel publishes, in the order it publishes them, taken from the label the
    /// row actually carries. A row with no label contributes an empty string rather than dropping
    /// out of the list, and that is the reason this is built from the cells themselves instead of
    /// from a query for labelled buttons: a query for labelled rows answers "every row is labelled"
    /// by finding nothing at all.
    private func publishedMenuRows() -> [String] {
        var rows: [String] = []
        for cell in app.collectionViews.firstMatch.cells.allElementsBoundByIndex {
            let button = cell.buttons.firstMatch
            rows.append(button.exists ? button.label : cell.label)
        }
        return rows
    }

    /// Whether a menu panel is on screen at all: the vendored panel is a collection view, so a
    /// published cell is the reading, and a panel that has been put away has neither.
    private func menuIsPresented() -> Bool {
        app.collectionViews.firstMatch.cells.firstMatch.exists
    }

    /// Closes the panel the way a player closes it: the three-dot button raised it, and tapping that
    /// button again puts it away. The loop is bounded and re-reads the tree between passes; the
    /// fallback aims at the top-left corner, which is neither the button nor any row of a panel
    /// anchored to it. No leaf is ever tapped here -- leaving the menu without choosing anything is
    /// the whole point of the callers.
    private func dismissMenu() {
        for round in 0..<3 {
            guard menuIsPresented() else { return }
            if round == 0 {
                menuButton.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.02)).tap()
            }
            let deadline = Date().addingTimeInterval(5)
            repeat {
                if !menuIsPresented() { return }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline
        }
        attachHierarchy("menu-would-not-close")
    }

    /// R1 rows 5, 6, 7 and 9, read from the menu's own side: every submenu publishes exactly the
    /// leaves it is supposed to publish, spelled the way the vendored interface spells them. The
    /// comparison is an equality rather than a membership test for one reason -- a row that ships
    /// without a label, or a placeholder left in a removed row's place, is a row a player cannot
    /// read and cannot use, and both of those survive a membership test and fail this one.
    ///
    /// What this row does not claim is that each leaf works; each leaf has a row of its own for
    /// that. The resolution and aspect leaves are driven and read back in
    /// testDisplayRowsReachTheRenderer, the frame-rate row in
    /// testFrameRateLimitRowReachesThePortsLimiter, the audio row that took the retired row's slot
    /// in testAudioRecordingRowReportsTheMixersOwnState, and the three game-data leaves are driven,
    /// refused and confirmed in the Files importer rows below. The retired performance row's absence
    /// is re-read here, so the slot it left is checked from both sides.
    func testEverySubmenuPublishesItsLabelledLeaves() throws {
        launchAndWaitForOverlay()

        for submenu in Self.vendoredSubmenuLeaves {
            ensureMenuOpen()
            guard let row = scrollMenuForElement(submenu.submenu, timeout: 20) else {
                attachHierarchy("submenu-row-missing")
                XCTFail("the " + submenu.submenu + " row is in the menu")
                continue
            }
            row.tap()

            guard waitForOverlayElement(submenu.leaves[0], timeout: 20) != nil else {
                attachHierarchy("submenu-would-not-open")
                XCTFail("the " + submenu.submenu + " submenu opens")
                continue
            }

            // The cells arrive with the panel, so this waits for the list to reach its final
            // length before reading it: a reading taken mid-presentation would compare a half-built
            // list against a whole one. The assertion below is still an equality, so a wrong list
            // cannot pass by being waited for.
            var rows = publishedMenuRows()
            let deadline = Date().addingTimeInterval(15)
            repeat {
                rows = publishedMenuRows()
                if rows.count == submenu.leaves.count { break }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline

            attach("submenu-leaves-" + submenu.submenu)
            attachHierarchy("submenu-leaves-" + submenu.submenu)
            XCTAssertEqual(rows, submenu.leaves,
                           "the " + submenu.submenu + " submenu publishes exactly its own leaves")
            XCTAssertNil(overlayElement("Experimental Performance Mode (Restart Required)"),
                         "no panel publishes the retired performance row (R1 row 12)")
            dismissMenu()
        }
    }

    /// The first run of digits in `text` that is followed by a space and `suffix`, or nil. This is
    /// how the stop alert's frame count is read without depending on the alert's wording: a number
    /// sitting next to its unit is the number, and a sentence that names none yields nil.
    private func firstInteger(in text: String, before suffix: String) -> Int? {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index].isNumber else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end].isNumber { end += 1 }
            let digits = String(characters[index..<end])
            let rest = String(characters[end...])
            if rest.hasPrefix(" " + suffix), let value = Int(digits) { return value }
            index = end
        }
        return nil
    }

    /// What a WAV on the disk actually holds, read here rather than taken from the alert that
    /// described it. The audio row's claim is about bytes, and this is the reader that makes the
    /// claim checkable: the header has to parse, the data chunk has to be the length the row named,
    /// and the loudest sample has to be what the row said it was.
    private struct WavReading {
        let dataFrames: Int
        let channels: Int
        let sampleRate: Int
        let bitsPerSample: Int
        let peak: Int
    }

    private func readWav(at path: String) -> WavReading? {
        guard let data = FileManager.default.contents(atPath: path), data.count >= 44 else {
            return nil
        }
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16
                | Int(bytes[at + 3]) << 24
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        guard String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { return nil }

        var channels = 0
        var sampleRate = 0
        var bits = 0
        var offset = 12
        while offset + 8 <= bytes.count {
            let tag = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            if tag == "fmt ", offset + 24 <= bytes.count {
                channels = u16(offset + 10)
                sampleRate = u32(offset + 12)
                bits = u16(offset + 22)
            } else if tag == "data" {
                let available = max(0, (bytes.count - (offset + 8)) / 2)
                let samples = min(size / 2, available)
                var peak = 0
                for index in 0..<samples {
                    let raw = u16(offset + 8 + index * 2)
                    let value = raw >= 0x8000 ? 65536 - raw : raw
                    if value > peak { peak = value }
                }
                let bytesPerFrame = max(1, channels * bits / 8)
                return WavReading(dataFrames: size / bytesPerFrame, channels: channels,
                                  sampleRate: sampleRate, bitsPerSample: bits, peak: peak)
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }

    /// The file the start alert named, taken out of the sentence that introduces it. The row prints
    /// the absolute path it opened, and the point of pulling it back out here is to open the same
    /// file rather than one this test went looking for.
    private func recordedPath(in text: String, after marker: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        let token = text[start.upperBound...].prefix { !$0.isWhitespace }
        return token.hasSuffix(".wav") ? String(token) : nil
    }

    /// Taps the audio recording row and returns the alert it raised as its title and its body. The
    /// row is looked up again on every tap because the menu is rebuilt after each one -- the handler
    /// calls -refreshMenuButton, which re-reads the mixer and re-composes the row's checkmark -- so
    /// an element held across two taps would be describing a menu that no longer exists.
    @discardableResult
    private func tapAudioRow(_ what: String) -> (title: String, message: String) {
        ensureMenuOpen()
        // The row lives in the Experimental submenu, so each walk opens that submenu first. The
        // walk is repeated on every tap rather than cached for the same reason the row lookup is:
        // the handler calls -refreshMenuButton, which re-reads the mixer and re-composes the row's
        // checkmark, so an element (or an open submenu) held across two taps would be describing a
        // menu that no longer exists.
        tapMenuRow("Experimental")
        guard let row = scrollMenuForElement("Record Audio (Experimental)", timeout: 20) else {
            attachHierarchy("audio-row-missing")
            XCTFail("the audio recording row is in the menu (" + what + ")")
            return (title: "", message: "")
        }
        row.tap()

        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 30) else {
            attachHierarchy("audio-alert-missing")
            XCTFail("the audio row raises an alert (" + what + ")")
            return (title: "", message: "")
        }
        // iOS publishes the title as the alert's own label and the body beneath it. Some versions
        // repeat the title as the first static text; a repeat is dropped so the body is the body.
        var labels = alert.staticTexts.allElementsBoundByIndex.map(\.label)
        let title = alert.label.isEmpty ? (labels.first ?? "") : alert.label
        if labels.first == title { labels.removeFirst() }
        let message = labels.joined(separator: " ")

        attach("audio-alert-" + what)
        alert.buttons["OK"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 5), "OK dismisses the audio alert")
        return (title: title, message: message)
    }

    /// R2, the audio row. The vendored slot held a switch that slowed an emulated CPU by ten per
    /// cent, and this runtime has no emulated clock to slow -- shipping that switch would be the
    /// inert row doc 33 forbids, and rebuilding it under a nicer name would be the same switch with
    /// a better label. The port does have its own mixer and its own transport, though, and the
    /// honest experimental thing to expose from them is the one operation a player can check for
    /// themselves: record exactly the bytes the audio device is handed, which is what turns "the
    /// game is making a sound" and "the sound is the one the models on screen are making" into two
    /// questions instead of one.
    ///
    /// The row's claim is that it reports the mixer rather than remembering what the last tap asked
    /// for, and this is built so that a device-less run and a live one prove it in opposite
    /// directions. With a device open the two taps are the two halves of one take: the first says it
    /// started, and the second says it stopped and names the frames it wrote, read out of the alert
    /// and required to be positive, together with the mixer's own rate. Without a device both taps
    /// give the same reading, and that equality is exactly the claim -- a row that had toggled a
    /// remembered flag would answer the second tap differently from the first.
    func testAudioRecordingRowReportsTheMixersOwnState() throws {
        launchAndWaitForOverlay()

        let started = tapAudioRow("start")
        XCTAssertFalse(started.title.isEmpty, "the audio row names what it did")

        if started.title == "Recording" {
            // The take needs mixer time before it has a length: the recorder is stopped by a tap,
            // and the count belongs to whatever the mixer handed over in between. This waits that
            // out instead of asserting on a race, and the number below is still the mixer's own.
            Thread.sleep(forTimeInterval: 3)

            let stopped = tapAudioRow("stop")
            XCTAssertEqual(stopped.title, "Recording Stopped",
                           "the second tap stops the take the first one started")
            let frames = firstInteger(in: stopped.message, before: "frames,")
            XCTAssertNotNil(frames, "the stop alert names the frames it wrote: " + stopped.message)
            XCTAssertGreaterThan(frames ?? 0, 0,
                                 "the take is a recording and not an empty file: " + stopped.message)
            XCTAssertTrue(stopped.message.contains("32000 Hz"),
                          "the stop alert names the mixer's own rate: " + stopped.message)
            XCTAssertTrue(stopped.message.contains("Files"),
                          "the stop alert says where the file is: " + stopped.message)

            // The row promises a file, so the file is opened and measured instead of being
            // inferred from the counter the alert printed. A take whose bytes never reached the
            // disk, a header that disagrees with the length the alert named, or an audibility
            // sentence the samples contradict all fail here, and the counter alone would pass all
            // three.
            if let path = recordedPath(in: started.message, after: "given to: ") {
                XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                              "the take is where the start alert said it would be: " + path)
                guard let wav = readWav(at: path) else {
                    XCTFail("the take parses as a RIFF/WAVE file: " + path)
                    return
                }
                XCTAssertEqual(wav.channels, 2, "the take is stereo: " + path)
                XCTAssertEqual(wav.sampleRate, 32000,
                               "the take is at the mixer's own rate: " + path)
                XCTAssertEqual(wav.bitsPerSample, 16, "the take is 16-bit: " + path)
                XCTAssertEqual(wav.dataFrames, frames ?? -1,
                               "the WAV's data chunk is the length the stop alert named: " + path)
                XCTAssertGreaterThan(wav.dataFrames, 0, "the take holds samples: " + path)
                let silent = wav.peak < 32
                XCTAssertEqual(stopped.message.contains("silence"), silent,
                               "the stop alert's audibility sentence is what the samples say: "
                               + stopped.message)
                if !silent {
                    XCTAssertTrue(stopped.message.contains("loudest sample is \(wav.peak)"),
                                  "the alert names the peak it measured: " + stopped.message)
                }
            } else {
                XCTFail("the start alert names the file it opened: " + started.message)
            }
        } else {
            XCTAssertEqual(started.title, "Nothing to Record",
                           "a row that did not start a take says the port has no device open "
                           + "rather than starting one anyway: " + started.message)
            let again = tapAudioRow("again")
            XCTAssertEqual(again.title, started.title,
                           "with no device the row gives the same reading twice; a remembered flag "
                           + "would answer the second tap differently")
        }
    }

    // MARK: - Ballpad's own Files importer (doc 34 F01/F02)

    /// The three files the wrapper script puts in this app's Files-visible Documents folder. They
    /// are the player's own game bytes, derived at run time; see scripts/native/run-uitests.sh.
    private static let validImageName = "uitest-valid.iso"
    private static let truncatedImageName = "uitest-truncated.iso"
    private static let wrongGameImageName = "uitest-wronggame.iso"

    /// The heading BallPad's own importer carries on a fresh install. The screen speaks in the
    /// app's voice: the headline, the copy and the quiet line under them are all BallPad's own
    /// sentences, which is why asserting this exact string is what makes the row "the app shows
    /// BallPad's own first-run screen" rather than "the app shows some screen".
    ///
    /// What the port says about a disc it could not find is deliberately *not* on the screen. Its
    /// refusal (src/platform/dvd.c) names every container path the search tried -- on a Simulator an
    /// absolute `/Users/.../CoreSimulator/Devices/<UDID>/...` path -- and then tells the reader to
    /// set the `STRIKERS_DATA` variable or the `data` key in `strikers.ini`. Neither is a thing a
    /// player holding an iPad can do, and on the iPad the block filled most of the first screen. It
    /// goes to the app's log instead; `app-runtime.log` carries it on one line under
    /// `game data: the port's own not-found text`.
    private static let importHeading = "Add your game"

    /// No disc, no writable directories, no seed: the launch of a fresh install. This is the
    /// launch the old build answered by printing its refusal and exiting before UIKit existed.
    private func launchWithNoEnvironment() {
        app.launchEnvironment = [:]
        app.launch()
    }

    private var importScreenTitle: XCUIElement { app.staticTexts["BallpadGameDataImportTitle"] }
    private var importScreenChoose: XCUIElement { app.buttons["BallpadGameDataImportChoose"] }

    /// The screen's copy is a label, but the element is looked up by whatever type the interface
    /// actually published rather than by the one this bundle assumed: the body was a text view until
    /// it became BallPad's own centred copy, and a row that asserts a string is on screen has no
    /// business failing over which view class drew it.
    private func importScreenElement(_ identifier: String) -> XCUIElement? {
        let candidates = [app.staticTexts[identifier], app.textViews[identifier],
                          app.buttons[identifier], app.otherElements[identifier]]
        for candidate in candidates where candidate.exists { return candidate }
        return nil
    }

    /// Which screen answers a launch with no environment: the game, because a stored disc
    /// resolved, or the importer, because nothing did. Both are legitimate outcomes; which one a
    /// row expects is that row's claim.
    private enum NoEnvironmentLaunch { case game, importer, neither }

    private func classifyNoEnvironmentLaunch(timeout: TimeInterval = 240) -> NoEnvironmentLaunch {
        launchWithNoEnvironment()
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if menuButton.exists { return .game }
            if importScreenTitle.exists { return .importer }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return .neither
    }

    // MARK: The Files picker

    /// One flat query, resolved to a single element, or nil.
    ///
    /// The shape matters. A query that walks through a container -- `app.collectionViews.cells[x]`,
    /// `app.tables.cells[x]` -- raises "Failed to get matching snapshot: No matches found for first
    /// query match sequence" when the *container* matched nothing, which is an exception and not a
    /// false: run f01f02-phone-r2 lost F02 to exactly that on a page of the picker with no collection
    /// view on it. Asking the app for descendants of one type keeps every step flat, so a page that
    /// simply does not have the element answers nil.
    private func pickerDescendant(_ type: XCUIElement.ElementType,
                                  matching predicate: NSPredicate,
                                  excludingIdentifier excluded: String? = nil,
                                  limit: Int = 8) -> XCUIElement? {
        let query = app.descendants(matching: type).matching(predicate)
        let count = query.count
        guard count > 0 else { return nil }
        for index in 0..<min(count, limit) {
            let element = query.element(boundBy: index)
            if let excluded, element.identifier == excluded { continue }
            if element.exists { return element }
        }
        return nil
    }

    private static let pickerRowTypes: [XCUIElement.ElementType] = [.cell, .button, .other]

    /// The picker's tree belongs to another framework, and the same item is a cell on one page and
    /// a button on the next, so every step searches the honest query types rather than assuming one
    /// of them. Only single matches are handed back: "Browse" names both the tab bar's Browse
    /// button and, once inside that location, the navigation bar's back button, and tapping an
    /// ambiguous query raises instead of choosing. That ambiguity is what the first run of this
    /// row hit, so the back button is excluded by identifier here.
    private func pickerMatch(_ labels: [String]) -> XCUIElement? {
        for label in labels {
            let tabBar = app.otherElements["DOC.browsingModeTabBar"]
            if tabBar.exists {
                let tab = tabBar.buttons[label]
                if tab.exists { return tab.firstMatch }
            }
            let byName = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
            for type in Self.pickerRowTypes {
                if let match = pickerDescendant(type, matching: byName,
                                                excludingIdentifier: "BackButton") {
                    return match
                }
            }
        }
        return nil
    }

    /// A row in the picker's *list* of places rather than in its sidebar. The list decorates the
    /// name it was given, and the decoration is not part of the name: the app's own folder is
    /// published as `identifier: 'BallPad, Container', label: 'BallPad, 4 items'` (the shape
    /// measured in run f01f02-phone-r3, attached as files-picker-in-On-My-iPhone, under the display
    /// name the bundle then carried), so an exact
    /// comparison against the folder's name can never find the row. The prefix is the identity;
    /// the suffix is the picker's own annotation of what is inside.
    private func pickerContainer(named name: String, timeout: TimeInterval = 8) -> XCUIElement? {
        let prefix = NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@",
                                 name, name)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for type in Self.pickerRowTypes {
                if let row = pickerDescendant(type, matching: prefix,
                                              excludingIdentifier: "BackButton") {
                    return row
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    private func pickerElement(_ labels: [String], timeout: TimeInterval = 15) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = pickerMatch(labels) { return element }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// The picker's row for the file, in whichever form the current layout publishes it. Icon mode
    /// makes one cell whose identifier and label both open with the file name and then fold in the
    /// size and the date, so the exact match is tried first and a prefix match after it.
    private func pickerRow(named name: String, timeout: TimeInterval = 20) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let exact = NSPredicate(format: "identifier == %@ OR label == %@", name, name)
        let prefix = NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@",
                                 name, name)
        repeat {
            for type in Self.pickerRowTypes {
                if let row = pickerDescendant(type, matching: exact) { return row }
                if let row = pickerDescendant(type, matching: prefix) { return row }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// The file itself, row first and label last. A row in icon mode publishes the name twice: once
    /// on the cell and once as a label on top of its icon, and a tap that lands on the label has
    /// been measured to leave the picker standing (run f01f02-phone-r2, whose F01 tapped the label
    /// and then waited out the whole alert timeout). The label is therefore only offered once the
    /// rows have had half the budget to show up, and a label tap that changes nothing is caught by
    /// the caller rather than believed.
    private func pickerFile(named name: String, timeout: TimeInterval = 20) -> XCUIElement? {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        let byName = NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", name, name)
        repeat {
            if let row = pickerRow(named: name, timeout: 0.5) { return row }
            if Date().timeIntervalSince(start) > timeout / 2,
               let label = pickerDescendant(.staticText, matching: byName) {
                return label
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// A selection dismisses the whole picker service, so the tab bar's disappearance is the only
    /// in-process sign that a tap was taken rather than merely delivered.
    private func waitForPickerToClose(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !app.otherElements["DOC.browsingModeTabBar"].exists { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return !app.otherElements["DOC.browsingModeTabBar"].exists
    }

    /// Taps the file and requires the picker to go away, retrying against the row itself when the
    /// first tap only reached the label.
    private func selectFileInPicker(named name: String, timeout: TimeInterval = 20) -> Bool {
        guard let first = pickerFile(named: name, timeout: timeout) else { return false }
        attachHierarchy("files-picker-file")
        first.tap()
        if waitForPickerToClose() { return true }

        attachHierarchy("files-picker-still-open")
        guard let row = pickerRow(named: name, timeout: 10) else { return false }
        row.tap()
        return waitForPickerToClose()
    }

    /// Drives the Files picker from wherever it opens to the named image in this app's own folder.
    /// The folder is published to Files because the bundle sets UIFileSharingEnabled, and the
    /// wrapper script fills it before the run (scripts/native/run-uitests.sh), so the selection,
    /// the copy the picker hands back and the staging that follows are all the real ones. The
    /// picker is a remote view service that remembers where it was last left, so a run can meet it
    /// on Recents or already standing in this app's folder; each bounded pass looks for the file,
    /// then comes in through the Browse tab, then walks one container on the way to the folder.
    ///
    /// The order is the one two runs measured rather than a preference. Looking for the file first
    /// covers the run that meets the picker still standing in this app's folder, and it is short on
    /// purpose: the first run of this row spent its whole budget here and tapped a label on a
    /// Recents page instead of the row, which is why nothing is selected until a tap is seen to
    /// dismiss the picker. Browse comes next because it is the route that has worked -- the run that
    /// passed did exactly that tap and then found the file on the first query -- and the container
    /// walk is last because it is the slowest and the least likely.
    ///
    /// Browse is not a shortcut to the folder, it is a shortcut to wherever the picker was left, and
    /// the third run measured both outcomes of it: f01f02-phone-r1 opened onto this app's folder
    /// directly, f01f02-phone-r3 opened onto the locations sidebar with iCloud Drive and On My
    /// iPhone in it. So the walk is what makes the route deterministic, and it needs two hops --
    /// On My iPhone, then the app's own folder -- rather than one.
    private func pickImageThroughFiles(named name: String) {
        // Pass 1: the file may already be on screen.
        if selectFileInPicker(named: name, timeout: 12) { return }

        // Pass 2: in through the Browse tab, which lands wherever Files was last browsing -- in a
        // passing run, this app's own folder, which is the folder the fixture is in.
        if let browse = pickerElement(["Browse"], timeout: 20) {
            browse.tap()
            Thread.sleep(forTimeInterval: 1.5)
            attachHierarchy("files-picker-browse")
            if selectFileInPicker(named: name) { return }
        } else {
            attachHierarchy("files-picker-no-browse")
        }

        // Pass 3: the locations the browse root lists on the way to this app's folder, which is
        // what the picker's Browse tab opens onto -- a sidebar of places, not the last folder (run
        // f01f02-phone-r3: Browse landed on `Title: On My iPhone` with iCloud Drive/On My iPhone in
        // a Locations list). The sidebar entries carry their own name, but the folder list below
        // them decorates it, so both spellings are looked for.
        for container in ["On My iPhone", "On My iPad", "This iPhone", "This iPad",
                          "BallPad"] {
            guard let inside = pickerMatch([container])
                                  ?? pickerContainer(named: container, timeout: 6) else { continue }
            inside.tap()
            Thread.sleep(forTimeInterval: 1.5)
            attachHierarchy("files-picker-in-"
                            + container.replacingOccurrences(of: " ", with: "-"))
            if selectFileInPicker(named: name) { return }
        }

        attachHierarchy("files-picker-could-not-reach-the-file")
        XCTFail("the Files picker reached " + name + " in this app's own folder")
    }

    /// Launch with no stored disc and no environment at all: the launch of a fresh install. The
    /// build this port replaced answered it by printing its refusal and exiting before UIKit
    /// existed, so which screen comes up here is the row's first claim.
    func testFreshInstallShowsImportScreenAndActivatesAPickedImage() throws {
        let outcome = classifyNoEnvironmentLaunch()
        XCTAssertEqual(outcome, .importer,
                       "a launch with no data and no environment presents Ballpad's own importer "
                       + "instead of exiting")
        guard outcome == .importer else { return }

        XCTAssertEqual(importScreenTitle.label, Self.importHeading,
                       "the importer leads with BallPad's own heading")
        XCTAssertNotNil(importScreenElement("BallpadGameDataImportBody"),
                        "the importer carries BallPad's own copy")
        XCTAssertNotNil(importScreenElement("BallpadGameDataImportDetail"),
                        "the quiet line naming the disc BallPad accepts is on the screen, under the "
                        + "copy -- BallPad's own sentence, not the port's developer-facing refusal")
        XCTAssertTrue(importScreenChoose.isHittable,
                      "the choose button is hittable without scrolling the explanation")
        attach("f01-import-screen")
        attachHierarchy("f01-import-screen-hierarchy")

        importScreenChoose.tap()
        pickImageThroughFiles(named: Self.validImageName)

        // Staging and validation run on a background queue and answer with this alert, which is
        // the app accepting the copy -- not yet the launch playing it.
        let ready = app.alerts["Game Data Ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 180),
                      "the copy chosen through Files is accepted as this port's disc")
        attach("f01-game-data-ready")
        XCTAssertTrue(ready.buttons["Start the Game"].exists, "the alert continues the launch")
        ready.buttons["Start the Game"].tap()

        // The port re-resolves through the hook the importer records into, so the same process
        // reaching its overlay is what shows the activation landed rather than the alert alone.
        XCTAssertTrue(menuButton.waitForExistence(timeout: 300),
                      "the same launch continues into the game on the copy chosen through Files")
        attach("f01-overlay-after-import")
        attachHierarchy("f01-overlay-after-import-hierarchy")
    }

    /// F02's precondition: a stored disc this app resolves on a launch with no environment. The
    /// row that imports one normally ran first; this makes the state a property of this row rather
    /// than of another method's leftovers.
    private func ensureStoredGameData() {
        guard classifyNoEnvironmentLaunch() == .importer else { return }
        XCTAssertEqual(importScreenTitle.label, Self.importHeading,
                       "the importer leads with BallPad's own heading")
        importScreenChoose.tap()
        pickImageThroughFiles(named: Self.validImageName)
        let ready = app.alerts["Game Data Ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 180),
                      "the image this row sets up is accepted")
        ready.buttons["Start the Game"].tap()
        XCTAssertTrue(menuButton.waitForExistence(timeout: 300),
                      "the image this row set up activated and the game came up")
    }

    /// The running game's own menu, down to the vendored Game Data & Saves submenu. The rows are
    /// the vendored ones; only their destinations are Ballpad's.
    private func openGameDataMenu() {
        openMenu()
        guard let dataRow = scrollMenuForElement("Game Data & Saves", timeout: 25) else {
            XCTFail("the Game Data & Saves row is in the menu")
            return
        }
        dataRow.tap()
    }

    private func tapDataMenuRow(_ title: String) {
        guard let row = waitForOverlayElement(title, timeout: 20) else {
            XCTFail("the vendored row is in the data submenu: " + title)
            return
        }
        row.tap()
    }

    /// A refused import through the menu row: the alert the app raises has to carry the port's own
    /// words, which is what makes this "the engine refused it" rather than "a screen appeared".
    private func importFromMenuExpectingRefusal(named name: String, containing phrase: String) {
        openGameDataMenu()
        tapDataMenuRow("Import or Reimport Game Data")
        pickImageThroughFiles(named: name)

        let refusal = app.alerts["That Disc Cannot Be Used"]
        XCTAssertTrue(refusal.waitForExistence(timeout: 180),
                      "the refused image " + name + " is reported to the player")
        attachHierarchy("f02-refusal-" + name.replacingOccurrences(of: ".", with: "-"))
        let words = refusal.staticTexts.allElementsBoundByIndex.map(\.label)
            .joined(separator: " ")
        XCTAssertTrue(words.contains(phrase),
                      "the refusal is the port's own words (" + phrase + "); saw: " + words)
        refusal.buttons["OK"].tap()
        XCTAssertFalse(refusal.waitForExistence(timeout: 5), "OK dismisses the refusal")
    }

    /// Cancel is the other half of doc 34's "failure/cancel leaves previous installation usable".
    private func cancelMenuImport() {
        openGameDataMenu()
        tapDataMenuRow("Import or Reimport Game Data")
        guard let cancel = pickerElement(["Cancel"], timeout: 60) else {
            attachHierarchy("f02-picker-no-cancel")
            XCTFail("the Files picker offers Cancel")
            return
        }
        cancel.tap()
        XCTAssertFalse(app.alerts["Game Data Imported"].waitForExistence(timeout: 10),
                       "cancelling the picker imports nothing")
    }

    /// The installation is still the one that was there: a fresh process resolves it and reaches
    /// the game. A store a refusal had damaged would show the importer instead.
    private func assertStoredGameDataStillPlays(_ when: String) {
        XCTAssertEqual(classifyNoEnvironmentLaunch(), .game,
                       "the previous installation is still usable " + when)
        attachHierarchy("f02-still-plays-" + when.replacingOccurrences(of: " ", with: "-"))
    }

    /// Removal is the one menu action that is supposed to stop the next launch resolving.
    private func removeStoredGameData() {
        openGameDataMenu()
        tapDataMenuRow("Remove Stored Game Data")

        let confirm = app.alerts["Remove Stored Game Data?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "the vendored confirmation is raised")
        XCTAssertTrue(confirm.buttons["Remove"].exists, "the confirmation offers Remove")
        confirm.buttons["Remove"].tap()

        let done = app.alerts["Game Data Removed"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the removal reports what it did")
        attachHierarchy("f02-removed")
        done.buttons["OK"].tap()
    }

    /// F02. Every refusal has to leave the installation that was already there usable and has to
    /// leave the file the player chose untouched. The words the refusals carry are the port's own,
    /// because validation calls the engine's reader rather than a second parser; the two phrases
    /// below are from src/platform/disc.c and this app's own header check.
    func testRefusedImportKeepsThePreviousInstallationUsable() throws {
        ensureStoredGameData()

        importFromMenuExpectingRefusal(named: Self.truncatedImageName, containing: "truncated")
        assertStoredGameDataStillPlays("after a truncated image was refused")

        importFromMenuExpectingRefusal(named: Self.wrongGameImageName,
                                       containing: "is not Super Mario Strikers")
        assertStoredGameDataStillPlays("after another game's disc was refused")

        cancelMenuImport()
        assertStoredGameDataStillPlays("after the picker was cancelled")

        removeStoredGameData()
        XCTAssertEqual(classifyNoEnvironmentLaunch(), .importer,
                       "once the stored disc is removed the next launch asks for one again")
        attach("f02-importer-after-removal")

        // The removal row leaves the machine asking for game data, so this takes it back the way a
        // player would, from the importer that is already up. It decides nothing F02 has not
        // already decided; what it buys is the state the wrapper script reads back afterwards --
        // the store holds a staged copy, and that copy can be compared with the fixture the picker
        // offered instead of with what an alert said about itself.
        XCTAssertTrue(importScreenChoose.isHittable, "the importer is up after the removal")
        importScreenChoose.tap()
        pickImageThroughFiles(named: Self.validImageName)
        let restored = app.alerts["Game Data Ready"]
        XCTAssertTrue(restored.waitForExistence(timeout: 180),
                      "a removed installation can be re-imported from the importer")
        restored.buttons["Start the Game"].tap()
        XCTAssertTrue(menuButton.waitForExistence(timeout: 300),
                      "the re-imported disc activates in the same launch")
        attachHierarchy("f02-reimported")
    }
}
