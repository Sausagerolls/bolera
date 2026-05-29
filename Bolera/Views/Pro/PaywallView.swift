import SwiftUI
import BoleraCore
import StoreKit

/// One-time purchase paywall for Bolera Pro. Shown as a sheet from any
/// pro-gated entry point.
struct PaywallView: View {
    @EnvironmentObject var pro: ProEntitlementStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.10),
                                    Color(red: 0.18, green: 0.05, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    header
                    featureList
                    purchaseButton
                    restoreButton
                    if let err = pro.lastError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Text("One-time purchase. Restores across all your devices signed in to the same Apple ID. No subscription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    Spacer(minLength: 32)
                }
                .padding(.top, 40)
            }
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onChange(of: pro.isPro) { _, newValue in
            if newValue { dismiss() }
        }
        .task { await pro.refresh() }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("BoleraGlyph")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            Text("Bolera Pro")
                .font(.system(size: 34, weight: .heavy))
            Text("Unlock the full experience")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow("slider.vertical.3", "Full 10-band equalizer",
                       "Graphic + parametric modes with curated presets and custom saves.")
            featureRow("rectangle.stack.badge.minus", "Library toggles",
                       "Hide entire Jellyfin libraries — your Christmas songs stay out of the rotation.")
            featureRow("hand.raised.slash.fill", "Ignore tracks",
                       "Silently skip songs you never want to hear, synced across devices.")
            featureRow("sparkles", "Priority access to new features",
                       "Pro unlocks new features first. You're the reason Bolera keeps shipping.")
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func featureRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var purchaseButton: some View {
        let product = pro.products.first(where: { $0.id == ProProductIDs.lifetime })
        Button {
            Task { await pro.purchaseLifetime() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.accentColor)
                    .frame(height: 56)
                if pro.purchaseInFlight {
                    ProgressView().tint(.white)
                } else if let p = product {
                    Text("Unlock — \(p.displayPrice)")
                        .font(.headline)
                        .foregroundStyle(.white)
                } else {
                    Text("Loading…")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .disabled(pro.purchaseInFlight || product == nil)
        .padding(.horizontal)
    }

    private var restoreButton: some View {
        Button {
            Task { await pro.restore() }
        } label: {
            Text("Restore Purchases")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .disabled(pro.purchaseInFlight)
    }
}
