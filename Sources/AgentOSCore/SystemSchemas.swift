import Foundation

enum SystemSchemas {
  static var entries: [(String, String, Value, Bool)] {
    let text: Value = ["type": "string"]
    let title: Value = ["type": "string", "maxLength": 2000]
    let strings: Value = ["type": "array", "items": ["type": "string"]]
    func schema(_ properties: [String: Value], required: [String]) -> Value {
      [
        "type": "object",
        "properties": .object(properties.merging(["ext": ["type": "object"]]) { a, _ in a }),
        "required": .array(required.map(Value.string)),
      ]
    }
    return [
      (
        "notes", "note",
        schema(
          ["title": title, "body": text, "tags": strings, "links": strings], required: ["title"]),
        false
      ),
      (
        "tasks", "task",
        schema(
          [
            "title": title, "body": text, "done": ["type": "boolean"], "due": text,
            "priority": ["type": "integer", "minimum": 0, "maximum": 4], "source": text,
            "tags": strings,
          ], required: ["title"]), false
      ),
      (
        "documents", "document",
        schema(
          [
            "title": title, "path": text, "body": text, "status": ["enum": ["draft", "published"]],
            "publishedUrl": text, "tags": strings,
            "citations": ["type": "array", "items": ["type": "object"]],
          ], required: ["title"]), false
      ),
      (
        "bookmarks", "bookmark",
        schema(
          [
            "title": title, "url": ["type": "string", "format": "uri"], "excerpt": text,
            "tags": strings, "savedFrom": text,
          ], required: ["title", "url"]), false
      ),
      (
        "memory", "memory",
        schema(
          [
            "title": title, "kind": ["enum": ["preference", "fact", "experience"]], "content": text,
            "source": text, "confidence": ["type": "number", "minimum": 0, "maximum": 1],
          ], required: ["content"]), true
      ),
      (
        "profile", "profile",
        schema(
          [
            "name": text, "language": text, "tone": text,
            "accounts": ["type": "array", "items": ["type": "object"]],
          ], required: ["name"]), true
      ),
      (
        "contacts", "contact",
        schema(
          ["name": text, "emails": strings, "phones": strings, "notes": text], required: ["name"]),
        true
      ),
      (
        "mail", "mail.summary",
        schema(
          [
            "account": text, "folder": text, "from": text, "to": strings, "subject": text,
            "date": text, "snippet": text, "flags": strings,
          ], required: ["account", "subject"]), true
      ),
      (
        "media", "media.item",
        schema(
          [
            "title": title, "path": text, "kind": ["enum": ["movie", "episode", "music"]],
            "year": ["type": "integer"], "duration": ["type": "number", "minimum": 0],
            "poster": text, "progress": ["type": "number", "minimum": 0],
          ], required: ["title", "path"]), false
      ),
    ]
  }
}
