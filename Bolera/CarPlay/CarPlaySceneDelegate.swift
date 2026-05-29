import UIKit
import CarPlay
import BoleraCore

/// CarPlay entry point. iOS instantiates this delegate when a head unit
/// connects and the user launches Bolera from CarPlay's app grid. We
/// own a `CPInterfaceController` for the duration of the session and
/// hand it off to `CarPlayCoordinator`, which builds the template
/// hierarchy and reacts to user taps by driving the same
/// `AudioPlayer.shared` the phone UI uses.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        // Re-assert the auth manager wiring as a safety net for
        // CarPlay-cold-launch (`@main` runs before any scene delegate,
        // but the weak `authManager` ref on `AudioPlayer.shared` could
        // theoretically be nil between init and the first scene). Don't
        // call `configureAudioSession()` here — `BoleraApp.init` already
        // did it, and re-activating the session mid handoff (which is
        // exactly when iOS notifies us of CarPlay connection) can
        // interrupt a stream the phone scene already started.
        AudioPlayer.shared.authManager = AuthManager.shared
        let coord = CarPlayCoordinator(interfaceController: interfaceController)
        self.coordinator = coord
        coord.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        coordinator = nil
    }
}
