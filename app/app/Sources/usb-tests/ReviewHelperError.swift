import Foundation
enum HelperError: LocalizedError, Equatable {
    case io(String)

    var errorDescription: String? {
        switch self {
        case .io(let detail): detail
        }
    }
}
