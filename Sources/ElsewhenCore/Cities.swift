import Foundation

/// One row of the list: a city's name and zone, and what else is known of it.
/// Stored as `{ name, zone, lat, lon, region, people }`, the same shape Omarchy
/// writes to shell.json, so a list can move between the two.
public struct City: Codable, Equatable, Hashable, Sendable {
  public var label: String
  public var id: String
  public var lat: Double?
  public var lon: Double?
  public var region: String?
  public var people: [String]

  public init(label: String, id: String, lat: Double? = nil, lon: Double? = nil, region: String? = nil, people: [String] = []) {
    self.label = label
    self.id = id
    self.lat = lat
    self.lon = lon
    self.region = region
    self.people = people
  }

  enum CodingKeys: String, CodingKey {
    case label = "name", id = "zone", lat, lon, region, people
  }

  // Lenient: a hand-edited entry with a stray field type loses that field, not the row.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    label = (try? c.decode(String.self, forKey: .label)) ?? ""
    id = (try? c.decode(String.self, forKey: .id)) ?? ""
    lat = try? c.decode(Double.self, forKey: .lat)
    lon = try? c.decode(Double.self, forKey: .lon)
    region = try? c.decode(String.self, forKey: .region)
    people = (try? c.decode([String].self, forKey: .people)) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(label, forKey: .label)
    try c.encode(id, forKey: .id)
    if let lat, let lon {
      try c.encode(lat, forKey: .lat)
      try c.encode(lon, forKey: .lon)
    }
    if let region, !region.isEmpty { try c.encode(region, forKey: .region) }
    if !people.isEmpty { try c.encode(people, forKey: .people) }
  }

  public var hasCoordinates: Bool { lat != nil && lon != nil }

  /// Coordinates and weather are keyed by "label|zone": two cities may share a zone.
  public var key: String { Model.factsKey(label: label, id: id) }
}

/// Where a city is, as far as a place search knows.
public struct Place: Equatable, Hashable, Sendable {
  public var lat: Double?
  public var lon: Double?
  public var region: String?

  public init(lat: Double? = nil, lon: Double? = nil, region: String? = nil) {
    self.lat = lat
    self.lon = lon
    self.region = region
  }
}

/// The city you are in: `chosen` is false only while it is the zone's own city.
public struct Here: Equatable, Sendable {
  public var city: City
  public var chosen: Bool
}

/// What a pick of "here" changes. `here` is nil to go back to the zone's own city.
public struct HerePick: Equatable, Sendable {
  public var here: City?
  public var zones: [City]
  /// The zone this Mac's clock would have to move to, "" when it is already there.
  public var zoneChange: String
}

public enum Model {
  public static let defaultZones = "Los Angeles|America/Los_Angeles, Paris|Europe/Paris, Tokyo|Asia/Tokyo"

  // ---- names and zones

  /// Keeps the list free of entries that could never name a zone.
  public static func isZoneID(_ id: String) -> Bool {
    !id.isEmpty && id.unicodeScalars.allSatisfy { s in
      (s.value < 128) && (CharacterSet.alphanumerics.contains(s) || "_+-/".unicodeScalars.contains(s))
    }
  }

  /// Labels once lived in a "Label|Zone, Label|Zone" string, so they carry neither delimiter.
  public static func cleanLabel(_ label: String?) -> String {
    let text = (label ?? "").replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "|", with: " ")
    return collapseSpaces(text)
  }

  static func collapseSpaces(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  public static func labelForZoneId(_ id: String) -> String {
    (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
  }

  public static func factsKey(label: String, id: String) -> String { label + "|" + id }

  static func isCoordinate(_ value: Double?, _ limit: Double) -> Bool {
    guard let value else { return false }
    return value.isFinite && abs(value) <= limit
  }

  /// The place facts a city may carry beyond its name and zone. Coordinates come as a pair or not at all.
  public static func withPlace(_ city: City, _ place: Place?) -> City {
    var out = city
    guard let place else { return out }
    if isCoordinate(place.lat, 90), isCoordinate(place.lon, 180) {
      out.lat = place.lat
      out.lon = place.lon
    }
    let region = collapseSpaces(place.region ?? "")
    if !region.isEmpty { out.region = region }
    return out
  }

  /// "Los Angeles|America/Los_Angeles, Asia/Tokyo" -> cities. Empty means a fresh install.
  public static func parseZones(_ spec: String?) -> [City] {
    var out: [City] = []
    for part in (spec ?? "").split(separator: ",", omittingEmptySubsequences: false) {
      let entry = part.trimmingCharacters(in: .whitespaces)
      if entry.isEmpty { continue }
      let fields = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      var label: String
      let id: String
      if fields.count >= 2 {
        label = fields[0].trimmingCharacters(in: .whitespaces)
        id = fields[1].trimmingCharacters(in: .whitespaces)
      } else {
        id = entry
        label = labelForZoneId(entry)
      }
      if !isZoneID(id) { continue }
      if label.isEmpty { label = labelForZoneId(id) }
      out.append(City(label: label, id: id))
    }
    return out
  }

  /// A stored list made safe to show: bad zones dropped, names, places and people cleaned.
  public static func normalizeCities(_ cities: [City]) -> [City] {
    var out: [City] = []
    for c in cities {
      let id = c.id.trimmingCharacters(in: .whitespaces)
      if !isZoneID(id) { continue }
      let label = cleanLabel(c.label)
      var entry = withPlace(City(label: label.isEmpty ? labelForZoneId(id) : label, id: id),
                            Place(lat: c.lat, lon: c.lon, region: c.region))
      entry.people = cleanPeople(c.people)
      out.append(entry)
    }
    return out
  }

  public static func serializeZones(_ zones: [City]) -> String {
    zones.filter { !$0.id.isEmpty }.map { $0.label.isEmpty ? $0.id : $0.label + "|" + $0.id }.joined(separator: ", ")
  }

  // ---- editing

  /// Rows and globe cities share no index space, so they meet on (label, zone id).
  public static func indexOfZone(_ zones: [City], label: String, id: String) -> Int {
    zones.firstIndex { $0.label == label && $0.id == id } ?? -1
  }

  /// Focus is held as a key so it follows the city when the list is replaced.
  public static func indexOfZoneKey(_ zones: [City], _ key: String) -> Int {
    if key.isEmpty { return -1 }
    return zones.firstIndex { $0.key == key } ?? -1
  }

  /// Two cities may share a zone, so an entry is its label and zone together.
  public static func hasEntry(_ zones: [City], id: String, label: String) -> Bool {
    zones.contains { $0.id == id && $0.label == label }
  }

  /// "Springfield" in "Missouri, US" -> "Springfield (Missouri)".
  public static func regionalName(_ name: String, _ region: String?) -> String {
    let first = cleanLabel((region ?? "").split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "")
    return first.isEmpty ? name : name + " (" + first + ")"
  }

  /// Within about a kilometre: the same place, whichever list it came from.
  public static func nearPlace(_ aLat: Double?, _ aLon: Double?, _ bLat: Double?, _ bLon: Double?) -> Bool {
    guard let aLat, let aLon, let bLat, let bLon else { return false }
    return abs(aLat - bLat) < 0.01 && abs(aLon - bLon) < 0.01
  }

  /// Returns the same list when nothing changes. A second town with a name and
  /// zone already on the list is a different place when its coordinates say so,
  /// and is named with its region to tell the two apart.
  public static func addZone(_ zones: [City], id: String, label: String?, place: Place? = nil) -> [City] {
    let zoneId = id.trimmingCharacters(in: .whitespaces)
    if !isZoneID(zoneId) { return zones }
    var name = cleanLabel(label)
    if name.isEmpty { name = labelForZoneId(zoneId) }
    var row = withPlace(City(label: name, id: zoneId), place)
    let at = indexOfZone(zones, label: name, id: zoneId)
    if at >= 0 {
      if row.lat == nil || zones[at].lat == nil
        || nearPlace(zones[at].lat, zones[at].lon, row.lat, row.lon) { return zones }
      row.label = regionalName(name, row.region)
      if row.label == name || hasEntry(zones, id: zoneId, label: row.label) { return zones }
    }
    return zones + [row]
  }

  /// By position: with two rows on one zone, an id cannot say which was clicked. The last city stays.
  public static func removeZoneAt(_ zones: [City], _ index: Int) -> [City] {
    if zones.count <= 1 || index < 0 || index >= zones.count { return zones }
    var out = zones
    out.remove(at: index)
    return out
  }

  public static func removeZone(_ zones: [City], id: String) -> [City] {
    if zones.count <= 1 { return zones }
    let out = zones.filter { $0.id != id }
    return out.count == zones.count ? zones : out
  }

  public static func moveZone(_ zones: [City], from: Int, to: Int) -> [City] {
    let n = zones.count
    if from == to || from < 0 || from >= n || to < 0 || to >= n { return zones }
    var out = zones
    let row = out.remove(at: from)
    out.insert(row, at: to)
    return out
  }

  // ---- here

  /// Tapping a city on this machine's zone makes it "here", and the zone's own
  /// city clears the choice. The new name, "" to clear, or nil to leave it.
  public static func homeCityAfterTap(label: String, zoneId: String, homeOverride: String, localZone: String) -> String? {
    let name = label.trimmingCharacters(in: .whitespaces)
    if name.isEmpty || localZone.isEmpty || zoneId != localZone { return nil }
    let override = homeOverride.trimmingCharacters(in: .whitespaces)
    let zoneCity = labelForZoneId(localZone)
    if name == (override.isEmpty ? zoneCity : override) { return nil }
    return name == zoneCity ? "" : name
  }

  /// Where "here" is: the stored place while this machine is still on its zone,
  /// else the zone's own city. Nil until the machine's zone is known.
  public static func resolveHere(_ here: City?, localZone: String) -> Here? {
    if localZone.isEmpty { return nil }
    if let here, here.id == localZone {
      let name = cleanLabel(here.label)
      if !name.isEmpty {
        return Here(city: withPlace(City(label: name, id: localZone), Place(lat: here.lat, lon: here.lon, region: here.region)), chosen: true)
      }
    }
    return Here(city: City(label: labelForZoneId(localZone), id: localZone), chosen: false)
  }

  /// Picking `pick` as here. On this machine's zone the row that stood for the
  /// old here is renamed to the new one, keeping its place and its people. A
  /// city on another zone asks for the clock to move there and leaves the list alone.
  public static func hereAfterPick(_ zones: [City], current: City?, pick: City, localZone: String) -> HerePick? {
    let zone = pick.id
    if localZone.isEmpty || !isZoneID(zone) { return nil }
    let name = cleanLabel(pick.label)
    if name.isEmpty { return nil }
    let placed = withPlace(City(label: name, id: zone), Place(lat: pick.lat, lon: pick.lon, region: pick.region))
    let bare = name == labelForZoneId(zone) && placed.lat == nil
    let here: City? = bare ? nil : placed
    if zone != localZone { return HerePick(here: here, zones: zones, zoneChange: zone) }

    var out = zones
    let at = current.map { indexOfZone(zones, label: $0.label, id: zone) } ?? -1
    if at >= 0, let current, name == current.label || !hasEntry(zones, id: zone, label: name) {
      var row = placed
      row.people = zones[at].people
      out[at] = row
    }
    return HerePick(here: here, zones: out, zoneChange: "")
  }

  // ---- people

  static let maxPeople = 12

  /// GitHub's own rule for a username.
  public static func isGitHubHandle(_ text: String) -> Bool {
    guard let first = text.unicodeScalars.first, text.count <= 39 else { return false }
    let alnum: (Unicode.Scalar) -> Bool = { s in s.isASCII && CharacterSet.alphanumerics.contains(s) }
    return alnum(first) && text.unicodeScalars.allSatisfy { alnum($0) || $0 == "-" }
  }

  /// "Emir, @sarahdev" -> ["Emir", "@sarahdev"]: trimmed, without repeats, and a
  /// handle GitHub could not have is kept as a plain name.
  public static func parsePeople(_ text: String?) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    for part in (text ?? "").split(separator: ",", omittingEmptySubsequences: false) {
      if out.count >= maxPeople { break }
      var name = cleanLabel(String(part))
      if name.hasPrefix("@") {
        let handle = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
        name = isGitHubHandle(handle) ? "@" + handle : handle
      }
      if name.isEmpty || seen.contains(name.lowercased()) { continue }
      seen.insert(name.lowercased())
      out.append(name)
    }
    return out
  }

  public static func cleanPeople(_ list: [String]) -> [String] {
    parsePeople(list.map { $0.replacingOccurrences(of: ",", with: " ") }.joined(separator: ","))
  }

  public static func peopleText(_ list: [String]) -> String { list.joined(separator: ", ") }

  /// "@SarahDev" -> "sarahdev"; "" for a plain name.
  public static func personHandle(_ person: String) -> String {
    guard person.hasPrefix("@") else { return "" }
    let handle = String(person.dropFirst())
    return isGitHubHandle(handle) ? handle.lowercased() : ""
  }

  /// A handle reads as the profile's name once it is known, and as the bare handle before.
  public static func personName(_ person: String, profiles: [String: Profile]) -> String {
    let handle = personHandle(person)
    if handle.isEmpty { return person }
    if let profile = profiles[handle] {
      if !profile.name.isEmpty { return profile.name }
      if !profile.login.isEmpty { return profile.login }
    }
    return String(person.dropFirst())
  }

  /// The first letter, whole.
  public static func initialOf(_ name: String) -> String {
    guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "" }
    return String(first).uppercased()
  }

  /// Every handle on the list, once.
  public static func handlesIn(_ zones: [City]) -> [String] {
    var out: [String] = []
    for zone in zones {
      for person in zone.people {
        let handle = personHandle(person)
        if !handle.isEmpty && !out.contains(handle) { out.append(handle) }
      }
    }
    return out
  }

  /// The row at `index` with these people, or the same list when nothing changes.
  public static func setPeopleAt(_ zones: [City], _ index: Int, _ people: [String]) -> [City] {
    if index < 0 || index >= zones.count { return zones }
    let next = cleanPeople(people)
    if peopleText(next) == peopleText(zones[index].people) { return zones }
    var out = zones
    out[index].people = next
    return out
  }

  // ---- first run

  public struct SeedCandidate: Sendable {
    public let label: String
    public let id: String
    public let rank: Int
  }

  /// Home plus four well-known cities spread round the clock from it. Rank breaks ties.
  public static let seedCandidates: [SeedCandidate] = seedTable.map { SeedCandidate(label: $0.0, id: $0.1, rank: $0.2) }

  private static let seedTable: [(String, String, Int)] = [
    ("Honolulu", "Pacific/Honolulu", 3), ("Anchorage", "America/Anchorage", 3),
    ("Los Angeles", "America/Los_Angeles", 2), ("Vancouver", "America/Vancouver", 3),
    ("Mexico City", "America/Mexico_City", 3), ("Chicago", "America/Chicago", 3),
    ("New York", "America/New_York", 1), ("Sao Paulo", "America/Sao_Paulo", 2),
    ("Buenos Aires", "America/Argentina/Buenos_Aires", 3), ("Reykjavik", "Atlantic/Reykjavik", 3),
    ("London", "Europe/London", 1), ("Lisbon", "Europe/Lisbon", 3), ("Paris", "Europe/Paris", 1),
    ("Berlin", "Europe/Berlin", 3), ("Madrid", "Europe/Madrid", 3), ("Rome", "Europe/Rome", 3),
    ("Cairo", "Africa/Cairo", 3), ("Johannesburg", "Africa/Johannesburg", 3),
    ("Istanbul", "Europe/Istanbul", 3), ("Moscow", "Europe/Moscow", 3), ("Nairobi", "Africa/Nairobi", 3),
    ("Dubai", "Asia/Dubai", 2), ("Karachi", "Asia/Karachi", 3), ("Delhi", "Asia/Kolkata", 2),
    ("Bangkok", "Asia/Bangkok", 3), ("Jakarta", "Asia/Jakarta", 3), ("Singapore", "Asia/Singapore", 2),
    ("Hong Kong", "Asia/Hong_Kong", 2), ("Shanghai", "Asia/Shanghai", 2), ("Perth", "Australia/Perth", 3),
    ("Seoul", "Asia/Seoul", 3), ("Tokyo", "Asia/Tokyo", 1), ("Sydney", "Australia/Sydney", 2),
    ("Auckland", "Pacific/Auckland", 3)
  ]

  public static func seedCandidateZones() -> [String] { seedCandidates.map(\.id) }

  static let dayMinutes = 1440

  /// Minutes east of home, wrapped to one turn of the dial.
  static func eastOf(_ offset: Int, _ home: Int) -> Int {
    let d = (offset - home) % dayMinutes
    return d < 0 ? d + dayMinutes : d
  }

  static func dialDistance(_ a: Int, _ b: Int) -> Int {
    let d = abs(a - b) % dayMinutes
    return min(d, dayMinutes - d)
  }

  static func pickSeedAt(_ home: City, _ offsets: [String: Int], _ count: Int, _ gap: Int) -> [(label: String, id: String, east: Int)] {
    guard let homeOff = offsets[home.id] else { return [] }
    let homeLabel = home.label.lowercased()
    var picked: [(label: String, id: String, east: Int)] = []
    for rank in 1...3 {
      for c in seedCandidates where c.rank == rank && picked.count < count {
        guard let off = offsets[c.id] else { continue }
        if c.id == home.id || c.label.lowercased() == homeLabel { continue }
        let east = eastOf(off, homeOff)
        if min(east, dayMinutes - east) < gap { continue }
        if picked.contains(where: { dialDistance($0.east, east) < gap }) { continue }
        picked.append((c.label, c.id, east))
      }
    }
    return picked
  }

  /// `offsets` maps zone id to minutes east of UTC and must include home's.
  public static func pickSeedZones(home: City, offsets: [String: Int], count: Int = 4) -> [City] {
    if home.id.isEmpty || offsets[home.id] == nil { return [] }
    // Relax the gap where half the world sits within a couple of hours of home.
    var picked: [(label: String, id: String, east: Int)] = []
    for gap in [180, 120, 60] {
      picked = pickSeedAt(home, offsets, count, gap)
      if picked.count >= count { break }
    }
    return picked.sorted { $0.east < $1.east }.map { City(label: $0.label, id: $0.id) }
  }

  public static func seedZones(home: City, offsets: [String: Int], count: Int = 4) -> [City] {
    if home.id.isEmpty { return [] }
    return [City(label: home.label, id: home.id)] + pickSeedZones(home: home, offsets: offsets, count: count)
  }
}

/// A GitHub profile as cached on disk.
public struct Profile: Codable, Equatable, Sendable {
  public var login: String
  public var name: String
  /// A cached image path, "" when there is none.
  public var avatar: String

  public init(login: String, name: String, avatar: String) {
    self.login = login
    self.name = name
    self.avatar = avatar
  }
}
