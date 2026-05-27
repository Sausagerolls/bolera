import SwiftUI
import BoleraCore

/// Wraps a feature view. If the user is Pro, shows the content;
/// otherwise shows a lock overlay with a CTA that presents the paywall.
struct ProGated<Content: View>: View {
    let feature: String
    let blurb: String
    let content: () -> Content

    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    init(feature: String,
         blurb: String,
         @ViewBuilder content: @escaping () -> Content) {
        self.feature = feature
        self.blurb = blurb
        self.content = content
    }

    var body: some View {
        Group {
            if pro.isPro {
                content()
            } else {
                lockedState
            }
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallView() }
                .environmentObject(pro)
        }
    }

    private var lockedState: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.tint)
            Text(feature).font(.title2).bold()
            Text(blurb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showPaywall = true
            } label: {
                Text("Unlock Bolera Pro")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Row-level lock badge for list items. Used to nudge users from
/// inside SettingsView etc.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2).bold()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.2), in: Capsule())
            .foregroundStyle(.tint)
    }
}
