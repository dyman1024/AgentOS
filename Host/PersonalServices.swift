import AgentOSCore
import Contacts
import EventKit
import Foundation

@MainActor final class PersonalServices {
  let events = EKEventStore(), contacts = CNContactStore()
  func authorizeCalendar() async throws -> Bool { try await events.requestFullAccessToEvents() }
  func authorizeContacts() async throws -> Bool { try await contacts.requestAccess(for: .contacts) }
  func checkCalendar() throws {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
      throw HostError("denied", "请先在设置中授权日历访问")
    }
  }
  func calendars() throws -> Value {
    try checkCalendar()
    return .array(
      events.calendars(for: .event).map {
        [
          "id": .string($0.calendarIdentifier), "title": .string($0.title),
          "writable": .bool($0.allowsContentModifications),
        ]
      })
  }
  func date(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
      throw HostError("invalid_args", "Use an ISO-8601 date with timezone")
    }
    return date
  }
  func list(_ args: Value) throws -> Value {
    try checkCalendar()
    let start = try date(args.requiredString("start"))
    let end = try date(args.requiredString("end"))
    guard end > start, end.timeIntervalSince(start) <= 90 * 86400 else {
      throw HostError("invalid_args", "Calendar range must be 1–90 days")
    }
    let predicate = events.predicateForEvents(withStart: start, end: end, calendars: nil)
    return .array(events.events(matching: predicate).prefix(500).map(eventValue))
  }
  func eventValue(_ event: EKEvent) -> Value {
    [
      "id": .string(event.eventIdentifier ?? ""),
      "calendar": .string(event.calendar.calendarIdentifier), "title": .string(event.title ?? ""),
      "notes": .string(event.notes ?? ""), "location": .string(event.location ?? ""),
      "start": .string(ISO8601DateFormatter().string(from: event.startDate)),
      "end": .string(ISO8601DateFormatter().string(from: event.endDate)),
      "allDay": .bool(event.isAllDay),
      "modified": event.lastModifiedDate.map { .string(ISO8601DateFormatter().string(from: $0)) }
        ?? .null, "attendeeCount": .number(Double(event.attendees?.count ?? 0)),
    ]
  }
  func create(_ args: Value) throws -> Value {
    try checkCalendar()
    guard args["attendees"] == nil else {
      throw HostError("denied", "Invitations require a separate irreversible service")
    }
    let event = EKEvent(eventStore: events)
    event.title = String(try args.requiredString("title").prefix(500))
    event.notes = String((args["notes"]?.string ?? "").prefix(20000))
    event.startDate = try date(args.requiredString("start"))
    event.endDate = try date(args.requiredString("end"))
    guard event.endDate > event.startDate,
      event.endDate.timeIntervalSince(event.startDate) <= 366 * 86400
    else { throw HostError("invalid_args", "Invalid event duration") }
    event.location = args["location"]?.string
    event.isAllDay = args["allDay"]?.bool ?? false
    if let id = args["calendar"]?.string {
      event.calendar = events.calendar(withIdentifier: id)
    } else {
      event.calendar = events.defaultCalendarForNewEvents
    }
    guard let calendar = event.calendar, calendar.allowsContentModifications else {
      throw HostError("denied", "Calendar is not writable")
    }
    try events.save(event, span: .thisEvent, commit: true)
    return eventValue(event)
  }
  func undo(_ original: Value) throws -> Value {
    try checkCalendar()
    guard let event = events.event(withIdentifier: try original.requiredString("id")),
      eventValue(event) == original
    else { throw HostError("conflict", "Calendar event changed after creation") }
    guard event.attendees?.isEmpty ?? true else {
      throw HostError("denied", "Cannot compensate an event with invitees")
    }
    try events.remove(event, span: .thisEvent, commit: true)
    return ["removed": true]
  }
  func contactList(_ args: Value) throws -> Value {
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
      throw HostError("denied", "请先在设置中授权通讯录访问")
    }
    let keys: [CNKeyDescriptor] = [
      CNContactIdentifierKey as NSString, CNContactGivenNameKey as NSString,
      CNContactFamilyNameKey as NSString, CNContactEmailAddressesKey as NSString,
      CNContactPhoneNumbersKey as NSString,
    ]
    let request = CNContactFetchRequest(keysToFetch: keys)
    request.sortOrder = .userDefault
    let query = (args["query"]?.string ?? "").lowercased()
    let limit = min(max(args["limit"]?.int ?? 50, 1), 200)
    var result: [Value] = []
    try contacts.enumerateContacts(with: request) { contact, stop in
      let name = contact.givenName + " " + contact.familyName
      let emails = contact.emailAddresses.map { String($0.value) }
      if query.isEmpty || (name + emails.joined()).lowercased().contains(query) {
        result.append([
          "id": .string(contact.identifier),
          "name": .string(name.trimmingCharacters(in: .whitespaces)),
          "emails": .array(emails.map(Value.string)),
          "phones": .array(contact.phoneNumbers.map { .string($0.value.stringValue) }),
        ])
      }
      if result.count >= limit { stop.pointee = true }
    }
    return .array(result)
  }
}
