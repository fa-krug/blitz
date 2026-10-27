import SwiftUI

/// Stepped by rotation: a symbol effect redraws every frame and stalls main on the window server.
struct Spinner: View {
    private static let stepsPerSecond = 12.0
    private static let spokes = 8.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1 / Self.stepsPerSecond)) { context in
            Image(systemName: "progress.indicator", variableValue: 0.6)
                .rotationEffect(.degrees(Self.angle(at: context.date)))
        }
    }

    private static func angle(at date: Date) -> Double {
        let step = (date.timeIntervalSinceReferenceDate * stepsPerSecond).rounded(.down)
        return step.truncatingRemainder(dividingBy: spokes) * 360 / spokes
    }
}
