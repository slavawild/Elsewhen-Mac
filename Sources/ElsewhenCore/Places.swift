import Foundation

/// One line of a city search: a zone's city, an alias, or a place from the geocoder.
public struct ZoneOption: Equatable, Hashable, Sendable, Identifiable {
  public var value: String
  public var label: String
  public var lat: Double?
  public var lon: Double?
  public var region: String?

  public init(value: String, label: String, lat: Double? = nil, lon: Double? = nil, region: String? = nil) {
    self.value = value
    self.label = label
    self.lat = lat
    self.lon = lon
    self.region = region
  }

  public var id: String { label + "\u{0}" + (region ?? "") + "\u{0}" + value }
  public var place: Place? { lat == nil ? nil : Place(lat: lat, lon: lon, region: region ?? "") }
}

/// A city on the globe.
public struct GlobeCity: Equatable, Sendable {
  public var name: String
  public var zone: String
  public var lat: Double
  public var lon: Double
  public var rank: Int

  public init(name: String, zone: String, lat: Double, lon: Double, rank: Int) {
    self.name = name
    self.zone = zone
    self.lat = lat
    self.lon = lon
    self.rank = rank
  }

  public var key: String { Model.factsKey(label: name, id: zone) }
}

extension Model {
  /// Places people think of that the tz database files under another city's zone.
  public static let cityAliases: [(label: String, id: String)] = aliasTable

  private static let aliasTable: [(label: String, id: String)] = [
    // US Eastern
    ("Miami", "America/New_York"), ("Boca Raton", "America/New_York"), ("Boston", "America/New_York"),
    ("Philadelphia", "America/New_York"), ("Washington DC", "America/New_York"), ("Atlanta", "America/New_York"),
    ("Orlando", "America/New_York"), ("Tampa", "America/New_York"), ("Charlotte", "America/New_York"),
    ("Pittsburgh", "America/New_York"), ("Cleveland", "America/New_York"),
    // US Central
    ("Chicago", "America/Chicago"), ("Austin", "America/Chicago"), ("Dallas", "America/Chicago"),
    ("Houston", "America/Chicago"), ("San Antonio", "America/Chicago"), ("Nashville", "America/Chicago"),
    ("New Orleans", "America/Chicago"), ("Minneapolis", "America/Chicago"), ("Kansas City", "America/Chicago"),
    ("St. Louis", "America/Chicago"), ("Memphis", "America/Chicago"),
    // US Mountain
    ("Salt Lake City", "America/Denver"), ("Albuquerque", "America/Denver"),
    ("Colorado Springs", "America/Denver"), ("Boulder", "America/Denver"),
    // Arizona does not observe DST, so it is its own zone.
    ("Tucson", "America/Phoenix"), ("Scottsdale", "America/Phoenix"),
    // US Pacific
    ("San Francisco", "America/Los_Angeles"), ("San Diego", "America/Los_Angeles"),
    ("San Jose", "America/Los_Angeles"), ("Oakland", "America/Los_Angeles"),
    ("Sacramento", "America/Los_Angeles"), ("Seattle", "America/Los_Angeles"),
    ("Portland", "America/Los_Angeles"), ("Las Vegas", "America/Los_Angeles"),
    // Canada
    ("Montreal", "America/Toronto"), ("Ottawa", "America/Toronto"), ("Calgary", "America/Edmonton"),
    ("Victoria", "America/Vancouver"),
    // Latin America
    ("Rio de Janeiro", "America/Sao_Paulo"), ("Brasilia", "America/Sao_Paulo"), ("Guadalajara", "America/Mexico_City"),
    // UK and Ireland
    ("Manchester", "Europe/London"), ("Edinburgh", "Europe/London"), ("Glasgow", "Europe/London"),
    ("Birmingham", "Europe/London"), ("Cambridge", "Europe/London"), ("Oxford", "Europe/London"),
    // Continental Europe
    ("Munich", "Europe/Berlin"), ("Frankfurt", "Europe/Berlin"), ("Hamburg", "Europe/Berlin"),
    ("Cologne", "Europe/Berlin"), ("Lyon", "Europe/Paris"), ("Marseille", "Europe/Paris"), ("Nice", "Europe/Paris"),
    ("Barcelona", "Europe/Madrid"), ("Valencia", "Europe/Madrid"), ("Seville", "Europe/Madrid"),
    ("Milan", "Europe/Rome"), ("Naples", "Europe/Rome"), ("Florence", "Europe/Rome"), ("Venice", "Europe/Rome"),
    ("Turin", "Europe/Rome"), ("Rotterdam", "Europe/Amsterdam"), ("Geneva", "Europe/Zurich"),
    ("Basel", "Europe/Zurich"), ("Gothenburg", "Europe/Stockholm"), ("Porto", "Europe/Lisbon"),
    ("Krakow", "Europe/Warsaw"), ("St Petersburg", "Europe/Moscow"),
    // Asia
    ("Beijing", "Asia/Shanghai"), ("Shenzhen", "Asia/Shanghai"), ("Guangzhou", "Asia/Shanghai"),
    ("Osaka", "Asia/Tokyo"), ("Kyoto", "Asia/Tokyo"), ("Yokohama", "Asia/Tokyo"), ("Nagoya", "Asia/Tokyo"),
    ("Busan", "Asia/Seoul"), ("Mumbai", "Asia/Kolkata"), ("Delhi", "Asia/Kolkata"), ("New Delhi", "Asia/Kolkata"),
    ("Bangalore", "Asia/Kolkata"), ("Bengaluru", "Asia/Kolkata"), ("Chennai", "Asia/Kolkata"),
    ("Hyderabad", "Asia/Kolkata"), ("Pune", "Asia/Kolkata"), ("Abu Dhabi", "Asia/Dubai"),
    ("Tel Aviv", "Asia/Jerusalem"),
    // Oceania and Africa
    ("Canberra", "Australia/Sydney"), ("Cape Town", "Africa/Johannesburg"), ("Durban", "Africa/Johannesburg"),
    ("Alexandria", "Africa/Cairo")
  ]

  /// The zone catalogue plus the aliases -> picker options, minus `existing`, sorted by name.
  public static func zoneOptions(_ ids: [String], existing: [City]) -> [ZoneOption] {
    var seen = Set<String>()
    var out: [ZoneOption] = []
    func offer(_ id: String, _ label: String) {
      let key = label + "\u{0}" + id
      if seen.contains(key) || hasEntry(existing, id: id, label: label) { return }
      seen.insert(key)
      out.append(ZoneOption(value: id, label: label))
    }
    for raw in ids {
      let id = raw.trimmingCharacters(in: .whitespaces)
      if id.isEmpty || !id.contains("/") { continue }
      offer(id, labelForZoneId(id))
    }
    for alias in cityAliases { offer(alias.id, alias.label) }
    return out.sorted { $0.label < $1.label }
  }

  /// Matches city name or IANA id; city-name prefixes sort first.
  public static func searchZones(_ options: [ZoneOption], query: String, limit: Int = 6) -> [ZoneOption] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    var starts: [ZoneOption] = []
    var contains: [ZoneOption] = []
    for o in options {
      let label = o.label.lowercased()
      if q.isEmpty {
        starts.append(o)
        if starts.count >= limit { break }
      } else if label.hasPrefix(q) {
        starts.append(o)
      } else if label.contains(q) || o.value.lowercased().contains(q) {
        contains.append(o)
      }
    }
    return Array((starts + contains).prefix(limit))
  }

  /// Keyboard selection in a result list, wrapping at both ends.
  public static func moveSelection(_ index: Int, _ delta: Int, _ count: Int) -> Int {
    if count == 0 { return 0 }
    return (((index + delta) % count) + count) % count
  }

  // ---- place search

  public static let placeQueryMin = 3
  public static let geocodeCount = 10

  /// The query a place search runs for, or "" when it is too short to be worth one.
  public static func placeQuery(_ text: String) -> String {
    let q = collapseSpaces(text)
    return q.count >= placeQueryMin ? q.lowercased() : ""
  }

  public static func geocodeURL(_ name: String) -> URL? {
    var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
    c?.queryItems = [
      URLQueryItem(name: "count", value: String(geocodeCount)),
      URLQueryItem(name: "language", value: "en"),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "name", value: name)
    ]
    return c?.url
  }

  /// One geocoder result, read defensively: the answer comes off the network.
  public struct GeocodeResult: Sendable {
    public var name: String
    public var latitude: Double?
    public var longitude: Double?
    public var timezone: String
    public var admin1: String
    public var countryCode: String
    public var country: String
  }

  /// The geocoder's results, nil when the answer is not one, and at most `geocodeCount` of them.
  public static func geocodeResults(_ data: Data) -> [GeocodeResult]? {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let results = payload["results"] as? [Any] else { return [] }
    return results.prefix(geocodeCount).compactMap { item in
      guard let r = item as? [String: Any] else { return nil }
      return GeocodeResult(
        name: r["name"] as? String ?? "",
        latitude: (r["latitude"] as? NSNumber)?.doubleValue,
        longitude: (r["longitude"] as? NSNumber)?.doubleValue,
        timezone: r["timezone"] as? String ?? "",
        admin1: r["admin1"] as? String ?? "",
        countryCode: r["country_code"] as? String ?? "",
        country: r["country"] as? String ?? ""
      )
    }
  }

  /// "Florida, US": what tells Portland, Oregon from Portland, Maine.
  public static func placeRegion(_ r: GeocodeResult) -> String {
    var parts: [String] = []
    let admin = cleanLabel(r.admin1)
    if !admin.isEmpty && admin != cleanLabel(r.name) { parts.append(admin) }
    let country = cleanLabel(r.countryCode.isEmpty ? r.country : r.countryCode)
    if !country.isEmpty { parts.append(country.count == 2 ? country.uppercased() : country) }
    return parts.joined(separator: ", ")
  }

  /// Geocoder answer -> picker options carrying the place, [] when it failed.
  public static func placeOptions(_ data: Data) -> [ZoneOption] {
    guard let results = geocodeResults(data) else { return [] }
    var out: [ZoneOption] = []
    var seen = Set<String>()
    for r in results {
      let name = cleanLabel(r.name)
      if name.isEmpty || !isZoneID(r.timezone) || !r.timezone.contains("/") { continue }
      let placed = withPlace(City(label: name, id: r.timezone), Place(lat: r.latitude, lon: r.longitude, region: placeRegion(r)))
      guard placed.lat != nil else { continue }
      let option = ZoneOption(value: r.timezone, label: name, lat: placed.lat, lon: placed.lon, region: placed.region)
      if seen.contains(option.id) { continue }
      seen.insert(option.id)
      out.append(option)
    }
    return out
  }

  /// The offline matches first, so three letters and Return still pick what they
  /// did; then the geocoder's places. A place whose name and zone match an
  /// offline city lends it a region and coordinates rather than being listed
  /// twice; another town of that name and zone is a place of its own. A place
  /// already on the list is left out.
  public static func mergePlaces(_ offline: [ZoneOption], _ places: [ZoneOption], existing: [City], limit: Int? = nil) -> [ZoneOption] {
    var out = offline
    let offlineCount = out.count
    for p in places {
      let tracked = existing.contains { row in
        row.id == p.value && (nearPlace(row.lat, row.lon, p.lat, p.lon)
          || (row.lat == nil && row.label.lowercased() == p.label.lowercased()))
      }
      if tracked { continue }
      let twin = out.prefix(offlineCount).firstIndex { $0.value == p.value && $0.label.lowercased() == p.label.lowercased() }
      if let twin, out[twin].lat == nil {
        out[twin].lat = p.lat
        out[twin].lon = p.lon
        out[twin].region = p.region
      } else if twin == nil || !nearPlace(out[twin!].lat, out[twin!].lon, p.lat, p.lon) {
        out.append(p)
      }
    }
    if let limit { return Array(out.prefix(limit)) }
    return out
  }

  /// Globe cities: home first, then the rest, first name wins.
  public static func mergeCities(home: GlobeCity?, builtIn: [GlobeCity], tracked: [GlobeCity], session: [GlobeCity]) -> [GlobeCity] {
    var out: [GlobeCity] = []
    var seen = Set<String>()
    func add(_ city: GlobeCity) {
      let key = city.name.lowercased()
      if seen.contains(key) { return }
      seen.insert(key)
      out.append(city)
    }
    if let home { add(home) }
    builtIn.forEach(add)
    tracked.forEach(add)
    session.forEach(add)
    return out
  }

  /// { place, answered }: a place in the row's own zone beats the top result,
  /// and `answered` is false when the request itself failed.
  public static func pickGeocode(_ data: Data?, zone: String) -> (place: Place?, answered: Bool) {
    guard let data, let results = geocodeResults(data) else { return (nil, false) }
    let best = results.first { $0.timezone == zone } ?? results.first
    guard let best, let lat = best.latitude, let lon = best.longitude else { return (nil, true) }
    return (Place(lat: lat, lon: lon), true)
  }

  /// The zone's representative city from zone1970.tab or zone.tab (ISO 6709), the offline fallback.
  public static func zoneTabCoords(_ tab: String, zone: String) -> Place? {
    for line in tab.split(separator: "\n") {
      if line.hasPrefix("#") { continue }
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      if parts.count < 3 || parts[2] != zone { continue }
      return parseISO6709(parts[1])
    }
    return nil
  }

  static func parseISO6709(_ text: String) -> Place? {
    // ±DDMM[SS]±DDDMM[SS]
    let chars = Array(text)
    guard let split = chars.indices.dropFirst().first(where: { chars[$0] == "+" || chars[$0] == "-" }) else { return nil }
    let latPart = String(chars[0..<split]), lonPart = String(chars[split...])
    func dec(_ s: String, degreeDigits: Int) -> Double? {
      guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
      let digits = s.dropFirst()
      guard digits.allSatisfy(\.isNumber), digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4 else { return nil }
      let a = Array(digits)
      let d = Double(String(a[0..<degreeDigits]))!
      let m = Double(String(a[degreeDigits..<degreeDigits + 2]))!
      let sec = a.count > degreeDigits + 2 ? Double(String(a[(degreeDigits + 2)...]))! : 0
      let value = (d + m / 60 + sec / 3600) * (sign == "-" ? -1 : 1)
      return (value * 1e4).rounded() / 1e4
    }
    guard let lat = dec(latPart, degreeDigits: 2), let lon = dec(lonPart, degreeDigits: 3) else { return nil }
    return Place(lat: lat, lon: lon)
  }
}
