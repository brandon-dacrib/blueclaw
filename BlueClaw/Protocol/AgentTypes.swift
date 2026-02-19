import Foundation

nonisolated struct Agent: Identifiable, Sendable {
    let id: String
    let name: String
    let emoji: String?
    let theme: String?

    init(id: String, name: String, emoji: String? = nil, theme: String? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.theme = theme
    }

    init(from dict: [String: Any]) {
        id = dict["id"] as? String ?? ""
        name = dict["name"] as? String ?? dict["id"] as? String ?? ""
        if let identity = dict["identity"] as? [String: Any] {
            emoji = identity["emoji"] as? String
            theme = identity["theme"] as? String
        } else {
            emoji = nil
            theme = nil
        }
    }

    var displayName: String {
        if let emoji {
            "\(emoji) \(name)"
        } else {
            name
        }
    }

    func sessionKey(suffix: String = "main") -> String {
        "agent:\(id):\(suffix)"
    }
}
