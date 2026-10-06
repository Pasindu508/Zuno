import Foundation

/// The 25 administrative districts of Sri Lanka with a principal city and coordinates,
/// used for location selection, "near you" ranking and distance filters.
enum SriLankaLocations {
    struct Place: Identifiable, Hashable, Sendable {
        var city: String
        var district: String
        var province: String
        var location: GeoPoint
        var id: String { "\(city)-\(district)" }
    }

    static let places: [Place] = [
        Place(city: "Colombo", district: "Colombo", province: "Western", location: .init(latitude: 6.9271, longitude: 79.8612)),
        Place(city: "Moratuwa", district: "Colombo", province: "Western", location: .init(latitude: 6.7730, longitude: 79.8816)),
        Place(city: "Dehiwala-Mount Lavinia", district: "Colombo", province: "Western", location: .init(latitude: 6.8390, longitude: 79.8650)),
        Place(city: "Sri Jayawardenepura Kotte", district: "Colombo", province: "Western", location: .init(latitude: 6.8868, longitude: 79.9187)),
        Place(city: "Gampaha", district: "Gampaha", province: "Western", location: .init(latitude: 7.0873, longitude: 79.9925)),
        Place(city: "Negombo", district: "Gampaha", province: "Western", location: .init(latitude: 7.2083, longitude: 79.8358)),
        Place(city: "Kalutara", district: "Kalutara", province: "Western", location: .init(latitude: 6.5854, longitude: 79.9607)),
        Place(city: "Kandy", district: "Kandy", province: "Central", location: .init(latitude: 7.2906, longitude: 80.6337)),
        Place(city: "Matale", district: "Matale", province: "Central", location: .init(latitude: 7.4675, longitude: 80.6234)),
        Place(city: "Nuwara Eliya", district: "Nuwara Eliya", province: "Central", location: .init(latitude: 6.9497, longitude: 80.7891)),
        Place(city: "Galle", district: "Galle", province: "Southern", location: .init(latitude: 6.0535, longitude: 80.2210)),
        Place(city: "Matara", district: "Matara", province: "Southern", location: .init(latitude: 5.9549, longitude: 80.5550)),
        Place(city: "Hambantota", district: "Hambantota", province: "Southern", location: .init(latitude: 6.1241, longitude: 81.1185)),
        Place(city: "Jaffna", district: "Jaffna", province: "Northern", location: .init(latitude: 9.6615, longitude: 80.0255)),
        Place(city: "Kilinochchi", district: "Kilinochchi", province: "Northern", location: .init(latitude: 9.3803, longitude: 80.3770)),
        Place(city: "Mannar", district: "Mannar", province: "Northern", location: .init(latitude: 8.9810, longitude: 79.9044)),
        Place(city: "Vavuniya", district: "Vavuniya", province: "Northern", location: .init(latitude: 8.7514, longitude: 80.4971)),
        Place(city: "Mullaitivu", district: "Mullaitivu", province: "Northern", location: .init(latitude: 9.2671, longitude: 80.8142)),
        Place(city: "Batticaloa", district: "Batticaloa", province: "Eastern", location: .init(latitude: 7.7310, longitude: 81.6747)),
        Place(city: "Ampara", district: "Ampara", province: "Eastern", location: .init(latitude: 7.2975, longitude: 81.6820)),
        Place(city: "Trincomalee", district: "Trincomalee", province: "Eastern", location: .init(latitude: 8.5874, longitude: 81.2152)),
        Place(city: "Kurunegala", district: "Kurunegala", province: "North Western", location: .init(latitude: 7.4863, longitude: 80.3623)),
        Place(city: "Puttalam", district: "Puttalam", province: "North Western", location: .init(latitude: 8.0362, longitude: 79.8283)),
        Place(city: "Anuradhapura", district: "Anuradhapura", province: "North Central", location: .init(latitude: 8.3114, longitude: 80.4037)),
        Place(city: "Polonnaruwa", district: "Polonnaruwa", province: "North Central", location: .init(latitude: 7.9403, longitude: 81.0188)),
        Place(city: "Badulla", district: "Badulla", province: "Uva", location: .init(latitude: 6.9934, longitude: 81.0550)),
        Place(city: "Monaragala", district: "Monaragala", province: "Uva", location: .init(latitude: 6.8728, longitude: 81.3507)),
        Place(city: "Ratnapura", district: "Ratnapura", province: "Sabaragamuwa", location: .init(latitude: 6.6828, longitude: 80.3992)),
        Place(city: "Kegalle", district: "Kegalle", province: "Sabaragamuwa", location: .init(latitude: 7.2513, longitude: 80.3464)),
    ]

    static var districts: [String] { Array(Set(places.map(\.district))).sorted() }

    static func place(named city: String) -> Place? { places.first { $0.city == city } }

    static let defaultPlace = places[0]

    /// The nearest listed city to a coordinate (used after a location permission grant).
    static func nearest(to point: GeoPoint) -> Place {
        places.min { $0.location.distance(to: point) < $1.location.distance(to: point) } ?? defaultPlace
    }

    /// Validates a Sri Lankan mobile number and returns it in E.164 (+947XXXXXXXX).
    static func normalizedMobile(_ raw: String) -> String? {
        var digits = raw.filter(\.isNumber)
        if digits.hasPrefix("94") { digits.removeFirst(2) }
        if digits.hasPrefix("0") { digits.removeFirst() }
        guard digits.count == 9, digits.hasPrefix("7") else { return nil }
        return "+94" + digits
    }
}
