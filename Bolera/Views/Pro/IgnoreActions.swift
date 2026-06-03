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

/// Context-menu entry for ignoring/unignoring a whole artist. Anything by an
/// ignored artist is dropped from mixes, radio, and AI playlists.
struct IgnoreArtistToggleButton: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    var body: some View {
        if pro.isPro {
            if ignored.isArtistIgnored(item.Id) {
                Button {
                    ignored.unignoreArtist(item.Id)
                } label: {
                    Label("Stop Ignoring Artist", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    ignored.ignoreArtist(item)
                } label: {
                    Label("Ignore Artist", systemImage: "person.slash")
                }
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                Label("Ignore Artist (Pro)", systemImage: "lock.fill")
            }
            .sheet(isPresented: $showPaywall) {
                NavigationStack { PaywallView() }
                    .environmentObject(pro)
            }
        }
    }
}

/// Context-menu entry for ignoring/unignoring a whole album. Every track on an
/// ignored album is dropped from mixes, radio, and AI playlists.
struct IgnoreAlbumToggleButton: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    var body: some View {
        if pro.isPro {
            if ignored.isAlbumIgnored(item.Id) {
                Button {
                    ignored.unignoreAlbum(item.Id)
                } label: {
                    Label("Stop Ignoring Album", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    ignored.ignoreAlbum(item)
                } label: {
                    Label("Ignore Album", systemImage: "square.stack.3d.up.slash")
                }
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                Label("Ignore Album (Pro)", systemImage: "lock.fill")
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
