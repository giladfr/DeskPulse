import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape.fill") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell.badge.fill") }
            WeatherSettings()
                .tabItem { Label("Weather", systemImage: "cloud.sun.fill") }
            StockSettings()
                .tabItem { Label("Stocks", systemImage: "chart.line.uptrend.xyaxis") }
            ClockSettings()
                .tabItem { Label("Clocks", systemImage: "clock.fill") }
            NewsSettings()
                .tabItem { Label("News", systemImage: "newspaper.fill") }
            RadioSettings()
                .tabItem { Label("Radio", systemImage: "radio.fill") }
        }
        .frame(width: 600, height: 500)
    }
}

private struct WeatherSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var results: [WeatherLocation] = []
    @State private var isSearching = false
    @State private var searched = false

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Showing", value: settings.weatherLocation.name)
                HStack {
                    TextField("Search for a city", text: $query)
                        .onSubmit(search)
                    Button("Search", action: search)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if searched && results.isEmpty {
                    Text("No places found.").foregroundStyle(.secondary)
                }
                ForEach(results, id: \.self) { location in
                    Button {
                        settings.weatherLocation = location
                        results = []
                        query = ""
                        searched = false
                    } label: {
                        HStack {
                            Text(location.name)
                            Spacer()
                            Text(location.timeZone).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Units") {
                Picker("Units", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            Text("Forecasts come from Open-Meteo; only the chosen city's coordinates are sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func search() {
        let query = query
        isSearching = true
        Task {
            results = await DataService.searchLocations(query)
            isSearching = false
            searched = true
        }
    }
}

private struct StockSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(settings.watchlist) { entry in
                        HStack {
                            Image(systemName: entry.symbol == settings.featuredSymbol ? "star.fill" : "star")
                                .foregroundStyle(entry.symbol == settings.featuredSymbol ? .yellow : .secondary)
                                .onTapGesture { settings.featuredSymbol = entry.symbol }
                                .help("Show this symbol large, with its chart")
                            Text(entry.symbol).font(.body.monospaced().weight(.semibold))
                            if let assetClass = entry.assetClass, assetClass != "stocks" {
                                Text(assetClass.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                settings.removeSymbol(entry.symbol)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .disabled(settings.watchlist.count <= 1)
                            .help("Remove from watchlist")
                        }
                    }
                    .onMove { settings.watchlist.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 180)
            } header: {
                Text("Watchlist")
            } footer: {
                Text("Drag to reorder. The starred symbol is shown large with its intraday chart; click a chip on the card to switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Add a symbol") {
                AddSymbolForm()
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClockSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var newZone = TimeZone.current.identifier

    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        Form {
            Section {
                List {
                    ForEach($settings.clocks) { $clock in
                        HStack {
                            TextField("Flag", text: $clock.flag)
                                .frame(width: 44)
                            TextField("Name", text: $clock.name)
                            Picker("Time zone", selection: $clock.timeZone) {
                                ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                            Button {
                                settings.clocks.removeAll { $0.id == clock.id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .disabled(settings.clocks.count <= 1)
                        }
                    }
                    .onMove { settings.clocks.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 170)
            } header: {
                Text("World clocks")
            } footer: {
                Text("Drag to reorder. Flags are any emoji.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Add a clock") {
                HStack {
                    Picker("Time zone", selection: $newZone) {
                        ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Add") {
                        let city = newZone.split(separator: "/").last.map {
                            $0.replacingOccurrences(of: "_", with: " ")
                        } ?? newZone
                        settings.clocks.append(WorldClock(name: city, timeZone: newZone, flag: ""))
                    }
                    .disabled(settings.clocks.count >= 8)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct NewsSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var topic = ""
    @State private var customName = ""
    @State private var customURL = ""

    var body: some View {
        Form {
            Section {
                List {
                    ForEach($settings.newsSources) { $source in
                        HStack {
                            Toggle(isOn: $source.isEnabled) { EmptyView() }
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.name)
                                Text(source.url.host() ?? source.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                settings.newsSources.removeAll { $0.id == source.id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onMove { settings.newsSources.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 140)
            } header: {
                Text("“My news” sources")
            } footer: {
                Text("Shown together, newest first, on the My news card (add it from the dashboard's top bar).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Add") {
                Menu("Popular sources") {
                    ForEach(NewsSource.catalog, id: \.group) { group in
                        Section(group.group) {
                            ForEach(group.sources) { source in
                                Button(source.name) { settings.addNewsSource(source) }
                                    .disabled(settings.newsSources.contains { $0.url == source.url })
                            }
                        }
                    }
                }
                HStack {
                    TextField("Google News topic, e.g. semiconductors", text: $topic)
                        .onSubmit(addTopic)
                    Button("Add topic", action: addTopic)
                        .disabled(NewsSource.googleNews(topic: topic) == nil)
                }
                HStack {
                    TextField("Name", text: $customName).frame(width: 120)
                    TextField("RSS or Atom feed URL", text: $customURL)
                        .onSubmit(addCustom)
                    Button("Add feed", action: addCustom)
                        .disabled(customFeed == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var customFeed: NewsSource? {
        guard let url = URL(string: customURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
              url.host() != nil
        else { return nil }
        let name = customName.trimmingCharacters(in: .whitespaces)
        return NewsSource(name: name.isEmpty ? (url.host() ?? "Feed") : name, url: url)
    }

    private func addTopic() {
        guard let source = NewsSource.googleNews(topic: topic) else { return }
        settings.addNewsSource(source)
        topic = ""
    }

    private func addCustom() {
        guard let source = customFeed else { return }
        settings.addNewsSource(source)
        customName = ""
        customURL = ""
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Refresh news and weather every", selection: $settings.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                        Text(minutes == 1 ? "minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
                Text("Stocks update on their own schedule, every 10–60 seconds. Hidden cards are never fetched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Top bar") {
                ForEach(WidgetKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { !settings.hiddenFromTopBar.contains(kind) },
                        set: { shown in
                            if shown {
                                settings.hiddenFromTopBar.remove(kind)
                            } else {
                                settings.hiddenFromTopBar.insert(kind)
                            }
                        }
                    )) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
                Text("Turn off cards you never use to keep their buttons out of the top bar. A card that is open stays open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dashboard: DashboardModel
    @State private var newArea = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { RedAlertStatusView(monitor: dashboard.redAlert, enabled: dashboard.incomingAlertDetectionEnabled) }
                Toggle("Detect incoming alerts", isOn: Binding(
                    get: { dashboard.incomingAlertDetectionEnabled },
                    set: { if $0 != dashboard.incomingAlertDetectionEnabled { dashboard.toggleIncomingAlertDetection() } }
                ))
                Toggle("Show a macOS notification", isOn: $settings.notifiesIncomingAlerts)
                Button("Send a test alert") { dashboard.sendTestAlert() }
                    .help("Shows the notification and the HDMI screen banner without switching layouts")
            } header: {
                Text("Red Alert (Home Front Command)")
            } footer: {
                Text("Alerts arrive live from the Red Alert service (tzevaadom.co.il). A real alert also switches the dashboard to the situation layout. Drills are ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(settings.alertAreas, id: \.self) { area in
                    HStack {
                        Text(area)
                        Spacer()
                        Button {
                            settings.alertAreas.removeAll { $0 == area }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Area in Hebrew, e.g. תל אביב", text: $newArea)
                        .onSubmit(addArea)
                    Button("Add", action: addArea)
                        .disabled(newArea.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Areas")
            } footer: {
                Text(settings.alertAreas.isEmpty
                     ? "Alerts anywhere in Israel count. Add areas to only react to those (an alert matches if any of its areas contains one of these)."
                     : "Only alerts for these areas count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Price alerts") {
                if settings.priceAlerts.isEmpty {
                    Text("None yet. Right-click a symbol on the stock card and choose “Add price alert…”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.priceAlerts) { alert in
                    HStack {
                        Image(systemName: "bell.fill").foregroundStyle(.yellow)
                        Text(alert.summary)
                        Spacer()
                        Button {
                            settings.priceAlerts.removeAll { $0.id == alert.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addArea() {
        let area = newArea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !area.isEmpty, !settings.alertAreas.contains(area) else { return }
        settings.alertAreas.append(area)
        newArea = ""
    }
}

private struct RedAlertStatusView: View {
    @ObservedObject var monitor: RedAlertMonitor
    let enabled: Bool

    var body: some View {
        switch monitor.status {
        case .connected:
            Label("Connected", systemImage: "circle.fill").foregroundStyle(.green)
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.orange)
        case .disconnected(let reason):
            Label("Reconnecting — \(reason)", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .off:
            Label(enabled ? "Starting…" : "Off", systemImage: "circle").foregroundStyle(.secondary)
        }
    }
}

private struct RadioSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var name = ""
    @State private var address = ""

    var body: some View {
        Form {
            Section("Stations") {
                ForEach(RadioStation.all) { station in
                    Toggle(isOn: Binding(
                        get: { !settings.hiddenRadioStations.contains(station.id) },
                        set: { shown in
                            if shown {
                                settings.hiddenRadioStations.remove(station.id)
                            } else {
                                settings.hiddenRadioStations.insert(station.id)
                            }
                        }
                    )) {
                        Text("\(station.frequency)  \(station.name)")
                    }
                }
                ForEach(settings.customRadioStations) { station in
                    HStack {
                        Text("★  \(station.name)")
                        Text(station.streamURL.host() ?? "").foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            settings.customRadioStations.removeAll { $0.id == station.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Add a stream") {
                HStack {
                    TextField("Name", text: $name).frame(width: 130)
                    TextField("Stream URL (MP3, AAC or HLS)", text: $address)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(stream == nil)
                }
            }
            Section {
                Toggle("Recognize songs", isOn: $settings.recognizesSongs)
            } footer: {
                Text("Names the song when a station doesn't: sends 10 seconds of the playing station to Shazam every 90 seconds. Needs ffmpeg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var stream: CustomRadioStation? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
              url.host() != nil
        else { return nil }
        return CustomRadioStation(name: name, streamURL: url)
    }

    private func add() {
        guard let stream else { return }
        settings.customRadioStations.append(stream)
        name = ""
        address = ""
    }
}
