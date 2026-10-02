import Foundation

enum RevealGesture: String, CaseIterable, Identifiable, Sendable {
    case scratch, blow, shake

    var id: Self { self }

    var title: String {
        switch self {
        case .scratch: "Gratter"
        case .blow: "Souffler"
        case .shake: "Secouer"
        }
    }

    var symbol: String {
        switch self {
        case .scratch: "hand.draw"
        case .blow: "wind"
        case .shake: "iphone.radiowaves.left.and.right"
        }
    }

    var hint: String {
        switch self {
        case .scratch: "Gratte la photo du bout du doigt"
        case .blow: "Souffle sur le bas de l'iPhone"
        case .shake: "Secoue ton iPhone"
        }
    }
}

enum MaskKind: String, CaseIterable, Identifiable, Sendable {
    case frost, snow, paper, gold

    var id: Self { self }

    var title: String {
        switch self {
        case .frost: "Givre"
        case .snow: "Neige"
        case .paper: "Papier"
        case .gold: "Doré"
        }
    }

    var symbol: String {
        switch self {
        case .frost: "snowflake"
        case .snow: "cloud.snow"
        case .paper: "gift"
        case .gold: "sparkles"
        }
    }
}
