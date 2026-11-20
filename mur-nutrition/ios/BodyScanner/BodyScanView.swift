import AVFoundation
import SwiftUI

/// Full-screen body scan: live camera, live coaching, then results.
struct BodyScanView: View {
    @StateObject private var scan = BodyScanSession()
    @State private var heightText = ""
    @State private var sex: BiologicalSex = .male

    private let accent = Color(red: 0.36, green: 0.88, blue: 0.66) // MUR green #5be0a8

    var body: some View {
        ZStack {
            CameraPreview(session: scan.camera.session).ignoresSafeArea()
            VStack {
                header
                Spacer()
                footer
            }
            .padding()
        }
        .background(Color.black)
        .onAppear { scan.prepare() }
        .onDisappear { scan.shutdown() }
        .sheet(isPresented: .constant(scan.result != nil)) {
            if let result = scan.result {
                ResultView(result: result) { scan.cancel() }.interactiveDismissDisabled()
            }
        }
    }

    @ViewBuilder private var header: some View {
        switch scan.stage {
        case .front, .side:
            VStack(spacing: 8) {
                Text(scan.stage == .front ? "Step 1 of 2 · Face the camera, arms slightly out"
                                          : "Step 2 of 2 · Turn to your side")
                    .font(.headline)
                ProgressView(value: scan.progress).tint(accent)
                if let issue = scan.issues.first {
                    Text(issue.instruction).font(.title3.bold()).foregroundStyle(.yellow)
                } else {
                    Text("Hold still…").font(.title3.bold()).foregroundStyle(accent)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .failed(let message):
            Text(message).padding().background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var footer: some View {
        if scan.stage == .front || scan.stage == .side {
            Button("Cancel") { scan.cancel() }.buttonStyle(.bordered)
        } else {
            VStack(spacing: 12) {
                Text("Prop your phone upright at waist height, 2–2.5 m away. Wear fitted clothing and stand at least 1 m in front of a plain wall.")
                    .font(.footnote).multilineTextAlignment(.center)
                TextField("Your height (cm), measured with a tape", text: $heightText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Picker("Sex", selection: $sex) {
                    ForEach(BiologicalSex.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Button {
                    scan.startScan(profile: BodyScanProfile(knownHeightCm: Float(heightText), sex: sex))
                } label: {
                    Text("Start body scan").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct ResultView: View {
    let result: BodyScanResult
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Measurements") {
                    row("Height", result.height)
                    row("Neck", result.neck)
                    row("Chest", result.chest)
                    row("Waist", result.waist)
                    row("Hips", result.hip)
                }
                if let bf = result.bodyFatPercent {
                    Section("Estimated body fat") {
                        Text(String(format: "%.1f %%", bf)).font(.title2.bold())
                        Text("U.S. Navy method. Typical error is about ±3–4 %.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("\(result.framesUsed) frames · \(result.usedLiDAR ? "LiDAR" : "dual camera") depth")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Body scan")
            .toolbar { Button("Done", action: onDone) }
        }
    }

    @ViewBuilder private func row(_ label: String, _ m: BodyMeasurement?) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let m {
                Text(String(format: "%.1f cm", m.cm)).bold()
                Text(String(format: "±%.1f", m.spreadCm)).foregroundStyle(.secondary)
            } else {
                Text("not reliable, rescan").foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows the whole sensor frame (aspect-fit) so the user sees exactly what is being measured.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
