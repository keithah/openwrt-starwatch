import PhotosUI
import SwiftUI
import UIKit
import WattlineNetwork

struct RouterPairingEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairingText = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsScanner = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing code") {
                    TextField("wattline://pair…", text: $pairingText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { values in
                        pairingText = values.first ?? ""
                    }
                    Button("Use pairing link") { consume(pairingText) }
                        .disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("QR code") {
                    Button("Scan with camera") { showsScanner = true }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Choose QR image", systemImage: "photo")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Pair Router")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showsScanner) {
                RouterQRCodeScannerView { consume($0) }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
        }
    }

    @discardableResult
    private func consume(_ value: String) -> Bool {
        guard let input = try? RouterPairingInputParser.parse(text: value) else {
            errorMessage = "That is not a valid wattlined pairing code."
            return false
        }
        model.routerEnrollmentRoute.consume(input)
        pairingText = ""
        errorMessage = nil
        dismiss()
        return true
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw QRCodeRecognitionError.noPairingCode
            }
            let importer = RouterPairingImageImporter(
                recognizer: VisionQRCodeRecognizer(),
                route: model.routerEnrollmentRoute
            )
            try await importer.importImage(data)
            dismiss()
        } catch {
            errorMessage = "No valid wattlined pairing QR code was found in that image."
        }
    }
}

struct RouterEnrollmentView: View {
    enum Source {
        case discovered(DiscoveredRouter)
        case payload(RouterPairingPayload)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pin = ""
    @State private var label = UIDevice.current.name
    @State private var displayName = "My router"
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    let source: Source

    init(router: DiscoveredRouter) {
        source = .discovered(router)
        _displayName = State(initialValue: router.serviceName)
    }

    init(payload: RouterPairingPayload) {
        source = .payload(payload)
        _displayName = State(initialValue: payload.host)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Router") {
                    LabeledContent("Device", value: deviceID)
                    LabeledContent("Address", value: authority)
                    TextField("Router name", text: $displayName)
                    TextField("Client label", text: $label)
                }

                if case .discovered = source {
                    Section("Current pairing PIN") {
                        SecureField("6-digit PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                }

                Section {
                    Button(isSubmitting ? "Pairing…" : "Pair and connect") { submit() }
                        .disabled(!canSubmit || isSubmitting)
                } footer: {
                    Text("The managed client token is stored in Keychain. Wattline never stores the pairing PIN.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Pair Router")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { clearAndDismiss() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { clearAndDismiss() }
            }
            .onDisappear { clearSecrets() }
        }
    }

    private var deviceID: String {
        switch source {
        case .discovered(let router): router.deviceID
        case .payload(let payload): payload.deviceID
        }
    }

    private var authority: String {
        switch source {
        case .discovered(let router): "\(router.endpoint.host):\(router.endpoint.port)"
        case .payload(let payload): "\(payload.enrollmentEndpoint.host):\(payload.enrollmentEndpoint.port)"
        }
    }

    private var canSubmit: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && {
                if case .discovered = source { return pin.count == 6 }
                return true
            }()
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            let coordinator = RouterEnrollmentCoordinator(
                connections: model.routerConnections,
                connect: { model.connectViaRouter($0) }
            )
            do {
                switch source {
                case .discovered(let router):
                    try await coordinator.submit(pin: pin, label: label, router: router)
                case .payload(let payload):
                    try await coordinator.submit(
                        payload: payload,
                        displayName: displayName,
                        label: label
                    )
                }
                clearAndDismiss()
            } catch {
                errorMessage = coordinator.errorMessage
                isSubmitting = false
            }
        }
    }

    private func clearSecrets() {
        pin = ""
        if case .payload = source { model.routerEnrollmentRoute.clear() }
    }

    private func clearAndDismiss() {
        clearSecrets()
        dismiss()
    }
}
