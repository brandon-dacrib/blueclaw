import SwiftUI
import PhotosUI
import AVFoundation

struct MessageInputView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isFocused: Bool
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showCameraPermissionAlert = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppColors.surfaceBorder)

            // Attachment preview
            if let image = viewModel.pendingImage {
                HStack {
                    AttachmentPreviewView(image: image) {
                        viewModel.clearAttachment()
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Attachment menu
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        requestCameraAccess()
                    } label: {
                        Label("Camera", systemImage: "camera")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(AppColors.accent)
                }

                // Text input
                TextField("Message", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(isFocused ? AppColors.accent.opacity(0.5) : AppColors.inputBorder, lineWidth: 1)
                    )
                    .onSubmit {
                        Task { await viewModel.send() }
                    }

                // Voice-to-text
                VoiceButton { text in
                    viewModel.inputText = text
                    Task { await viewModel.send() }
                }

                // Send / Abort button
                if viewModel.isStreaming {
                    Button {
                        Task { await viewModel.abort() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(AppColors.accent)
                    }
                } else {
                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(canSend ? AppColors.accent : AppColors.textMuted)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppColors.surface)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) {
            guard let item = selectedPhotoItem else { return }
            selectedPhotoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    viewModel.attachImage(image)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPickerView { image in
                viewModel.attachImage(image)
            }
            .ignoresSafeArea()
        }
        .alert("Camera Access Required", isPresented: $showCameraPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BlueClaw needs camera access to take photos. Please enable it in Settings.")
        }
        .alert(
            "Sensitive Content Detected",
            isPresented: Binding(
                get: { viewModel.sensitiveWarning != nil },
                set: { if !$0 { viewModel.cancelSend() } }
            )
        ) {
            Button("Send Anyway", role: .destructive) {
                Task { await viewModel.confirmSend() }
            }
            Button("Edit Message", role: .cancel) {
                viewModel.cancelSend()
            }
        } message: {
            if let matches = viewModel.sensitiveWarning {
                Text("Your message may contain sensitive data that will be sent to the server:\n\n"
                     + matches.map { "- \($0.category): \($0.matched)" }.joined(separator: "\n"))
            }
        }
    }

    private func requestCameraAccess() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    showCamera = true
                }
            }
        case .denied, .restricted:
            showCameraPermissionAlert = true
        @unknown default:
            showCamera = true
        }
    }

    private var canSend: Bool {
        let hasText = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = viewModel.pendingImage != nil
        return (hasText || hasImage) && !viewModel.isStreaming
    }
}
