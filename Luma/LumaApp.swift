import SwiftUI
import AVFoundation
import Photos
import CoreImage
import UIKit

@main struct LumaApp: App {
    @StateObject private var library = Library()
    var body: some Scene { WindowGroup { CameraScreen().environmentObject(library).preferredColorScheme(.dark) } }
}

struct Adjustments: Codable {
    var exposure: Double = 0
    var contrast: Double = 1.04
    var saturation: Double = 0.96
    var warmth: Double = 0
    var highlights: Double = 0.85
    var shadows: Double = 0.12
}

struct PhotoItem: Identifiable, Codable {
    var id: UUID
    var date: Date
    var filename: String
    var raw: Bool
    var adjustments: Adjustments
}

@MainActor final class Library: ObservableObject {
    @Published var items: [PhotoItem] = []
    @Published var error: String?
    let directory: URL
    private var index: URL { directory.appendingPathComponent("index.json") }
    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Luma", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: index.path) {
                items = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: index))
            }
        } catch { self.error = "Could not open the library: \(error.localizedDescription)" }
    }
    func save(data: Data, raw: Bool) {
        let id = UUID()
        let name = id.uuidString + (raw ? ".dng" : ".jpg")
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            items.insert(PhotoItem(id: id, date: Date(), filename: name, raw: raw, adjustments: Adjustments()), at: 0)
            try persist()
        } catch { self.error = "Could not save the photo: \(error.localizedDescription)" }
    }
    func update(_ item: PhotoItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        do { try persist() } catch { self.error = "Could not save edits: \(error.localizedDescription)" }
    }
    func delete(_ item: PhotoItem) {
        do {
            try FileManager.default.removeItem(at: url(item))
            items.removeAll { $0.id == item.id }
            try persist()
        } catch { self.error = "Could not delete the photo: \(error.localizedDescription)" }
    }
    func url(_ item: PhotoItem) -> URL { directory.appendingPathComponent(item.filename) }
    private func persist() throws { try JSONEncoder().encode(items).write(to: index, options: .atomic) }
}

enum Renderer {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static func image(url: URL, adjustments a: Adjustments, maxDimension: CGFloat? = nil) -> UIImage? {
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        if let maxDimension = maxDimension {
            let size = image.extent.size
            let scale = min(1, maxDimension / max(size.width, size.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + a.warmth * 2000, y: 0)])
        image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": a.highlights, "inputShadowAmount": a.shadows])
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation])
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "luma.camera")
    private let output = AVCapturePhotoOutput()
    @Published var ready = false
    @Published var message: String?
    var onCapture: ((Data, Bool) -> Void)?
    private var configured = false
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.configure() } else { DispatchQueue.main.async { self.message = "Camera access is off. Enable it in Settings to take photos." } }
            }
        default: message = "Camera access is off. Enable it in Settings to take photos."
        }
    }
    private func configure() {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.message = "The back camera is unavailable." }
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(self.output)
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.ready = true }
        }
    }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() }; DispatchQueue.main.async { self.ready = false } } }
    func capture() {
        queue.async {
            guard self.session.isRunning else { return }
            let settings: AVCapturePhotoSettings
            if let connection = self.output.connection(with: .video), connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if let format = self.output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
                settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { DispatchQueue.main.async { self.message = "Capture failed: \(error.localizedDescription)" }; return }
        guard let data = photo.fileDataRepresentation() else { DispatchQueue.main.async { self.message = "The camera did not return a photo." }; return }
        DispatchQueue.main.async { self.onCapture?(data, photo.isRawPhoto) }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Preview {
        let view = Preview(); view.previewLayer.session = session; view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        return view
    }
    func updateUIView(_ uiView: Preview, context: Context) {}
}

struct CameraScreen: View {
    @EnvironmentObject var library: Library
    @Environment(\.scenePhase) private var phase
    @StateObject private var camera = Camera()
    @State private var showGallery = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LUMA").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(4)
                        Text("A LITTLE MORE INTENTIONAL").font(.system(size: 9, weight: .medium)).tracking(1.8).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Image(systemName: "camera.aperture").font(.title3).foregroundStyle(.white.opacity(0.7))
                }.padding(.horizontal, 24).padding(.vertical, 20)
                ZStack {
                    CameraPreview(session: camera.session).clipShape(RoundedRectangle(cornerRadius: 6))
                    if let message = camera.message { Text(message).multilineTextAlignment(.center).padding().background(.black.opacity(0.8)).cornerRadius(12).padding() }
                    VStack { Spacer(); HStack { Text("VIEWFINDER").font(.system(size: 9, weight: .semibold)).tracking(2); Spacer(); Text("01").font(.caption.monospacedDigit()) }.foregroundStyle(.white.opacity(0.75)).padding(16) }
                }.padding(.horizontal, 12)
                HStack {
                    Button { showGallery = true } label: {
                        VStack(spacing: 7) { Image(systemName: "square.grid.2x2").font(.title2); Text("GALLERY").font(.system(size: 9, weight: .semibold)).tracking(1) }
                    }.frame(maxWidth: .infinity).accessibilityLabel("Open gallery")
                    Button { camera.capture() } label: { Circle().stroke(.white, lineWidth: 3).frame(width: 78, height: 78).overlay(Circle().fill(.white).padding(7)) }
                        .disabled(!camera.ready).opacity(camera.ready ? 1 : 0.45).accessibilityLabel("Take photo")
                    VStack(spacing: 7) { Image(systemName: "sparkles").font(.title2); Text("SHOOT FIRST").font(.system(size: 9, weight: .semibold)).tracking(1) }.frame(maxWidth: .infinity).foregroundStyle(.white.opacity(0.55))
                }.foregroundStyle(.white).padding(.vertical, 24)
            }
        }
        .onAppear { camera.onCapture = { data, raw in library.save(data: data, raw: raw) }; camera.start() }
        .onChange(of: phase) { newPhase in if newPhase == .active && !showGallery { camera.start() } else { camera.stop() } }
        .fullScreenCover(isPresented: $showGallery, onDismiss: { camera.start() }) { GalleryScreen().environmentObject(library).onAppear { camera.stop() } }
        .alert("Luma", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(library.error ?? "") }
    }
}

struct GalleryScreen: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    VStack(spacing: 14) { Image(systemName: "camera.aperture").font(.system(size: 42)).foregroundStyle(.orange); Text("Your story starts here").font(.title3.bold()); Text("Photos you take will appear in this gallery.").foregroundStyle(.secondary).multilineTextAlignment(.center) }.padding()
                } else {
                    ScrollView { LazyVGrid(columns: columns, spacing: 4) { ForEach(library.items) { item in NavigationLink { EditorScreen(item: item) } label: { Thumbnail(url: library.url(item), adjustments: item.adjustments) } } }.padding(4) }
                }
            }.background(Color.black).navigationTitle("Gallery").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Camera") { dismiss() } }; ToolbarItem(placement: .topBarTrailing) { Text("\(library.items.count)").foregroundStyle(.secondary) } }
        }.preferredColorScheme(.dark)
    }
}

struct Thumbnail: View {
    let url: URL
    let adjustments: Adjustments
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { proxy in
            ZStack { Color(white: 0.12); if let image = image { Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped() } else { Image(systemName: "photo").foregroundStyle(.secondary) } }
        }.aspectRatio(1, contentMode: .fit)
            .task(id: "\(url.path)-\(adjustments.exposure)-\(adjustments.contrast)-\(adjustments.saturation)-\(adjustments.warmth)-\(adjustments.highlights)-\(adjustments.shadows)") {
                image = await Task.detached(priority: .utility) { Renderer.image(url: url, adjustments: adjustments, maxDimension: 350) }.value
            }
    }
}

struct EditorScreen: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State var item: PhotoItem
    @State private var preview: UIImage?
    @State private var selected = 0
    @State private var showDelete = false
    @State private var status: String?
    @State private var busy = false
    private let names = ["Exposure", "Contrast", "Color", "Warmth", "Highlights", "Shadows"]
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let preview = preview { Image(uiImage: preview).resizable().scaledToFit() }
                else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("DEVELOP").font(.caption.bold()).tracking(2); Spacer(); Text(item.raw ? "RAW ORIGINAL" : "PHOTO ORIGINAL").font(.caption2).tracking(1).foregroundStyle(.secondary) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(names.indices, id: \.self) { i in Button(names[i]) { selected = i }.font(.subheadline.weight(selected == i ? .semibold : .regular)).padding(.horizontal, 14).padding(.vertical, 9).background(selected == i ? Color.white : Color.white.opacity(0.08)).foregroundStyle(selected == i ? Color.black : Color.white).clipShape(Capsule()) } }
                }
                HStack { Text(names[selected]).font(.subheadline); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Slider(value: value, in: range).tint(.orange)
                HStack { Button("Reset") { item.adjustments = Adjustments() }; Spacer(); Button { export() } label: { Label(busy ? "Saving…" : "Save to Photos", systemImage: "square.and.arrow.down") }.disabled(busy) }.font(.subheadline.weight(.medium))
            }.padding(20).background(Color(white: 0.1))
        }.background(.black).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { Text(item.date, style: .date).font(.subheadline) }; ToolbarItem(placement: .topBarTrailing) { Button(role: .destructive) { showDelete = true } label: { Image(systemName: "trash") } } }
            .confirmationDialog("Delete this photo and its original?", isPresented: $showDelete, titleVisibility: .visible) { Button("Delete Photo", role: .destructive) { library.delete(item); dismiss() } }
            .alert("Luma", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) { Button("OK", role: .cancel) {} } message: { Text(status ?? "") }
            .onDisappear { library.update(item) }
            .task(id: renderID) {
                let url = library.url(item), adjustment = item.adjustments
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                let rendered = await Task.detached(priority: .userInitiated) { Renderer.image(url: url, adjustments: adjustment, maxDimension: 1600) }.value
                if !Task.isCancelled { preview = rendered; library.update(item); if rendered == nil { status = "This photo could not be rendered on this device." } }
            }
    }
    private var renderID: String { let a = item.adjustments; return "\(a.exposure),\(a.contrast),\(a.saturation),\(a.warmth),\(a.highlights),\(a.shadows)" }
    private var value: Binding<Double> {
        switch selected {
        case 0: return $item.adjustments.exposure
        case 1: return $item.adjustments.contrast
        case 2: return $item.adjustments.saturation
        case 3: return $item.adjustments.warmth
        case 4: return $item.adjustments.highlights
        default: return $item.adjustments.shadows
        }
    }
    private var range: ClosedRange<Double> {
        switch selected { case 0: return -2...2; case 1: return 0.5...1.5; case 2: return 0...2; case 3: return -1...1; default: return 0...1 }
    }
    private func export() {
        busy = true
        let url = library.url(item), adjustments = item.adjustments
        Task {
            let data = await Task.detached(priority: .userInitiated) { Renderer.image(url: url, adjustments: adjustments)?.jpegData(compressionQuality: 0.94) }.value
            guard let data = data else { busy = false; status = "Could not render this photo."; return }
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else { busy = false; status = "Allow Photos access in Settings to save an export."; return }
            do {
                try await PHPhotoLibrary.shared().performChanges { let request = PHAssetCreationRequest.forAsset(); request.addResource(with: .photo, data: data, options: nil) }
                busy = false; status = "Saved to Photos."
            } catch { busy = false; status = "Could not save to Photos: \(error.localizedDescription)" }
        }
    }
}

