import AVFoundation
import CoreMotion
import PhotosUI
import SwiftUI

struct FinderView: View {
    let active: Bool
    let open: (Route) -> Void
    let upgrade: () -> Void
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.openURL) private var openURL
    @State private var camera: Camera?
    @State private var motion = CMMotionManager()
    @State private var ready: Bool? = Launch.has("-camera-denied") ? false : nil
    @State private var demoImage: UIImage?
    @State private var hasFlash = false
    @State private var flash = false
    @State private var taking = false
    @State private var state = AutoShutter()
    @State private var frame = ViewfinderFrame(boxes: [], aspect: 0.75, reflection: false, signature: [])
    @State private var picker: PhotosPickerItem?
    @State private var showingImport = false
    @State private var mode: Mode = .page
    @State private var editingAlbum = false
    @State private var renameID: UUID?
    @State private var albumName = ""
    @State private var glare: GlareSequence?
    @State private var notice = ""
    @State private var lastSuccessfulAt = Date.distantPast
    @AppStorage("trial-disclosure-seen") private var trialDisclosureSeen = false

    private enum Mode: String, CaseIterable { case single, page, back }
    private struct GlareSequence {
        var id: UUID
        var frames: [URL] = []
        var roll: Double?
        var pitch: Double?
        var alignedAt: Double?
        var lastSignature: [Double]
    }
    private static let angles = ["angle_left", "angle_right", "angle_top", "angle_bottom"]

    var body: some View {
        VStack(spacing: 0) {
            header
            viewfinder
                .frame(maxHeight: .infinity)
            controls
            if !Launch.freePeriod, !Launch.isolated, !trialDisclosureSeen, purchases.days > 0, !purchases.access.bought {
                HStack {
                    Button(L.t("trial_badge")) { trialDisclosureSeen = true; upgrade() }
                    Spacer()
                    Button { trialDisclosureSeen = true } label: { Image(systemName: "xmark").padding(.horizontal, 8) }
                        .accessibilityLabel(L.t("dismiss"))
                }.font(.caption).foregroundStyle(.white.opacity(0.76)).padding(.horizontal, 20)
                    .padding(.bottom, 5)
            }
        }
        .foregroundStyle(.white)
        .background(Paper.camera.ignoresSafeArea())
        .preferredColorScheme(active ? .dark : nil)
        .alert(L.t(renameID == nil ? "new_album" : "rename_album"), isPresented: $editingAlbum) {
            TextField(L.t("album_name"), text: $albumName)
            Button(L.t("save")) { model.editAlbum(albumName, id: renameID) }
            Button(L.t("cancel"), role: .cancel) {}
        }
        .onChange(of: active, initial: true) { _, running in
            if running { prepareCamera() }
            else { camera?.stop(); resetSupplement(); state.resetStability() }
        }
        .onDisappear { camera?.stop(); resetSupplement(); state.resetStability() }
        .task(id: active) {
            #if DEBUG
            guard active, Launch.demo, demoImage == nil else { return }
            let preview = try? await model.work { Demo.preview }
            if !Task.isCancelled { demoImage = preview }
            #endif
        }
        .photosPicker(isPresented: $showingImport, selection: $picker, matching: .images)
        .onChange(of: picker) { _, value in
            guard let value else { return }
            Task {
                defer { picker = nil }
                do {
                    guard let image = try await value.loadTransferable(type: Data.self) else { throw ScanError.image }
                    if mode == .back, let id = model.scans.last?.id {
                        await camera?.stopForAnalysis(); await model.back(id, data: image); open(.detail(id))
                    }
                    else { _ = await model.ingest(image, single: mode == .single) }
                } catch { model.message = L.t("capture_issue") }
            }
        }
        .task(id: model.message) {
            guard !model.message.isEmpty else { return }
            notice = model.message
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = "" }
        }
    }

    private var header: some View {
        HStack {
            PhotosPicker(selection: $picker, matching: .images) {
                Image(systemName: "photo.on.rectangle").frame(width: 44, height: 44)
            }
            .accessibilityLabel(L.t("import_photo"))
            .accessibilityIdentifier("finder-import")
            Spacer()
            Menu {
                ForEach(model.albums) { album in
                    Button { model.select(album) } label: {
                        if model.selectedAlbum?.id == album.id { Label(album.title, systemImage: "checkmark") }
                        else { Text(album.title) }
                    }
                }
                Divider()
                Button(L.t("new_album"), systemImage: "plus") {
                    renameID = nil; albumName = ""; editingAlbum = true
                }
                if let album = model.selectedAlbum {
                    Button(L.t("rename_album"), systemImage: "pencil") {
                        renameID = album.id; albumName = album.title; editingAlbum = true
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.selectedAlbum?.title ?? L.f("album_number", "1"))
                        .font(.system(size: 19, weight: .semibold, design: .serif)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.white.opacity(0.55))
                }.frame(minHeight: 44)
            }
            .accessibilityIdentifier("finder-album")
            Spacer()
            Button {
                flash.toggle()
            } label: {
                Image(systemName: flash ? "bolt.fill" : "bolt.slash")
                    .frame(width: 42, height: 42).background(.white.opacity(0.11), in: Circle())
            }
            .disabled(!hasFlash || glare != nil)
            .accessibilityLabel(L.t("flash"))
            .accessibilityValue(L.t(flash ? "on" : "off"))
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 4)
    }

    private var viewfinder: some View {
        GeometryReader { proxy in
            let imageRect = aspectFit(frame.aspect, in: proxy.size)
            ZStack {
                Color(hex: 0x29241F)
                if let demoImage {
                    Image(uiImage: demoImage).resizable().scaledToFit()
                        .frame(maxWidth: proxy.size.width, maxHeight: proxy.size.height)
                    if mode != .back { CornerOverlay(boxes: frame.boxes, rect: imageRect) }
                } else if ready == true, let camera {
                    CameraPreview(session: camera.session)
                    if mode != .back { CornerOverlay(boxes: frame.boxes, rect: imageRect) }
                } else if ready == false {
                    VStack(spacing: 12) {
                        Image(systemName: "camera").font(.system(size: 35, weight: .light))
                        Text(L.t("camera_unavailable")).font(.headline).multilineTextAlignment(.center)
                        Button(L.t("open_settings")) {
                            if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                        }.buttonStyle(.bordered).tint(.white)
                        Button(L.t("import_photo")) { showingImport = true }
                            .accessibilityIdentifier("denied-import")
                    }.padding()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .overlay(alignment: .top) {
                if ready != false, !Launch.demo || demoImage != nil {
                    hint.padding(.top, 12).padding(.horizontal, 12)
                }
            }
            .clipped()
        }
    }

    private var hint: some View {
        HStack(spacing: 8) {
            if taking || model.busy { ProgressView().scaleEffect(0.7).tint(.white) }
            else { Circle().fill(Paper.marker).frame(width: 6, height: 6) }
            Text(hintText).foregroundStyle(.white).multilineTextAlignment(.center)
                .accessibilityIdentifier("finder-status")
            if glare != nil {
                Button(L.t("cancel")) { resetSupplement() }.foregroundStyle(Paper.marker)
            } else if let id = model.reflectionID {
                Button(L.t("remove_glare")) { beginSupplement(id) }.foregroundStyle(Paper.marker)
                    .accessibilityIdentifier("finder-glare")
            } else if !notice.isEmpty && notice == L.t("photos_denied") {
                Button(L.t("open_settings")) {
                    if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                }.foregroundStyle(Paper.marker)
            }
        }
        .font(.footnote.weight(.semibold)).padding(.vertical, 9).padding(.horizontal, 13)
        .background(.black.opacity(0.63), in: Capsule()).buttonStyle(.plain)
    }

    private var hintText: String {
        if let glare { return L.f("angle_format", L.t(Self.angles[min(glare.frames.count, 3)]), String(glare.frames.count + 1)) }
        if taking || model.busy { return L.t("processing") }
        if !notice.isEmpty { return notice }
        if mode == .back { return L.t("back_hint") }
        if frame.reflection { return L.t("glare_hint") }
        if model.recentCount > 0, model.reflectionID != nil { return L.f("scan_glare_hint", String(model.recentCount)) }
        if !frame.boxes.isEmpty { return L.f(model.preferences.autoCapture ? "hold_steady" : "frames_found", String(frame.boxes.count)) }
        return L.t(mode == .page ? "page_hint" : "single_hint")
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(Mode.allCases, id: \.self) { target in
                    Button {
                        if target == .back, !purchases.hasPro { upgrade(); return }
                        if target == .back, model.scans.isEmpty { model.message = L.t("back_needs_scan"); return }
                        mode = target
                        state.resetStability()
                        camera?.setSingle(target == .single)
                    } label: {
                        Text(L.t("mode_" + target.rawValue)).font(.subheadline.weight(mode == target ? .bold : .regular))
                            .foregroundStyle(mode == target ? Paper.marker : .white.opacity(0.57)).frame(minHeight: 44)
                    }.accessibilityAddTraits(mode == target ? .isSelected : [])
                }
            }.disabled(glare != nil)
            HStack(spacing: 0) {
                Button { open(.library) } label: {
                    ZStack(alignment: .topTrailing) {
                        PhotoStack(urls: model.scans.suffix(3).reversed().compactMap { model.archive?.thumbnail($0) })
                            .scaleEffect(0.65).frame(width: 64, height: 57)
                        if !model.scans.isEmpty {
                            Text(model.scans.count, format: .number).font(.caption2.bold()).monospacedDigit()
                                .foregroundStyle(Paper.camera).padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Paper.marker, in: Capsule()).offset(x: 4, y: -4)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(L.t("open_library"))
                .accessibilityIdentifier("finder-library")
                Button { take() } label: {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 2.5).frame(width: 73, height: 73)
                        Circle().fill(.white).frame(width: 62, height: 62)
                        if taking || model.busy { ProgressView().tint(Paper.camera) }
                    }
                }
                .disabled(!canCapture)
                .accessibilityLabel(L.t("shutter"))
                .accessibilityIdentifier("finder-shutter")
                Button { model.preferences.autoCapture.toggle(); state.resetStability() } label: {
                    Text(L.t(model.preferences.autoCapture ? "auto_on" : "auto_off"))
                        .font(.caption.weight(.semibold)).lineLimit(2)
                        .padding(.horizontal, 10).padding(.vertical, 9).background(.white.opacity(0.12), in: Capsule())
                        .frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("finder-auto")
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 12)
    }

    private func prepareCamera() {
        if Launch.demo {
            #if DEBUG
            frame = ViewfinderFrame(boxes: Demo.boxes, aspect: Demo.aspect, reflection: true, signature: [])
            #endif
            model.reflectionID = model.scans.first(where: \.reflected)?.id
            return
        }
        guard !Launch.has("-camera-denied") else { return }
        let camera = self.camera ?? Camera()
        self.camera = camera
        camera.setSingle(mode == .single)
        camera.onAvailability = { ready = $0; hasFlash = $1 }
        camera.onFrame = { value in
            frame = value
            if glare != nil { checkAngle(value); return }
            guard model.preferences.autoCapture, mode != .back, !taking, !model.busy,
                  Date().timeIntervalSince(lastSuccessfulAt) > 0.8 else { return }
            if state.update(boxes: value.boxes, signature: value.signature, now: CACurrentMediaTime()) { take() }
        }
        camera.start()
    }

    private var canCapture: Bool {
        active && !taking && !model.busy && (Launch.demo ? demoImage != nil : ready == true && camera != nil)
    }

    private func take() {
        guard canCapture else { return }
        let snapshot = frame
        taking = true
        let captureMode = mode
        let isSupplement = glare != nil
        func finish(_ result: Result<Data, Error>) async {
            defer { taking = false }
            do {
                let data = try result.get()
                if isSupplement {
                    if glare != nil { await receiveSupplement(data, signature: snapshot.signature) }
                } else if captureMode == .back, let last = model.scans.last {
                    await camera?.stopForAnalysis()
                    await model.back(last.id, data: data)
                    open(.detail(last.id))
                } else if await model.ingest(data, single: captureMode == .single) {
                    state.captured(snapshot.boxes, signature: snapshot.signature)
                    lastSuccessfulAt = Date()
                }
            } catch { model.message = L.t("capture_issue"); state.resetStability() }
        }
        #if DEBUG
        if Launch.demo {
            Task {
                do {
                    let data = try await model.work { captureMode == .back ? Demo.backData : Demo.jpeg }
                    await finish(.success(data))
                } catch { await finish(.failure(error)) }
            }
            return
        }
        #endif
        camera?.shutter(flash: flash && !isSupplement) { result in
            Task { await finish(result) }
        }
    }

    private func beginSupplement(_ id: UUID) {
        guard purchases.hasPro else { upgrade(); return }
        guard !taking, !model.busy else { return }
        if motion.isDeviceMotionAvailable { motion.startDeviceMotionUpdates() }
        let attitude = motion.deviceMotion?.attitude
        glare = GlareSequence(id: id, roll: attitude?.roll, pitch: attitude?.pitch, lastSignature: frame.signature)
    }

    private func checkAngle(_ frame: ViewfinderFrame) {
        guard !taking, !model.busy, var step = glare, !frame.boxes.isEmpty, step.frames.count < 4,
              let attitude = motion.deviceMotion?.attitude else { return }
        guard let roll = step.roll, let pitch = step.pitch else {
            step.roll = attitude.roll
            step.pitch = attitude.pitch
            glare = step
            return
        }
        let offsets = [roll - attitude.roll, attitude.roll - roll,
                       attitude.pitch - pitch, pitch - attitude.pitch]
        let aligned = offsets[step.frames.count] > 0.10 && offsets[step.frames.count] < 0.48
            && AutoShutter.signatureDelta(step.lastSignature, frame.signature) > 0.022
        let speed = hypot(hypot(motion.deviceMotion?.rotationRate.x ?? 0, motion.deviceMotion?.rotationRate.y ?? 0),
                          motion.deviceMotion?.rotationRate.z ?? 0)
        let now = CACurrentMediaTime()
        step.alignedAt = aligned && speed < 0.20 ? step.alignedAt ?? now : nil
        glare = step
        if let since = step.alignedAt, now - since >= 0.55 { take() }
    }

    private func receiveSupplement(_ data: Data, signature: [Double]) async {
        guard var step = glare else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".capture")
        do {
            try await model.work { try data.write(to: url, options: .atomic) }
            guard glare?.id == step.id else { try? FileManager.default.removeItem(at: url); return }
            step.frames.append(url)
            step.lastSignature = signature
            step.alignedAt = nil
            if step.frames.count == 4 {
                motion.stopDeviceMotionUpdates()
                glare = nil
                await model.reduceGlare(step.id, frames: step.frames)
                state.captured(frame.boxes, signature: frame.signature)
            } else { glare = step }
        } catch { model.message = L.t("disk_error"); resetSupplement() }
    }

    private func resetSupplement() {
        motion.stopDeviceMotionUpdates()
        for url in glare?.frames ?? [] { try? FileManager.default.removeItem(at: url) }
        glare = nil
    }
}
