import Foundation
import StoreKit
import Combine

/// Single source of truth for whether the user owns Bolera Pro.
/// Loads products from StoreKit, observes transactions for the lifetime
/// of the app, and persists the last-known entitlement so UI doesn't
/// flicker offline. Designed as a `@MainActor` singleton.
@MainActor
public final class ProEntitlementStore: ObservableObject {

    public static let shared = ProEntitlementStore()

    /// True iff the user has unlocked Bolera Pro on this Apple ID.
    @Published public private(set) var isPro: Bool
    /// Loaded Product metadata so the paywall can show price + title.
    @Published public private(set) var products: [Product] = []
    /// In-progress purchase, used by paywall for spinner state.
    @Published public private(set) var purchaseInFlight: Bool = false
    /// Last error surfaced from a purchase or restore attempt.
    @Published public var lastError: String?

    private static let cacheKey = "bolera.pro.isPro"
    private var updatesTask: Task<Void, Never>?

    private init() {
        self.isPro = UserDefaults.standard.bool(forKey: Self.cacheKey)
        self.updatesTask = Task { [weak self] in
            await self?.listenForTransactionUpdates()
        }
        Task { await refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Loads product metadata and recomputes the current entitlement.
    public func refresh() async {
        await loadProducts()
        await recomputeEntitlement()
    }

    private func loadProducts() async {
        do {
            let loaded = try await Product.products(for: ProProductIDs.all)
            self.products = loaded.sorted { $0.price < $1.price }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Walks current entitlements and updates `isPro`.
    public func recomputeEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               ProProductIDs.all.contains(tx.productID),
               tx.revocationDate == nil {
                owned = true
            }
        }
        setPro(owned)
    }

    /// Buy the lifetime unlock.
    public func purchaseLifetime() async {
        guard let product = products.first(where: { $0.id == ProProductIDs.lifetime }) else {
            lastError = "Pro product not loaded yet. Try again in a moment."
            await loadProducts()
            return
        }
        await purchase(product)
    }

    private func purchase(_ product: Product) async {
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let tx) = verification {
                    await tx.finish()
                    setPro(true)
                }
            case .userCancelled:
                break
            case .pending:
                // Ask-to-buy etc. — entitlement will arrive via Transaction.updates.
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Apple-required restore-purchases path.
    public func restore() async {
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            try await AppStore.sync()
            await recomputeEntitlement()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            if case .verified(let tx) = result {
                await tx.finish()
                await recomputeEntitlement()
            }
        }
    }

    private func setPro(_ value: Bool) {
        if isPro != value {
            isPro = value
        }
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
    }
}
