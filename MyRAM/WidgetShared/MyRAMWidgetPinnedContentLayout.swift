import SwiftUI

struct MyRAMWidgetPinnedContentMeasurement: Equatable, Sendable {
    let fullHeight: CGFloat
    let oneLineHeight: CGFloat
    let twoLineHeight: CGFloat
}

enum MyRAMWidgetPinnedContentRowRepresentation: Equatable, Sendable {
    case complete
    case truncatedTwoLines
}

struct MyRAMWidgetPinnedContentAllocatedRow: Equatable, Sendable {
    let pinIndex: Int
    let representation: MyRAMWidgetPinnedContentRowRepresentation
    let height: CGFloat
}

struct MyRAMWidgetPinnedContentAllocationPlan: Equatable, Sendable {
    let rows: [MyRAMWidgetPinnedContentAllocatedRow]
    let allPinsRepresented: Bool
    let bodyIsEligible: Bool
    let bodyMaximumHeight: CGFloat

    var omittedPinCount: Int {
        allPinsRepresented ? 0 : 1
    }
}

struct MyRAMWidgetPinnedContentAllocationPolicy: Sendable {
    private let measurementTolerance: CGFloat = 0.5

    func plan(
        pinMeasurements: [MyRAMWidgetPinnedContentMeasurement],
        bodyMinimumHeight: CGFloat?,
        availableHeight: CGFloat,
        verticalSpacing: CGFloat
    ) -> MyRAMWidgetPinnedContentAllocationPlan {
        guard !pinMeasurements.isEmpty else {
            let bodyHeight = bodyAvailableHeight(
                afterPinnedHeight: 0,
                hasPinnedRows: false,
                bodyMinimumHeight: bodyMinimumHeight,
                availableHeight: availableHeight,
                verticalSpacing: verticalSpacing
            )
            return MyRAMWidgetPinnedContentAllocationPlan(
                rows: [],
                allPinsRepresented: true,
                bodyIsEligible: bodyHeight > 0,
                bodyMaximumHeight: bodyHeight
            )
        }

        if pinMeasurements.count == 1 {
            return singlePinPlan(
                measurement: pinMeasurements[0],
                bodyMinimumHeight: bodyMinimumHeight,
                availableHeight: availableHeight,
                verticalSpacing: verticalSpacing
            )
        }

        return multiplePinPlan(
            measurements: pinMeasurements,
            bodyMinimumHeight: bodyMinimumHeight,
            availableHeight: availableHeight,
            verticalSpacing: verticalSpacing
        )
    }

    private func singlePinPlan(
        measurement: MyRAMWidgetPinnedContentMeasurement,
        bodyMinimumHeight: CGFloat?,
        availableHeight: CGFloat,
        verticalSpacing: CGFloat
    ) -> MyRAMWidgetPinnedContentAllocationPlan {
        if fits(measurement.fullHeight, within: availableHeight) {
            let row = MyRAMWidgetPinnedContentAllocatedRow(
                pinIndex: 0,
                representation: .complete,
                height: measurement.fullHeight
            )
            let bodyHeight = bodyAvailableHeight(
                afterPinnedHeight: measurement.fullHeight,
                hasPinnedRows: true,
                bodyMinimumHeight: bodyMinimumHeight,
                availableHeight: availableHeight,
                verticalSpacing: verticalSpacing
            )
            return MyRAMWidgetPinnedContentAllocationPlan(
                rows: [row],
                allPinsRepresented: true,
                bodyIsEligible: bodyHeight > 0,
                bodyMaximumHeight: bodyHeight
            )
        }

        guard fits(measurement.twoLineHeight, within: availableHeight) else {
            return MyRAMWidgetPinnedContentAllocationPlan(
                rows: [],
                allPinsRepresented: false,
                bodyIsEligible: false,
                bodyMaximumHeight: 0
            )
        }

        return MyRAMWidgetPinnedContentAllocationPlan(
            rows: [
                MyRAMWidgetPinnedContentAllocatedRow(
                    pinIndex: 0,
                    representation: .truncatedTwoLines,
                    height: measurement.twoLineHeight
                )
            ],
            allPinsRepresented: true,
            bodyIsEligible: false,
            bodyMaximumHeight: 0
        )
    }

    private func multiplePinPlan(
        measurements: [MyRAMWidgetPinnedContentMeasurement],
        bodyMinimumHeight: CGFloat?,
        availableHeight: CGFloat,
        verticalSpacing: CGFloat
    ) -> MyRAMWidgetPinnedContentAllocationPlan {
        var rows: [MyRAMWidgetPinnedContentAllocatedRow] = []
        var usedHeight: CGFloat = 0

        for (index, measurement) in measurements.enumerated() {
            let spacingBeforeRow = rows.isEmpty ? 0 : verticalSpacing
            let remainingHeight = max(0, availableHeight - usedHeight - spacingBeforeRow)
            let completeFitsWithinTwoLines = measurement.fullHeight <= measurement.twoLineHeight + measurementTolerance

            let representation: MyRAMWidgetPinnedContentRowRepresentation
            let rowHeight: CGFloat
            if completeFitsWithinTwoLines {
                representation = .complete
                rowHeight = measurement.fullHeight
            } else {
                representation = .truncatedTwoLines
                rowHeight = measurement.twoLineHeight
            }

            guard fits(rowHeight, within: remainingHeight) else {
                return MyRAMWidgetPinnedContentAllocationPlan(
                    rows: rows,
                    allPinsRepresented: false,
                    bodyIsEligible: false,
                    bodyMaximumHeight: 0
                )
            }

            usedHeight += spacingBeforeRow + rowHeight
            rows.append(
                MyRAMWidgetPinnedContentAllocatedRow(
                    pinIndex: index,
                    representation: representation,
                    height: rowHeight
                )
            )
        }

        let bodyHeight = bodyAvailableHeight(
            afterPinnedHeight: usedHeight,
            hasPinnedRows: !rows.isEmpty,
            bodyMinimumHeight: bodyMinimumHeight,
            availableHeight: availableHeight,
            verticalSpacing: verticalSpacing
        )
        return MyRAMWidgetPinnedContentAllocationPlan(
            rows: rows,
            allPinsRepresented: true,
            bodyIsEligible: bodyHeight > 0,
            bodyMaximumHeight: bodyHeight
        )
    }

    private func bodyAvailableHeight(
        afterPinnedHeight pinnedHeight: CGFloat,
        hasPinnedRows: Bool,
        bodyMinimumHeight: CGFloat?,
        availableHeight: CGFloat,
        verticalSpacing: CGFloat
    ) -> CGFloat {
        guard let bodyMinimumHeight else { return 0 }
        let spacingBeforeBody = hasPinnedRows ? verticalSpacing : 0
        let remainingHeight = max(0, availableHeight - pinnedHeight - spacingBeforeBody)
        guard fits(bodyMinimumHeight, within: remainingHeight) else { return 0 }
        return remainingHeight
    }

    private func fits(_ requiredHeight: CGFloat, within availableHeight: CGFloat) -> Bool {
        requiredHeight <= availableHeight + measurementTolerance
    }
}

enum MyRAMWidgetPinnedContentRowVariant: Sendable {
    case full
    case oneLine
    case twoLines

    var lineLimit: Int? {
        switch self {
        case .full:
            nil
        case .oneLine:
            1
        case .twoLines:
            2
        }
    }
}

enum MyRAMWidgetPinnedContentSubviewRole: Equatable, Sendable {
    case pinFullProbe(Int)
    case pinOneLineProbe(Int)
    case pinTwoLinesProbe(Int)
    case pinRender(Int)
    case bodyOneLineProbe
    case body
}

enum MyRAMWidgetPinnedContentSubviewDisposition: Equatable, Sendable {
    case measurementOnly
    case renderPin(MyRAMWidgetPinnedContentAllocatedRow)
    case renderBody
    case suppressed
}

struct MyRAMWidgetPinnedContentSubviewDispositionPolicy: Sendable {
    func disposition(
        for role: MyRAMWidgetPinnedContentSubviewRole,
        allocation: MyRAMWidgetPinnedContentAllocationPlan
    ) -> MyRAMWidgetPinnedContentSubviewDisposition {
        switch role {
        case .pinFullProbe, .pinOneLineProbe, .pinTwoLinesProbe, .bodyOneLineProbe:
            return .measurementOnly
        case let .pinRender(index):
            guard let row = allocation.rows.first(where: { $0.pinIndex == index }) else {
                return .suppressed
            }
            return .renderPin(row)
        case .body:
            return allocation.bodyIsEligible ? .renderBody : .suppressed
        }
    }
}

struct MyRAMWidgetPinnedContentLayout<PinRow: View, BodyRow: View>: View {
    private let pinnedTexts: [String]
    private let bodyText: String?
    private let verticalSpacing: CGFloat
    private let pinRow: (String, MyRAMWidgetPinnedContentRowVariant) -> PinRow
    private let bodyRow: (String, Bool) -> BodyRow

    init(
        pinnedTexts: [String],
        bodyText: String?,
        verticalSpacing: CGFloat,
        @ViewBuilder pinRow: @escaping (String, MyRAMWidgetPinnedContentRowVariant) -> PinRow,
        @ViewBuilder bodyRow: @escaping (String, Bool) -> BodyRow
    ) {
        self.pinnedTexts = pinnedTexts
        self.bodyText = bodyText
        self.verticalSpacing = verticalSpacing
        self.pinRow = pinRow
        self.bodyRow = bodyRow
    }

    var body: some View {
        MyRAMWidgetPinnedContentSwiftUILayout(
            pinCount: pinnedTexts.count,
            verticalSpacing: verticalSpacing
        ) {
            ForEach(Array(pinnedTexts.enumerated()), id: \.offset) { index, text in
                pinRow(text, .full)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .layoutValue(
                        key: MyRAMWidgetPinnedContentSubviewRoleKey.self,
                        value: .pinFullProbe(index)
                    )

                pinRow(text, .oneLine)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .layoutValue(
                        key: MyRAMWidgetPinnedContentSubviewRoleKey.self,
                        value: .pinOneLineProbe(index)
                    )

                pinRow(text, .twoLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .layoutValue(
                        key: MyRAMWidgetPinnedContentSubviewRoleKey.self,
                        value: .pinTwoLinesProbe(index)
                    )

                ViewThatFits(in: .vertical) {
                    pinRow(text, .full)
                        .fixedSize(horizontal: false, vertical: true)
                    pinRow(text, .twoLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutValue(
                    key: MyRAMWidgetPinnedContentSubviewRoleKey.self,
                    value: .pinRender(index)
                )
            }

            if let bodyText {
                bodyRow(bodyText, true)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .layoutValue(
                        key: MyRAMWidgetPinnedContentSubviewRoleKey.self,
                        value: .bodyOneLineProbe
                    )

                bodyRow(bodyText, false)
                    .layoutValue(
                        key: MyRAMWidgetPinnedContentSubviewRoleKey.self,
                        value: .body
                    )
            }
        }
        .clipped()
    }
}

private struct MyRAMWidgetPinnedContentSubviewRoleKey: LayoutValueKey {
    static let defaultValue: MyRAMWidgetPinnedContentSubviewRole? = nil
}

private struct MyRAMWidgetPinnedContentSwiftUILayout: Layout {
    let pinCount: Int
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let width = resolvedWidth(for: proposal, subviews: subviews)
        let naturalHeight = naturalHeight(width: width, subviews: subviews)
        let height = proposal.height ?? naturalHeight
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let measurements = pinMeasurements(width: bounds.width, subviews: subviews)
        let bodyMinimumHeight = bodyOneLineMinimumHeight(width: bounds.width, subviews: subviews)
        let allocation = MyRAMWidgetPinnedContentAllocationPolicy().plan(
            pinMeasurements: measurements,
            bodyMinimumHeight: bodyMinimumHeight,
            availableHeight: bounds.height,
            verticalSpacing: verticalSpacing
        )
        let dispositionPolicy = MyRAMWidgetPinnedContentSubviewDispositionPolicy()
        let rowOrigins = rowOrigins(for: allocation, startingAt: bounds.minY)
        let bodyOrigin = bodyOrigin(for: allocation, startingAt: bounds.minY)

        for subview in subviews {
            guard let role = subview[MyRAMWidgetPinnedContentSubviewRoleKey.self] else {
                park(subview, outside: bounds)
                continue
            }

            switch dispositionPolicy.disposition(for: role, allocation: allocation) {
            case .measurementOnly, .suppressed:
                park(subview, outside: bounds)
            case let .renderPin(row):
                guard let y = rowOrigins[row.pinIndex] else {
                    park(subview, outside: bounds)
                    continue
                }
                subview.place(
                    at: CGPoint(x: bounds.minX, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: row.height)
                )
            case .renderBody:
                let remainingHeight = max(
                    0,
                    min(allocation.bodyMaximumHeight, bounds.maxY - bodyOrigin)
                )
                guard remainingHeight > 0 else {
                    park(subview, outside: bounds)
                    continue
                }
                subview.place(
                    at: CGPoint(x: bounds.minX, y: bodyOrigin),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: remainingHeight)
                )
            }
        }
    }

    private func resolvedWidth(for proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width {
            return width
        }
        return subviews
            .map { $0.sizeThatFits(.unspecified).width }
            .max() ?? 0
    }

    private func naturalHeight(width: CGFloat, subviews: Subviews) -> CGFloat {
        let measurements = pinMeasurements(width: width, subviews: subviews)
        let bodyFullHeight = subview(with: .body, in: subviews)?
            .sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        let rowHeight = measurements.reduce(CGFloat.zero) { partial, measurement in
            partial + min(measurement.fullHeight, measurement.twoLineHeight)
        }
        let pinSpacing = CGFloat(max(0, measurements.count - 1)) * verticalSpacing
        let bodySpacing = bodyFullHeight > 0 && !measurements.isEmpty ? verticalSpacing : 0
        return rowHeight + pinSpacing + bodySpacing + bodyFullHeight
    }

    private func pinMeasurements(
        width: CGFloat,
        subviews: Subviews
    ) -> [MyRAMWidgetPinnedContentMeasurement] {
        (0..<pinCount).compactMap { index in
            guard let full = subview(with: .pinFullProbe(index), in: subviews),
                  let oneLine = subview(with: .pinOneLineProbe(index), in: subviews),
                  let twoLines = subview(with: .pinTwoLinesProbe(index), in: subviews) else {
                return nil
            }
            let proposal = ProposedViewSize(width: width, height: nil)
            return MyRAMWidgetPinnedContentMeasurement(
                fullHeight: full.sizeThatFits(proposal).height,
                oneLineHeight: oneLine.sizeThatFits(proposal).height,
                twoLineHeight: twoLines.sizeThatFits(proposal).height
            )
        }
    }

    private func bodyOneLineMinimumHeight(width: CGFloat, subviews: Subviews) -> CGFloat? {
        subview(with: .bodyOneLineProbe, in: subviews)?
            .sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }

    private func rowOrigins(
        for allocation: MyRAMWidgetPinnedContentAllocationPlan,
        startingAt startY: CGFloat
    ) -> [Int: CGFloat] {
        var origins: [Int: CGFloat] = [:]
        var y = startY

        for (position, row) in allocation.rows.enumerated() {
            if position > 0 {
                y += verticalSpacing
            }
            origins[row.pinIndex] = y
            y += row.height
        }

        return origins
    }

    private func bodyOrigin(
        for allocation: MyRAMWidgetPinnedContentAllocationPlan,
        startingAt startY: CGFloat
    ) -> CGFloat {
        var y = startY
        for (position, row) in allocation.rows.enumerated() {
            if position > 0 {
                y += verticalSpacing
            }
            y += row.height
        }
        if !allocation.rows.isEmpty {
            y += verticalSpacing
        }
        return y
    }

    private func park(_ subview: LayoutSubview, outside bounds: CGRect) {
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY + 1),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: 0, height: 0)
        )
    }

    private func subview(
        with role: MyRAMWidgetPinnedContentSubviewRole,
        in subviews: Subviews
    ) -> LayoutSubview? {
        subviews.first { $0[MyRAMWidgetPinnedContentSubviewRoleKey.self] == role }
    }
}
