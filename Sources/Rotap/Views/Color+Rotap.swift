import SwiftUI

extension Color {
    /// Rotap's record red, #EB4C46. Used for everything that means "recording".
    static let record = Color(red: 235 / 255, green: 76 / 255, blue: 70 / 255)
    /// Tint for Liquid Glass prominent buttons: glass adds a highlight, so this is pre-darkened
    /// until the rendered fill measures #EB4C46.
    static let recordGlassTint = Color(red: 227 / 255, green: 52 / 255, blue: 55 / 255)
}

extension ShapeStyle where Self == Color {
    static var record: Color { .record }
}
