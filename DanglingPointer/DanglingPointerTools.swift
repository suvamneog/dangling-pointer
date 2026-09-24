//
//  DanglingPointerTools.swift
//  DanglingPointer
//
//  Tools the model can call, Friday-style. All free and keyless:
//  web search (DuckDuckGo), weather (Open-Meteo), news (Google News RSS),
//  reading a web page, battery (IOKit), and looking at the screen.
//  Results are trimmed hard so they cost few tokens.
//

import Foundation
import IOKit.ps

@MainActor
final class DanglingPointerTools {
    /// Captures the screen for `look_at_screen`. Returns JPEG data + label.
    private let captureScreen: () async throws -> (data: Data, label: String)

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: configuration)
    }()

    /// Upper bound on any tool result sent back to the model.
    private static let maxResultCharacters = 1500

    init(captureScreen: @escaping () async throws -> (data: Data, label: String)) {
        self.captureScreen = captureScreen
    }

    // MARK: - Definitions

    /// Tool schemas sent with each request. Descriptions are kept short — they cost tokens every call.
    static func definitions(includeLookAtScreen: Bool) -> [[String: Any]] {
        var definitions: [[String: Any]] = [
            function("search_web", "Search the web for current or factual info you don't know.",
                     ["query": "search query"], required: ["query"]),
            function("get_weather", "Current weather and today's forecast for a city.",
                     ["city": "city name, e.g. Guwahati"], required: ["city"]),
            function("get_news", "Latest news headlines, optionally about a topic.",
                     ["topic": "optional topic; omit for top headlines"], required: []),
            function("read_webpage", "Read the main text of a web page.",
                     ["url": "full https url"], required: ["url"]),
            function("get_battery", "Mac battery level and charging state.", [:], required: []),
        ]
        if includeLookAtScreen {
            definitions.append(function(
                "look_at_screen",
                "See the user's screen. Use when the request depends on what's on screen.",
                [:], required: []
            ))
        }
        return definitions
    }

    private static func function(
        _ name: String,
        _ description: String,
        _ stringParameters: [String: String],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": stringParameters.mapValues { ["type": "string", "description": $0] },
                    "required": required
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    // MARK: - Dispatch

    func run(_ toolCall: XkiroToolCall) async -> XkiroToolResult {
        let arguments = toolCall.arguments
        let stringArgument = { (key: String) in
            (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        do {
            switch toolCall.name {
            case "search_web":
                return XkiroToolResult(text: try await searchWeb(query: stringArgument("query")))
            case "get_weather":
                return XkiroToolResult(text: try await weather(city: stringArgument("city")))
            case "get_news":
                return XkiroToolResult(text: try await news(topic: stringArgument("topic")))
            case "read_webpage":
                return XkiroToolResult(text: try await readWebpage(urlString: stringArgument("url")))
            case "get_battery":
                return XkiroToolResult(text: batteryStatus())
            case "look_at_screen":
                let screenshot = try await captureScreen()
                return XkiroToolResult(text: "screenshot attached below.", imageData: screenshot.data, imageLabel: screenshot.label)
            default:
                return XkiroToolResult(text: "unknown tool \(toolCall.name)")
            }
        } catch {
            print("⚠️ Tool \(toolCall.name) failed: \(error.localizedDescription)")
            return XkiroToolResult(text: "tool failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Web Search (DuckDuckGo HTML, no key)

    private func searchWeb(query: String) async throws -> String {
        guard !query.isEmpty else { return "empty query" }
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let html = try await fetchText(components.url!)

        let titles = Self.matches(of: #"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#, in: html)
        let snippets = Self.matches(of: #"class="result__snippet"[^>]*>(.*?)</a>"#, in: html)

        var lines: [String] = []
        for (resultIndex, titleMatch) in titles.prefix(5).enumerated() {
            let title = Self.plainText(fromHTML: titleMatch[2])
            let snippet = resultIndex < snippets.count ? Self.plainText(fromHTML: snippets[resultIndex][1]) : ""
            let domain = Self.resultDomain(fromDuckDuckGoLink: titleMatch[1])
            lines.append("- \(title) (\(domain)): \(snippet)")
        }
        return lines.isEmpty ? "no results" : Self.trimmed(lines.joined(separator: "\n"))
    }

    /// DuckDuckGo wraps links as //duckduckgo.com/l/?uddg=<encoded url>.
    private static func resultDomain(fromDuckDuckGoLink link: String) -> String {
        let decodedLink = link.replacingOccurrences(of: "&amp;", with: "&")
        let components = URLComponents(string: decodedLink.hasPrefix("//") ? "https:" + decodedLink : decodedLink)
        let targetURLString = components?.queryItems?.first(where: { $0.name == "uddg" })?.value ?? decodedLink
        return URL(string: targetURLString)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
    }

    // MARK: - Weather (Open-Meteo, no key)

    private func weather(city: String) async throws -> String {
        guard !city.isEmpty else { return "no city given — ask the user which city" }
        var geocodingComponents = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geocodingComponents.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        let geocoding = try await fetchJSON(geocodingComponents.url!)
        guard let place = (geocoding["results"] as? [[String: Any]])?.first,
              let latitude = place["latitude"] as? Double,
              let longitude = place["longitude"] as? Double else {
            return "couldn't find a place called \(city)"
        }

        var forecastComponents = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecastComponents.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let forecast = try await fetchJSON(forecastComponents.url!)
        let current = forecast["current"] as? [String: Any] ?? [:]
        let daily = forecast["daily"] as? [String: Any] ?? [:]
        let firstDailyValue = { (key: String) in ((daily[key] as? [Any])?.first as? NSNumber)?.intValue }

        let placeName = [place["name"] as? String, place["country"] as? String].compactMap { $0 }.joined(separator: ", ")
        let condition = Self.weatherDescription(forCode: (current["weather_code"] as? NSNumber)?.intValue ?? -1)
        return """
        \(placeName): \(condition), \((current["temperature_2m"] as? NSNumber)?.intValue ?? 0)°C \
        (feels \((current["apparent_temperature"] as? NSNumber)?.intValue ?? 0)°C), \
        humidity \((current["relative_humidity_2m"] as? NSNumber)?.intValue ?? 0)%, \
        wind \((current["wind_speed_10m"] as? NSNumber)?.intValue ?? 0) km/h. \
        today high \(firstDailyValue("temperature_2m_max") ?? 0)°C, low \(firstDailyValue("temperature_2m_min") ?? 0)°C, \
        rain chance \(firstDailyValue("precipitation_probability_max") ?? 0)%.
        """
    }

    private static func weatherDescription(forCode code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51...57: return "drizzle"
        case 61...67: return "rain"
        case 71...77: return "snow"
        case 80...82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95...99: return "thunderstorm"
        default: return "unknown conditions"
        }
    }

    // MARK: - News (Google News RSS, no key)

    private func news(topic: String) async throws -> String {
        let regionCode = Locale.current.region?.identifier ?? "US"
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        let localeQueryItems = [
            URLQueryItem(name: "hl", value: "\(languageCode)-\(regionCode)"),
            URLQueryItem(name: "gl", value: regionCode),
            URLQueryItem(name: "ceid", value: "\(regionCode):\(languageCode)"),
        ]
        var components = URLComponents(string: topic.isEmpty
            ? "https://news.google.com/rss"
            : "https://news.google.com/rss/search")!
        components.queryItems = (topic.isEmpty ? [] : [URLQueryItem(name: "q", value: topic)]) + localeQueryItems

        let rss = try await fetchText(components.url!)
        let headlines = Self.matches(of: #"<item>.*?<title>(.*?)</title>"#, in: rss)
            .prefix(6)
            .map { "- " + Self.plainText(fromHTML: $0[1]) }
        return headlines.isEmpty ? "no headlines found" : Self.trimmed(headlines.joined(separator: "\n"))
    }

    // MARK: - Read Web Page

    private func readWebpage(urlString: String) async throws -> String {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "only http(s) urls can be read"
        }
        var html = try await fetchText(url)
        // Drop scripts, styles and page chrome before stripping tags.
        html = html.replacingOccurrences(
            of: #"(?is)<(script|style|noscript|svg|nav|header|footer)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        return Self.trimmed(Self.plainText(fromHTML: html), limit: 2500)
    }

    // MARK: - Battery (IOKit)

    private func batteryStatus() -> String {
        guard let powerSourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSources = IOPSCopyPowerSourcesList(powerSourcesInfo)?.takeRetainedValue() as? [CFTypeRef] else {
            return "battery info unavailable"
        }
        for powerSource in powerSources {
            guard let description = IOPSGetPowerSourceDescription(powerSourcesInfo, powerSource)?
                    .takeUnretainedValue() as? [String: Any],
                  let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0 else { continue }
            let percentage = currentCapacity * 100 / maxCapacity
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isPluggedIn = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutesToEmpty = description[kIOPSTimeToEmptyKey] as? Int ?? -1
            var status = "battery \(percentage)%, " + (isCharging ? "charging" : isPluggedIn ? "plugged in" : "on battery")
            if !isPluggedIn && minutesToEmpty > 0 {
                status += ", about \(minutesToEmpty / 60)h \(minutesToEmpty % 60)m left"
            }
            return status
        }
        return "no battery (desktop mac)"
    }

    // MARK: - Helpers

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "DanglingPointerTools", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode) from \(url.host ?? "server")"])
        }
        // Only the first ~400KB matters; avoids chewing through huge pages.
        return String(decoding: data.prefix(400_000), as: UTF8.self)
    }

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        let (data, _) = try await session.data(from: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// All matches of `pattern` (dot matches newlines); each is [whole, group1, group2, …].
    private static func matches(of pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { groupIndex in
                Range(match.range(at: groupIndex), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'",
                        "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#8217;": "'", "&#8220;": "\"", "&#8221;": "\""]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmed(_ text: String, limit: Int = maxResultCharacters) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
