import AppKit
import SwiftUI

/// Native controls with an explicit layout contract: fill the proposed width,
/// rather than centering an intrinsic-width control inside a SwiftUI frame.
struct AlignedSegments<Value: Hashable>: NSViewRepresentable {
    let values: [Value]
    let titles: [String]
    @Binding var selection: Value
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject {
        var parent: AlignedSegments
        init(_ parent: AlignedSegments) { self.parent = parent }
        @objc func select(_ sender: NSSegmentedControl) {
            guard parent.values.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.values[sender.selectedSegment]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.select(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.segmentCount = titles.count
        for (index, title) in titles.enumerated() { control.setLabel(title, forSegment: index) }
        control.selectedSegment = values.firstIndex(of: selection) ?? -1
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 28)
    }
}

struct AlignedLanguagePicker: NSViewRepresentable {
    @Binding var selection: String
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject {
        var parent: AlignedLanguagePicker
        init(_ parent: AlignedLanguagePicker) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            guard Language.common.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = Language.common[sender.indexOfSelectedItem].code
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.target = context.coordinator
        control.action = #selector(Coordinator.select(_:))
        control.addItems(withTitles: Language.common.map(\.endonym))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        control.selectItem(at: Language.common.firstIndex { $0.code == selection } ?? -1)
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 28)
    }
}

struct AlignedSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject {
        var parent: AlignedSlider
        init(_ parent: AlignedSlider) { self.parent = parent }
        @objc func change(_ sender: NSSlider) {
            let raw = sender.doubleValue
            parent.value = parent.step.map { (raw / $0).rounded() * $0 } ?? raw
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let control = NSSlider(value: value, minValue: range.lowerBound,
            maxValue: range.upperBound, target: context.coordinator,
            action: #selector(Coordinator.change(_:)))
        control.isContinuous = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSSlider, context: Context) {
        context.coordinator.parent = self
        control.minValue = range.lowerBound
        control.maxValue = range.upperBound
        control.doubleValue = value
        control.altIncrementValue = step ?? (range.upperBound - range.lowerBound) / 100
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: 24)
    }
}
