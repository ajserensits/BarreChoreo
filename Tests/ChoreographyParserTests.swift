import XCTest
import PDFKit
import UIKit
@testable import BarreChoreography

final class ChoreographyParserTests: XCTestCase {
    func testHighlightedPDFExtractorCombinesSourcesInChosenOrderAndFlattensOutput() throws {
        let markedPDF = try makeMarkedPDF(label: "SOURCE TEXT")
        let fixtureDocument = try XCTUnwrap(PDFDocument(data: markedPDF))
        let fixturePage = try XCTUnwrap(fixtureDocument.page(at: 0))
        XCTAssertEqual(fixturePage.annotations.count, 1)
        XCTAssertEqual(
            fixturePage.annotations.first?.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "Stamp"
        )
        let first = HighlightedPDFSource(filename: "first.pdf", data: markedPDF)
        let second = HighlightedPDFSource(filename: "second.pdf", data: markedPDF)

        let extracted = try HighlightedPDFExtractor.extract(
            from: [first, second],
            minimumAreaRatio: 0.05,
            padding: 4
        )

        XCTAssertEqual(extracted.count, 2)
        XCTAssertEqual(extracted.map(\.sourceFilename), ["first.pdf", "second.pdf"])

        let reversed = Array(extracted.reversed())
        let outputData = try HighlightedPDFExtractor.generatePDF(
            title: "Combined Highlights",
            sources: [first, second],
            sections: reversed,
            keepHighlighting: false
        )
        let output = try XCTUnwrap(PDFDocument(data: outputData))

        XCTAssertEqual(output.pageCount, 1, "Short portions should stitch together on one output page")
        for pageIndex in 0..<output.pageCount {
            let page = try XCTUnwrap(output.page(at: pageIndex))
            XCTAssertEqual(page.bounds(for: .mediaBox).width, 612, accuracy: 0.5)
            XCTAssertEqual(page.bounds(for: .mediaBox).height, 792, accuracy: 0.5)
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertTrue((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(pageContainsVisibleContent(page), "Generated page \(pageIndex + 1) was blank")
        }
    }

    func testHighlightedPDFFilenameIsSafeAndKeepsPDFExtension() {
        XCTAssertEqual(
            HighlightedPDFExtractor.sanitizedFilename(title: "Tuesday / Align: Plan"),
            "Tuesday - Align- Plan.pdf"
        )
        XCTAssertEqual(
            HighlightedPDFExtractor.sanitizedFilename(title: "Already.pdf"),
            "Already.pdf"
        )
    }

    func testDisconnectedHighlightedTextBecomesSeparateRegions() {
        let horizontalBounds = CGRect(x: 40, y: 80, width: 520, height: 620)
        let plankLines = [
            CGRect(x: 80, y: 620, width: 300, height: 12),
            CGRect(x: 80, y: 602, width: 420, height: 12),
            CGRect(x: 80, y: 584, width: 390, height: 12)
        ]
        let excludedLungeLines = [
            CGRect(x: 80, y: 470, width: 350, height: 12),
            CGRect(x: 80, y: 452, width: 410, height: 12)
        ]
        let pushUpLines = [
            CGRect(x: 80, y: 330, width: 260, height: 12),
            CGRect(x: 80, y: 312, width: 400, height: 12),
            CGRect(x: 80, y: 294, width: 370, height: 12)
        ]

        let regions = HighlightedPDFExtractor.clusteredHighlightedLineRegions(
            plankLines + pushUpLines,
            horizontalBounds: horizontalBounds
        )

        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions[0].intersects(plankLines[0]))
        XCTAssertTrue(regions[1].intersects(pushUpLines[0]))
        for excludedLine in excludedLungeLines {
            XCTAssertFalse(regions.contains { $0.intersects(excludedLine) })
        }
    }

    func testIndependentSectionCopyRefreshesIDsAndPreservesRepeatLink() {
        let firstCue = ChoreographyCue(text: "First move")
        let repeatCue = ChoreographyCue(
            text: "Repeat",
            kind: .repeatInstruction,
            repeatTargetCueID: firstCue.id
        )
        let original = ChoreographySection(
            heading: "WARM UP",
            combinations: [.init(title: "FLOOR", cues: [firstCue, repeatCue])]
        )

        let copy = original.independentCopy()

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNotEqual(copy.combinations[0].id, original.combinations[0].id)
        XCTAssertNotEqual(copy.combinations[0].cues[0].id, firstCue.id)
        XCTAssertEqual(
            copy.combinations[0].cues[1].repeatTargetCueID,
            copy.combinations[0].cues[0].id
        )
        XCTAssertEqual(copy.heading, original.heading)
        XCTAssertEqual(copy.combinations[0].cues.map(\.text), ["First move", "Repeat"])
    }

    private func makeMarkedPDF(label: String) throws -> Data {
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let baseData = renderer.pdfData { context in
            context.beginPage()
            (label as NSString).draw(
                at: CGPoint(x: 72, y: 300),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor.black
                ]
            )
        }
        let document = try XCTUnwrap(PDFDocument(data: baseData))
        let page = try XCTUnwrap(document.page(at: 0))
        let stamp = PDFAnnotation(
            bounds: CGRect(x: 20, y: 390, width: 572, height: 180),
            forType: .stamp,
            withProperties: nil
        )
        stamp.stampName = "Approved"
        page.addAnnotation(stamp)
        return try XCTUnwrap(document.dataRepresentation())
    }

    private func pageContainsVisibleContent(_ page: PDFPage) -> Bool {
        let thumbnail = page.thumbnail(of: CGSize(width: 300, height: 300), for: .mediaBox)
        guard let image = thumbnail.cgImage else { return false }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).contains { offset in
            pixels[offset] < 235 || pixels[offset + 1] < 235 || pixels[offset + 2] < 235
        }
    }

    func testAudioMatcherUsesSpeechAndElapsedTimeToLocateCue() {
        let script = ChoreographyScript(
            title: "Classic",
            sourceFilename: "classic.pdf",
            sections: [
                .init(heading: "WARM UP", combinations: [.init(cues: [
                    .init(text: "Come to hands and knees"),
                    .init(text: "Drop your head and round your spine")
                ])]),
                .init(heading: "COOL DOWN", combinations: [.init(title: "HAMSTRING SETUP", cues: [
                    .init(text: "Place the tube around your right foot"),
                    .init(text: "Open the leg a few inches to the right")
                ])])
            ],
            originalText: "",
            plannedDurationMinutes: 50
        )

        let result = AudioFollowingMatcher().match(
            evidence: [
                .init(text: "now open the leg a few inches to the right", confidence: 0.92, ageSeconds: 2),
                .init(text: "tube around your right foot", confidence: 0.80, ageSeconds: 20)
            ],
            script: script,
            currentSectionIndex: 0,
            currentCueIndex: 1,
            elapsedSeconds: 45 * 60,
            scope: .locate
        )

        XCTAssertEqual(result?.location.sectionHeading, "COOL DOWN")
        XCTAssertEqual(result?.location.cueIndex, 1)
        XCTAssertGreaterThan(result?.confidence ?? 0, result?.runnerUpConfidence ?? 0)
    }

    func testAudioFollowSearchesOnlyNearbyCues() {
        let script = ChoreographyScript(
            title: "Classic",
            sourceFilename: "classic.pdf",
            sections: [.init(heading: "CLASS", combinations: [.init(cues: (0..<12).map {
                .init(text: $0 == 10 ? "distinctive final stretch phrase" : "movement cue \($0)")
            })])],
            originalText: ""
        )

        let result = AudioFollowingMatcher().match(
            evidence: [.init(text: "distinctive final stretch phrase", confidence: 1, ageSeconds: 0)],
            script: script,
            currentSectionIndex: 0,
            currentCueIndex: 0,
            elapsedSeconds: nil,
            scope: .follow
        )

        XCTAssertNotEqual(result?.location.cueIndex, 10)
    }

    func testSkipDetectionOnlyMatchesBeyondTheNextSection() {
        let script = ChoreographyScript(
            title: "Classic",
            sourceFilename: "classic.pdf",
            sections: [
                .init(heading: "WARM UP", combinations: [.init(cues: [.init(text: "Curl up tempo")])]),
                .init(heading: "THIGHS", combinations: [.init(cues: [.init(text: "Heavy heels chair")])]),
                .init(heading: "SEAT", combinations: [.init(cues: [.init(text: "Standing bent leg press back")])])
            ],
            originalText: ""
        )

        let result = AudioFollowingMatcher().match(
            evidence: [.init(text: "standing bent leg press back", confidence: 0.98, ageSeconds: 0)],
            script: script,
            currentSectionIndex: 0,
            currentCueIndex: 0,
            elapsedSeconds: nil,
            scope: .skipDetection
        )

        XCTAssertEqual(result?.location.sectionIndex, 2)
        XCTAssertGreaterThan(result?.confidence ?? 0, 0.7)
    }

    func testScriptsSortAlphabeticallyByVisibleTitle() {
        let scripts = ["Warm Up 10", "align", "Warm Up 2", "Classic"].map {
            ChoreographyScript(title: $0, sourceFilename: "\($0).pdf", sections: [], originalText: "")
        }

        XCTAssertEqual(
            scripts.sorted(by: ChoreographyScript.alphabeticallyByTitle).map(\.title),
            ["align", "Classic", "Warm Up 2", "Warm Up 10"]
        )
    }

    func testTeachingCopyPreservesOriginalAndCanRestoreEdits() {
        let original = ChoreographyScript(
            title: "Align",
            sourceFilename: "align.pdf",
            sections: [
                .init(heading: "WARMUP", combinations: [.init(cues: [.init(text: "Opening stretch")])]),
                .init(heading: "FLOOR CORE WORK", combinations: [.init(cues: [.init(text: "Plank to pike")])], option: "OPTION A")
            ],
            originalText: "ALIGN"
        )

        var copy = original.makeTeachingCopy(title: "Tuesday Align")
        copy.sections.removeFirst()
        copy.sections[0].combinations[0].cues[0].text = "Custom plank reminder"

        XCTAssertTrue(copy.isTeachingCopy)
        XCTAssertEqual(copy.sourceScriptID, original.id)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertTrue(copy.hasCustomizations)
        XCTAssertEqual(original.sections.count, 2)

        copy.restoreOriginalSections()

        XCTAssertFalse(copy.hasCustomizations)
        XCTAssertEqual(copy.sections, original.sections)
    }

    func testTeachingCopyRoundTripsThroughLocalStorage() throws {
        let original = ChoreographyScript(
            title: "Classic",
            importedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceFilename: "classic.pdf",
            sections: [.init(heading: "SEAT", combinations: [.init(cues: [.init(text: "Pulse tempo")])])],
            originalText: "SEAT"
        )
        var copy = original.makeTeachingCopy()
        copy.importedAt = Date(timeIntervalSince1970: 1_800_000_000)
        copy.sections.append(.init(heading: "CUSTOM FINISH", combinations: [.init(cues: [.init(text: "Personal reminder")])]))

        let data = try SharedCodec.encoder.encode(copy)
        let decoded = try SharedCodec.decoder.decode(ChoreographyScript.self, from: data)

        XCTAssertEqual(decoded, copy)
        XCTAssertEqual(decoded.originalSections, original.sections)
        XCTAssertTrue(decoded.hasCustomizations)
    }

    func testLinksRepeatInstructionToBeginningOfCurrentCombination() {
        let script = ChoreographyParser().parse(
            text: """
            SEAT
            STANDING BENT LEG
            Press the leg back – 8x
            Hold at the top – 4 8s
            Repeat on the second side
            """,
            title: "Classic",
            sourceFilename: "classic.pdf"
        )

        let cues = script.sections[0].combinations[0].cues
        XCTAssertEqual(cues.last?.kind, .repeatInstruction)
        XCTAssertEqual(cues.last?.repeatTargetCueID, cues.first?.id)
    }

    func testLinksLeadingRepeatInstructionToNextChoreographyBlock() {
        let script = ChoreographyParser().parse(
            text: """
            ARMS & LEGS
            COMPLETE BOTH ON FIRST SIDE THEN REPEAT
            CRESCENT LUNGE A
            Down 2 up 2 – 4x / 4 8s
            """,
            title: "Reform",
            sourceFilename: "reform.pdf"
        )

        let combinations = script.sections[0].combinations
        let repeatCue = combinations[0].cues[0]
        let nextCue = combinations[1].cues[0]
        XCTAssertEqual(repeatCue.kind, .repeatInstruction)
        XCTAssertEqual(repeatCue.repeatTargetCueID, nextCue.id)
    }

    func testPreservesCueWordingAndCounts() {
        let input = """
        SEAT
        SEAT IN PARALLEL
        Down an inch, up an inch 8x
        Hold low for 10
        STANDING BENT LEG
        Press back 2 counts, return 2 counts
        """

        let script = ChoreographyParser().parse(text: input, title: "Test", sourceFilename: "test.pdf")

        XCTAssertEqual(script.sections.first?.heading, "SEAT IN PARALLEL")
        XCTAssertEqual(script.sections.first?.combinations.map(\.title), [nil, "STANDING BENT LEG"])
        XCTAssertEqual(script.sections.first?.combinations.first?.cues.map(\.text), [
            "Down an inch, up an inch 8x",
            "Hold low for 10"
        ])
        XCTAssertEqual(script.originalText, input)
    }

    func testUsesClassNotesWhenNoMajorHeadingExists() {
        let script = ChoreographyParser().parse(
            text: "SETUP\nKeep shoulders relaxed",
            title: "Notes",
            sourceFilename: "notes.pdf"
        )

        XCTAssertEqual(script.sections.first?.heading, "CLASS NOTES")
        XCTAssertEqual(script.sections.first?.combinations.first?.title, "SETUP")
        XCTAssertEqual(script.sections.first?.combinations.first?.cues.first?.text, "Keep shoulders relaxed")
    }

    func testParsesMasterPDFStyleAndRemovesPageFurniture() {
        let input = """
        CLASSIC CHOREOGRAPHY COMBINATIONS
        Q4 2026 to post 9.15.26
        THIGHS TURNOUT
        LOW V
        Center of the room, ball between palms
        Squeeze squeezehold – 8x / 4 8s
        4
        CLASSIC CHOREOGRAPHY COMBINATIONS
        Q4 2026 to post 9.15.26
        SEAT IN PARALLEL
        STANDING BENT LEG
        Face barre, ball behind knee, heel to seat, flex
        Squeezehold – 16x / 8 8s
        """

        let script = ChoreographyParser().parse(text: input, title: "Q4", sourceFilename: "q4.pdf")

        XCTAssertEqual(script.sections.map(\.heading), ["THIGHS TURNOUT", "SEAT IN PARALLEL"])
        XCTAssertEqual(script.sections[0].combinations.first?.title, "LOW V")
        XCTAssertEqual(script.sections[1].combinations.first?.title, "STANDING BENT LEG")
        XCTAssertFalse(script.sections.flatMap(\.combinations).flatMap(\.cues).contains { $0.text.contains("CLASSIC CHOREOGRAPHY") })
    }

    func testJoinsPDFKitWrappedCueLines() {
        let input = """
        SEAT TURNOUT
        FOLDOVER
        Circlehold – 8x / 4 8s; circle tempo – 16x / 4 8s;
        reverse, circlehold – 8x / 4 8s
        """

        let script = ChoreographyParser().parse(text: input, title: "Test", sourceFilename: "test.pdf")

        XCTAssertEqual(script.sections[0].combinations[0].cues.map(\.text), [
            "Circlehold – 8x / 4 8s; circle tempo – 16x / 4 8s; reverse, circlehold – 8x / 4 8s"
        ])
    }

    func testPreservesNumberedAndBulletedListsAcrossPageFurniture() {
        let input = """
        Q4 2026 BARRE CLASSIC CLASS PLAN
        COOL DOWN
        SONG #13
        HAMSTRING SETUP
        1.\u{200B} Place the tube around your R foot
        2.\u{200B} L leg long on the floor
        8
        Q4 2026 BARRE CLASSIC CLASS PLAN
        3.\u{200B} Hold close to your foot
        • Keep shoulders relaxed
        o Turn lights OFF
        """

        let script = ChoreographyParser().parse(text: input, title: "Classic", sourceFilename: "classic.pdf")
        let cues = script.sections.flatMap(\.combinations).flatMap(\.cues)

        XCTAssertEqual(cues.map(\.listMarker), ["1.", "2.", "3.", "•", "o"])
        XCTAssertEqual(cues.map(\.text), [
            "Place the tube around your R foot",
            "L leg long on the floor",
            "Hold close to your foot",
            "Keep shoulders relaxed",
            "Turn lights OFF"
        ])
    }

    func testParsesIndividualClassPlanSectionsAndPreservesSetupNotes() {
        let input = """
        Q4 2026 BARRE CLASSIC CLASS PLAN
        BARRE CLASSIC CLASS PLAN
        Song Section Option Direction
        1 FLOORWORK A Center of room, face and mirror clients
        ROOM SET UP:
        ●
        Note equipment usage: double tube, ball, and mat
        THIGH #1
        SONG #3
        Setup in manual on page: 159
        EXTENSION PARALLEL
        Out an inch in an inch – 8x / 4 8s
        1
        Q4 2026 BARRE CLASSIC CLASS PLAN
        CORE FOCUS
        SONG #9
        BARRE PLANK A
        Pull tempo – 16x / 4 8s (count 10)
        ABS 1–3
        SONGS #10
        ABS 1 – OPTION C
        COMBO C
        USES BALL
        Tuck tuckhold – 8x / 4 8s
        """

        let script = ChoreographyParser().parse(text: input, title: "Class Plan", sourceFilename: "plan.pdf")

        XCTAssertEqual(script.classType, .classic)
        XCTAssertEqual(script.sections.map(\.heading), ["ROOM SET UP:", "THIGH #1", "CORE FOCUS", "ABS 1–3"])
        let cues = script.sections.flatMap(\.combinations).flatMap(\.cues).map(\.text)
        let equipmentNote = script.sections
            .flatMap(\.combinations)
            .flatMap(\.cues)
            .first { $0.text == "Note equipment usage: double tube, ball, and mat" }
        XCTAssertEqual(equipmentNote?.listMarker, "●")
        XCTAssertEqual(script.sections.first(where: { $0.heading == "THIGH #1" })?.song, "#3")
        XCTAssertTrue(cues.contains("Setup in manual on page: 159"))
        XCTAssertFalse(cues.contains { $0.contains("Q4 2026 BARRE CLASSIC CLASS PLAN") })
    }

    func testParsesDefineBlocksTimingMetadataAndDualCueText() {
        let input = """
        DEFINE CHOREO | CLASS PLAN #1
        Q4 2026
        DEFINE #1 - 50 MIN TIMING OVERVIEW
        Song Block Section Time
        #1 Block 1 Warmup 4
        ROOM SETUP
        ●
        Medium weights at center
        BLOCK 1 | WARMUP
        EQUIPMENT: 2 medium weights
        SONG: #1
        WARMUP
        Bird dog – 30 | Reach R arm forward, L leg back – 30 seconds (8x / 8 8s)
        """

        let script = ChoreographyParser().parse(text: input, title: "Define Plan", sourceFilename: "define.pdf")

        XCTAssertEqual(script.classType, .define)
        XCTAssertEqual(script.plannedDurationMinutes, 50)
        XCTAssertEqual(script.sections.map(\.heading), ["ROOM SETUP", "BLOCK 1 | WARMUP"])
        XCTAssertEqual(script.sections[1].song, "#1")
        XCTAssertEqual(script.sections[1].equipment, "2 medium weights")
        let cue = script.sections[1].combinations[0].cues[0]
        XCTAssertEqual(cue.shortText, "Bird dog – 30")
        XCTAssertEqual(cue.text, "Reach R arm forward, L leg back – 30 seconds (8x / 8 8s)")
        XCTAssertEqual(cue.sourceText, "Bird dog – 30 | Reach R arm forward, L leg back – 30 seconds (8x / 8 8s)")
    }

    func testParsesEngageAsThirtyMinuteBlockPlan() {
        let input = """
        BARRE ENGAGE CLASS PLAN
        ENGAGE #1 - 30 MIN TIMING OVERVIEW
        ROOM SET UP
        ● Ball at barre
        BLOCK 1 | WARMUP
        SONG: #1
        WARMUP
        Alternate lunge – 15 | Alternate lunge R then L – 15 seconds
        """

        let script = ChoreographyParser().parse(text: input, title: "Engage", sourceFilename: "engage.pdf")

        XCTAssertEqual(script.classType, .engage)
        XCTAssertEqual(script.plannedDurationMinutes, 30)
        XCTAssertEqual(script.sections.last?.heading, "BLOCK 1 | WARMUP")
    }

    func testParsesAlignFlowSectionsAndBreathBasedCues() {
        let input = """
        Q4 2026 BARRE ALIGN CLASS PLAN #1
        ROOM SET UP:
        ● Double tube and mat
        WARMUP
        SONG #1
        OPENING STRETCH FLOW
        Hold standing – few breaths
        FLOOR CORE WORK
        SONG #2
        OPTION A
        PLANK TO PIKE
        Isometric hold – 4 8s
        """

        let script = ChoreographyParser().parse(text: input, title: "Align", sourceFilename: "align.pdf")

        XCTAssertEqual(script.classType, .align)
        XCTAssertEqual(script.sections.map(\.heading), ["ROOM SET UP:", "WARMUP", "FLOOR CORE WORK"])
        XCTAssertEqual(script.sections.last?.song, "#2")
        XCTAssertEqual(script.sections.last?.option, "OPTION A")
        XCTAssertTrue(script.sections.flatMap(\.combinations).flatMap(\.cues).contains { $0.text.contains("few breaths") })
    }

    func testParsesReformNamedSectionsAndOperationalNotes() {
        let input = """
        BARRE REFORM CLASS PLAN #1
        Q4 2026
        WARM UP
        FLOORWORK ON SLIDERS
        SONG #1 ENERGIZING VOLUME
        Come center, repeat on L side
        ARMS & LEGS
        USE SONG #2 FOR 1st SIDE, SONG #3 FOR 2nd SIDE, ENERGIZING VOLUME
        COMPLETE BOTH ON FIRST SIDE THEN REPEAT
        CRESCENT LUNGE A
        Down 2 up 2 – 4x / 4 8s
        """

        let script = ChoreographyParser().parse(text: input, title: "Reform", sourceFilename: "reform.pdf")

        XCTAssertEqual(script.classType, .reform)
        XCTAssertEqual(script.sections.map(\.heading), ["WARM UP", "ARMS & LEGS"])
        let operationalCues = script.sections[1].combinations.flatMap(\.cues)
        XCTAssertTrue(operationalCues.contains { $0.kind == .song })
        XCTAssertTrue(operationalCues.contains { $0.kind == .repeatInstruction })
    }

    func testParsesEmpowerCircuitsAndClassifiesStageDirections() {
        let input = """
        Q4 2026 BARRE EMPOWER CLASS PLAN #1
        ROOM SET UP:
        ● Platform and light hand weights
        WARM UP
        SONG #1
        FLOOR WORK
        CLICK TO SONG #2 – TURN MUSIC UP TO ENERGIZING VOLUME
        CARDIO CENTRIC #1 – DYNAMIC ARMS
        Option #1: one weight in each hand
        DYNAMIC ARMS – A
        Repeat on L side
        STRENGTH CIRCUIT #1
        AFTER LAST 10, TURN MUSIC DOWN SLIGHTLY FOR QUAD STRETCH
        CHAIR V TO CURTSEY LUNGE
        Pulse tempo – 16x / 4 8s
        """

        let script = ChoreographyParser().parse(text: input, title: "Empower", sourceFilename: "empower.pdf")

        XCTAssertEqual(script.classType, .empower)
        XCTAssertEqual(script.sections.map(\.heading), ["ROOM SET UP:", "WARM UP", "CARDIO CENTRIC #1 – DYNAMIC ARMS", "STRENGTH CIRCUIT #1"])
        let cues = script.sections.flatMap(\.combinations).flatMap(\.cues)
        XCTAssertTrue(cues.contains { $0.kind == .song })
        XCTAssertTrue(cues.contains { $0.kind == .option })
        XCTAssertTrue(cues.contains { $0.kind == .transition })
    }

    func testDecodesPreviouslySavedScriptsWithNewDefaults() throws {
        let scriptID = UUID()
        let sectionID = UUID()
        let combinationID = UUID()
        let cueID = UUID()
        let legacy: [String: Any] = [
            "id": scriptID.uuidString,
            "title": "Saved Classic",
            "importedAt": "2026-10-27T00:00:00Z",
            "sourceFilename": "saved.pdf",
            "originalText": "SEAT",
            "sections": [[
                "id": sectionID.uuidString,
                "heading": "SEAT",
                "combinations": [[
                    "id": combinationID.uuidString,
                    "title": NSNull(),
                    "cues": [["id": cueID.uuidString, "text": "Pulse tempo – 16x"]]
                ]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        let decoded = try SharedCodec.decoder.decode(ChoreographyScript.self, from: data)

        XCTAssertEqual(decoded.classType, .unknown)
        XCTAssertTrue(decoded.isAvailableOnWatch)
        XCTAssertEqual(decoded.parserVersion, 1)
        XCTAssertEqual(decoded.originalSections, decoded.sections)
        XCTAssertNil(decoded.sourceScriptID)
        XCTAssertEqual(decoded.sections[0].combinations[0].cues[0].kind, .choreography)
        XCTAssertNil(decoded.sections[0].combinations[0].cues[0].repeatTargetCueID)
    }
}

