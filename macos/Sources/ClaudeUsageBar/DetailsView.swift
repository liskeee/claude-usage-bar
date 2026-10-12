import AppKit
import ClaudeUsageBarCore
import Observation
import SwiftUI

/// What the popover shows; the controller updates it.
@MainActor @Observable final class DetailsModel {
    var state = UsageState.initial
    var account: String?
    var now = Date()
    let texts: Texts
    @ObservationIgnored var onRefresh: () -> Void = {}

    init(texts: Texts) { self.texts = texts }
}

/// The details popover: one block per limit, then a footer with the data's age and a refresh link
/// (the Windows DetailsRenderer layout).
struct DetailsView: View {
    let model: DetailsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = scheme == .dark ? Palette.dark : Palette.light
        let limits = model.state.snapshot?.limits ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: Spark.image(size: 15, color: palette.clay))
                Text(DisplayText.heading(model.state)).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                if let account = model.account {
                    Text(account).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(height: 44)
            if limits.isEmpty {
                Text(DisplayText.empty(model.state, model.texts))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(height: 58, alignment: .leading)
            }
            ForEach(Array(limits.enumerated()), id: \.offset) { _, limit in
                LimitBlock(limit: limit, now: model.now, texts: model.texts, palette: palette)
            }
            Divider()
            HStack {
                Text(DisplayText.footer(model.state, now: model.now, model.texts)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(model.texts.popup.refresh) { model.onRefresh() }.buttonStyle(.link).font(.system(size: 11))
            }
            .frame(height: 40)
        }
        .padding(.horizontal, 16)
        .frame(width: 300)
    }
}

private struct LimitBlock: View {
    let limit: LimitInfo
    let now: Date
    let texts: Texts
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(Format.limitLabel(limit, texts)).font(.system(size: 12))
                Spacer()
                Text(Format.percent(limit.usedPercent))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: palette.number(limit.usedPercent)))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: palette.track))
                    Capsule().fill(Color(nsColor: palette.severity(limit.usedPercent)))
                        .frame(width: max(6, geometry.size.width * min(max(limit.usedPercent, 0), 100) / 100))
                }
            }
            .frame(height: 6)
            if let reset = limit.resetsAt {
                Text(DisplayText.resetLine(reset, now: now, texts)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 58)
    }
}
