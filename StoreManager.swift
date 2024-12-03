import StoreKit
import OSLog

@MainActor
class StoreManager: ObservableObject {
    static let shared = StoreManager()
    
    @Published private(set) var subscriptions: [Product] = []
    @Published private(set) var purchasedSubscriptions: [Product] = []
    @Published var isLoading = false
    
    private let productIds = [
        "com.example.myapp.monthly",
        "com.example.myapp.lifetime"
    ]
    
    private var updateListenerTask: Task<Void, Error>?
    
    init() {
        updateListenerTask = listenForTransactions()
        
        Task {
            await requestProducts()
        }
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    func requestProducts() async {
        isLoading = true
        do {
            print("Requesting products for IDs: \(productIds)")
            subscriptions = try await Product.products(for: productIds)
            print("Received products: \(subscriptions.count)")
            try await checkSubscriptionStatus()
        } catch {
            print("Failed to load products: \(error)")
            Logger.app.error("Failed to load products: \(error.localizedDescription)")
        }
        isLoading = false
    }
    
    func purchase(_ product: Product) async throws -> Transaction? {
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            try await checkSubscriptionStatus()
            return transaction
        case .userCancelled:
            return nil
        case .pending:
            return nil
        @unknown default:
            return nil
        }
    }
    
    func restorePurchases() async throws {
        try await AppStore.sync()
        try await checkSubscriptionStatus()
    }
    
    private func checkSubscriptionStatus() async throws {
        var purchasedSubs: [Product] = []
        
        for await result in Transaction.currentEntitlements {
            let transaction = try checkVerified(result)
            
            if let subscription = subscriptions.first(where: { $0.id == transaction.productID }) {
                purchasedSubs.append(subscription)
            }
        }
        
        purchasedSubscriptions = purchasedSubs
    }
    
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                let transaction = try await self.checkVerified(result)
                await transaction.finish()
                try await self.checkSubscriptionStatus()
            }
        }
    }
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

enum StoreError: Error {
    case failedVerification
    case unknown
} 
