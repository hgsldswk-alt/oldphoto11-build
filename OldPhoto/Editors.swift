import AVFoundation
import MapKit
import PhotosUI
import SwiftUI

struct CropEditor: View {
    let item: Scan
    let archive: Archive
    let edited: (UUID) -> Void
    @EnvironmentObject private var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var corners: Corners
    @State private var captured: UIImage?
    @State private var drag: CGPoint?
    @State private var adding = false
    @State private var applied = false

    init(item: Scan, archive: Archive, edited: @escaping (UUID) -> Void) {
        self.item = item
        self.archive = archive
        self.edited = edited
        _corners = State(initialValue: item.corners)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(L.t("crop_hint")).font(.subheadline).foregroundStyle(Paper.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                GeometryReader { proxy in
                    if let captured {
                        let bounds = aspectFit(captured.size.width / captured.size.height, in: proxy.size)
                        ZStack(alignment: .topLeading) {
                            Color.black
                            Image(uiImage: captured).resizable().frame(width: bounds.width, height: bounds.height)
                                .position(x: bounds.midX, y: bounds.midY)
                            CornerOverlay(boxes: [corners], rect: bounds)
                            ForEach(0..<4) { index in
                                let point = corners.points[index]
                                Circle().fill(Paper.marker).frame(width: 15, height: 15)
                                    .overlay { Circle().stroke(.black, lineWidth: 1.5) }
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                                    .position(x: bounds.minX + point.x * bounds.width,
                                              y: bounds.minY + point.y * bounds.height)
                                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("crop-plane"))
                                        .onChanged { value in
                                            drag = value.location
                                            corners = corners.moving(index, to: CGPoint(x: (value.location.x - bounds.minX) / bounds.width,
                                                                                       y: (value.location.y - bounds.minY) / bounds.height))
                                        }
                                        .onEnded { _ in drag = nil })
                                    .accessibilityLabel(L.f("corner_number", String(index + 1)))
                            }
                            if let drag {
                                Image(uiImage: captured).resizable()
                                    .frame(width: bounds.width * 2, height: bounds.height * 2)
                                    .offset(x: bounds.midX - drag.x, y: bounds.midY - drag.y)
                                    .frame(width: 78, height: 78).clipShape(Circle())
                                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                                    .position(x: min(max(42, drag.x), proxy.size.width - 42),
                                              y: drag.y > 105 ? drag.y - 60 : drag.y + 60)
                                    .allowsHitTesting(false)
                            }
                        }.coordinateSpace(name: "crop-plane")
                    } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .accessibilityIdentifier("crop-plane")
                Button(L.t(adding ? "reset_frame" : "add_frame"), systemImage: adding ? "arrow.uturn.backward" : "plus") {
                    adding.toggle()
                    corners = adding ? .centered : item.corners
                }.buttonStyle(.bordered).padding(.bottom, 12)
            }
            .foregroundStyle(Paper.ink).background(Paper.background.ignoresSafeArea())
            .navigationTitle(L.t("edit_frame")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("done")) { persist(); dismiss() }.accessibilityIdentifier("crop-done")
                }
            }
        }
        .task {
            let file = archive.page(item.pageID)
            captured = await Task.detached { ArchiveImage.read(file, limit: 1536) }.value
        }
        .onDisappear { persist() }
    }

    private func persist() {
        guard !applied, captured != nil, adding || corners != item.corners else { return }
        applied = true
        let value = corners
        let create = adding
        Task {
            if create { await model.addFrame(from: item.id, corners: value) }
            else if let id = await model.recrop(item.id, corners: value) { edited(id) }
        }
    }
}

struct DateEditor: View {
    var initial: PhotoDate?
    let save: (PhotoDate?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var precision: PhotoDate.Precision
    @State private var query = ""
    @State private var date: Date

    init(initial: PhotoDate?, save: @escaping (PhotoDate?) -> Void) {
        self.initial = initial
        self.save = save
        _precision = State(initialValue: initial?.precision ?? .year)
        _date = State(initialValue: initial?.date ?? PhotoDate(year: 1987).date ?? Date())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker(L.t("date_precision"), selection: $precision) {
                    ForEach(PhotoDate.Precision.allCases, id: \.self) { mode in
                        Text(L.t("precision_" + mode.rawValue)).tag(mode)
                    }
                }.pickerStyle(.segmented).padding(.horizontal, 16)
                if precision == .year || precision == .decade {
                    TextField(L.t("find_year"), text: $query).keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder).padding(.horizontal, 16)
                    List(years, id: \.self) { year in
                        Button(precision == .decade ? L.f("decade_format", String(year)) : String(year)) {
                            finish(PhotoDate(year: year, precision: precision))
                        }.accessibilityIdentifier("choose-year-\(year)")
                    }.listStyle(.plain)
                } else if precision == .month {
                    DatePicker(L.t("date"), selection: $date, displayedComponents: .date)
                        .datePickerStyle(.wheel).padding(.horizontal, 16)
                    Text(L.t("month_precision_hint")).font(.footnote).foregroundStyle(Paper.secondary)
                    Spacer()
                } else {
                    DatePicker(L.t("date"), selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                        .padding(.horizontal, 16)
                    Spacer()
                }
            }
            .environment(\.calendar, PhotoDate.calendar)
            .environment(\.timeZone, PhotoDate.calendar.timeZone)
            .padding(.top, 12)
            .navigationTitle(L.t("date")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.t("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if precision == .month || precision == .day {
                        Button(L.t("save")) {
                            let values = PhotoDate.calendar.dateComponents([.year, .month, .day], from: date)
                            if let year = values.year {
                                let value = PhotoDate(year: year, month: values.month,
                                                      day: precision == .day ? values.day : nil, precision: precision)
                                if value.date != nil { finish(value) }
                            }
                        }
                    } else if initial != nil { Button(L.t("clear")) { finish(nil) } }
                }
            }
        }
    }

    private var years: [Int] {
        let current = PhotoDate.calendar.component(.year, from: Date())
        let all = stride(from: precision == .decade ? current / 10 * 10 : current, through: 1800,
                         by: precision == .decade ? -10 : -1)
        return all.filter { query.isEmpty || String($0).contains(query) }
    }
    private func finish(_ value: PhotoDate?) { save(value); dismiss() }
}

struct TextEditorSheet: View {
    let key: String
    let suggestions: [String]
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @FocusState private var focus: Bool

    init(key: String, value: String, suggestions: [String], save: @escaping (String) -> Void) {
        self.key = key
        self.suggestions = suggestions
        self.save = save
        _value = State(initialValue: value)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L.t(key), text: $value, axis: .vertical).lineLimit(3...7).focused($focus)
                ForEach(suggestions.filter { !$0.isEmpty && $0 != value }.prefix(6), id: \.self) { name in
                    Button(name) { value = name }
                }
            }
            .navigationTitle(L.t(key)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.t("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("save")) {
                        save(String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(key == "people" ? 300 : 2000)))
                        dismiss()
                    }
                }
            }.task { focus = true }
        }
    }
}

struct PlaceEditor: View {
    let save: (Place?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var attempted = false
    private let initial: Place?

    init(initial: Place?, save: @escaping (Place?) -> Void) {
        self.initial = initial
        self.save = save
        _input = State(initialValue: initial?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L.t("place"), text: $input).onSubmit(search)
                Button(L.t("look_up_place"), systemImage: "magnifyingglass", action: search)
                    .disabled(input.isEmpty || searching)
                if searching { ProgressView() }
                if attempted && !searching && results.isEmpty { Text(L.t("no_places")).foregroundStyle(Paper.secondary) }
                ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                    Button {
                        let coordinate = item.placemark.coordinate
                        save(Place(name: item.name ?? input, latitude: coordinate.latitude, longitude: coordinate.longitude))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name ?? input)
                            if let address = item.placemark.title { Text(address).font(.caption).foregroundStyle(Paper.secondary) }
                        }
                    }
                }
            }
            .navigationTitle(L.t("place")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.t("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("save")) {
                        let name = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
                        save(name == initial?.name ? initial : name.isEmpty ? nil : Place(name: name))
                        dismiss()
                    }
                }
            }
        }
    }

    private func search() {
        guard !searching, !input.isEmpty else { return }
        searching = true
        attempted = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = input
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            results = Array((response?.mapItems ?? []).prefix(10))
            searching = false
        }
    }
}

struct BackEditor: View {
    let id: UUID
    @EnvironmentObject private var model: Model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = Camera()
    @State private var available = false
    @State private var taking = false
    @State private var wantsCamera = false
    @State private var picker: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if wantsCamera {
                        if available {
                            CameraPreview(session: camera.session).frame(height: 265).background(Paper.camera)
                            Button(L.t("shutter")) {
                                taking = true
                                camera.shutter(flash: false) { result in
                                    Task {
                                        defer { taking = false }
                                        if let data = try? result.get() { await receive(data) }
                                        else { model.message = L.t("capture_issue") }
                                    }
                                }
                            }.buttonStyle(ActionStyle()).disabled(taking || model.busy)
                        } else { Text(L.t("camera_unavailable")).foregroundStyle(Paper.secondary) }
                    } else if let photo = model.scan(id), let url = model.archive?.back(photo),
                              FileManager.default.fileExists(atPath: url.path) {
                        ArchiveImage(url: url, limit: 1000, mode: .fit).frame(height: 190)
                        if !photo.backText.isEmpty {
                            Text(photo.backText).font(.callout).textSelection(.enabled)
                            Button(L.t("use_as_note")) {
                                model.update(id) { $0.note = String(photo.backText.prefix(2000)) }
                                dismiss()
                            }
                        }
                        if let date = photo.suggestedDate {
                            Button(L.f("use_suggested_date", date.label)) {
                                model.update(id) { $0.date = date; $0.suggestedDate = nil }
                                dismiss()
                            }
                        }
                    }
                    if !wantsCamera {
                        Button(L.t("scan_back"), systemImage: "camera") {
                            #if DEBUG
                            if Launch.demo {
                                Task {
                                    do { await receive(try await model.work { Demo.backData }) }
                                    catch { model.message = L.t("capture_issue") }
                                }
                                return
                            }
                            #endif
                            wantsCamera = true
                            camera.onAvailability = { ready, _ in available = ready }
                            camera.start()
                        }.buttonStyle(ActionStyle()).accessibilityIdentifier("capture-back")
                    }
                    PhotosPicker(selection: $picker, matching: .images) { Text(L.t("import_back")) }
                        .disabled(model.busy)
                    Text(L.t("ocr_disclosure")).font(.footnote).foregroundStyle(Paper.secondary)
                }.padding(18)
            }
            .background(Paper.background.ignoresSafeArea())
            .navigationTitle(L.t("scan_back")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L.t("done")) { dismiss() } } }
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { camera.stop() } else if wantsCamera { camera.start() } }
        .onChange(of: picker) { _, value in
            guard let value else { return }
            Task {
                defer { picker = nil }
                if let data = try? await value.loadTransferable(type: Data.self) { await receive(data) }
                else { model.message = L.t("capture_issue") }
            }
        }
    }

    private func receive(_ data: Data) async {
        await camera.stopForAnalysis()
        wantsCamera = false
        await model.back(id, data: data)
    }
}
