import SwiftUI
import BoleraCore

/// Context-menu entry for ignoring/unignoring a single track.
/// Free users see the entry as a paywall prompt.
struct IgnoreToggleButton: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    var body: some View {
        if pro.isPro {
            if ignored.isIgnored(item.Id) {
                Button {
                    ignored.unignore(item.Id)
                } label: {
                    Label("Stop Ignoring", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    ignored.ignore(item)
                } label: {
                    Label("Ignore Track", systemImage: "hand.raised.slash")
                }
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                Label("Ignore Track (Pro)", systemImage: "lock.fill")
            }
            .sheet(isPresented: $showPaywall) {
                NavigationStack { PaywallView() }
                    .environmentObject(pro)
            }
        }
    }
}

/// Swipe-action variant for List rows.
struct IgnoreSwipeButton: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore

    var body: some View {
        if pro.isPro {
            if ignored.isIgnored(item.Id) {
                Button {
                    ignored.unignore(item.Id)
                } label: {
                    Label("Unignore", systemImage: "arrow.uturn.backward")
                }
                .tint(.gray)
            } else {
                Button {
                    ignored.ignore(item)
                } label: {
                    Label("Ignore", systemImage: "hand.raised.slash")
                }
                .tint(.orange)
            }
        } else {
            EmptyView()
        }
    }
}
