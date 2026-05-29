import SwiftUI
import BoleraCore
import StoreKit

struct PaywallView_Mac: View {
    @EnvironmentObject var pro: ProEntitlementStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image("BoleraGlyph")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
            Text("Bolera Pro").font(.title).bold()
            Text("Unlock the full experience").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                feature("slider.vertical.3", "Full 10-band EQ + presets")
                feature("rectangle.stack.badge.minus", "Hide libraries you don't want")
                feature("hand.raised.slash.fill", "Ignore tracks across devices")
                feature("desktopcomputer", "Native Mac app, synced via iCloud")
                feature("sparkles", "Priority access to new features")
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if let err = pro.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Restore") { Task { await pro.restore() } }
                Button(action: { Task { await pro.purchaseLifetime() } }) {
                    if pro.purchaseInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Unlock — \(displayPrice)")
                    }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(pro.purchaseInFlight)
            }

            Text("One-time purchase. Universal — works on iPhone, iPad, and Mac with the same Apple ID.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 460)
        .task { await pro.refresh() }
        .onChange(of: pro.isPro) { _, isPro in if isPro { dismiss() } }
    }

    private var displayPrice: String {
        pro.products.first(where: { $0.id == ProProductIDs.lifetime })?.displayPrice ?? "$4.99"
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 24)
            Text(text)
        }
    }
}

/// Swipe-action helper used by the Mac queue list.
struct IgnoreSwipeButton_Mac: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore

    var body: some View {
        if pro.isPro {
            if ignored.isIgnored(item.Id) {
                Button { ignored.unignore(item.Id) } label: {
                    Label("Unignore", systemImage: "arrow.uturn.backward")
                }.tint(.gray)
            } else {
                Button { ignored.ignore(item) } label: {
                    Label("Ignore", systemImage: "hand.raised.slash")
                }.tint(.orange)
            }
        } else {
            EmptyView()
        }
    }
}
