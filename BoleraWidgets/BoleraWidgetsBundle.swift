import WidgetKit
import SwiftUI

@main
struct BoleraWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RecentlyPlayedWidget()
        MixesWidget()
    }
}
