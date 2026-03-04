
import SwiftUI
import UIKit

struct ImageDetailView: View {
    let galleryImage: GalleryImage

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Namespace private var glassNamespace

    @State private var displayImage: UIImage?
    @State private var metadata: PhotoAssetMetadata?
    @State private var isMetadataVisible = false
    @State private var isAtMinimumZoom = true
    @State private var verticalDragOffset: CGFloat = 0
    @State private var sharePayload: SharePayload?

    private let photoLibraryService = PhotoLibraryService()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                Group {
                    if let image = displayImage ?? galleryImage.image {
                        ZoomableImageView(image: image, isAtMinimumZoom: $isAtMinimumZoom)
                    } else {
                        ContentUnavailableView("Image Error", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.white)
                    }
                }
                .ignoresSafeArea()
                .offset(y: verticalDragOffset)
                .opacity(contentOpacity)
                .allowsHitTesting(!isMetadataVisible)
                .simultaneousGesture(previewGesture)

                overlayChrome
            }
            .task(id: galleryImage.sourceId) {
                await loadPhotoDetails(for: proxy.size)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(isMetadataVisible)
        .sheet(item: $sharePayload) { payload in
            ShareSheet(activityItems: [payload.image])
        }
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

private extension ImageDetailView {
    static let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var contentOpacity: Double {
        let progress = min(max(verticalDragOffset / 260, 0), 1)
        return 1 - Double(progress * 0.45)
    }

    var shareImage: UIImage? {
        displayImage ?? galleryImage.image
    }

    var overlayChrome: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 12) {
                topControls
            }

            Spacer()

            GlassEffectContainer(spacing: 18) {
                bottomControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .zIndex(1)
    }

    var topControls: some View {
        HStack(spacing: 10) {
            toolbarChipButton(systemName: "chevron.down", action: closePreview)

            Spacer()

            similarityBadge

            toolbarActionGroup
        }
    }

    @ViewBuilder
    var bottomControls: some View {
        if isMetadataVisible {
            metadataPanel
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            swipeHint
        }
    }

    var swipeHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up")
                .font(.caption.bold())
            Text("Swipe up for photo details")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white.opacity(0.96))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(Color.white.opacity(0.06)).interactive(), in: .capsule)
        .glassEffectID("metadata-panel", in: glassNamespace)
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isMetadataVisible = true
            }
        }
    }

    var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Photo Info")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Swipe down to dismiss")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 14) {
                infoRow(
                    title: "Captured",
                    value: {
                        guard let creationDate = metadata?.creationDate else {
                            return "Unknown"
                        }
                        return Self.metadataDateFormatter.string(from: creationDate)
                    }()
                )
                infoRow(
                    title: "Location",
                    value: metadata?.locationName ?? "Unknown"
                )

                if let coordinate = metadata?.coordinateText {
                    infoRow(title: "Coordinates", value: coordinate)
                }

                if let metadata {
                    infoRow(
                        title: "Resolution",
                        value: "\(metadata.pixelWidth) x \(metadata.pixelHeight)"
                    )
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassEffect(.regular.tint(Color.white.opacity(0.08)).interactive(), in: .rect(cornerRadius: 28))
        .glassEffectID("metadata-panel", in: glassNamespace)
        .onTapGesture {
            // Consume taps so they do not fall through to the image view beneath.
        }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height > 60 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isMetadataVisible = false
                        }
                    }
                }
        )
    }

    func infoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var similarityBadge: some View {
        Text(String(format: "%.2f", galleryImage.similarityScore))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(Color.white.opacity(0.06)), in: .capsule)
    }

    var toolbarActionGroup: some View {
        HStack(spacing: 16) {
            toolbarIconButton(systemName: "square.and.arrow.up", action: shareCurrentPhoto)
                .disabled(shareImage == nil)
                .opacity(shareImage == nil ? 0.45 : 1)

            toolbarIconButton(
                systemName: isMetadataVisible ? "info.circle.fill" : "info.circle",
                action: toggleMetadata
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(Color.white.opacity(0.06)).interactive(), in: .capsule)
    }

    func toolbarChipButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Capsule())
                .glassEffect(.regular.tint(Color.white.opacity(0.06)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    func toolbarIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var previewGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isAtMinimumZoom else { return }
                let vertical = value.translation.height
                let horizontal = abs(value.translation.width)
                guard abs(vertical) > horizontal else { return }
                if vertical > 0 {
                    verticalDragOffset = vertical
                }
            }
            .onEnded { value in
                guard isAtMinimumZoom else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        verticalDragOffset = 0
                    }
                    return
                }

                let vertical = value.translation.height
                let predicted = value.predictedEndTranslation.height

                if isMetadataVisible, vertical > 50 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isMetadataVisible = false
                        verticalDragOffset = 0
                    }
                    return
                }

                if vertical > 120 || predicted > 180 {
                    closePreview()
                    return
                }

                if vertical < -90 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isMetadataVisible = true
                    }
                }

                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    verticalDragOffset = 0
                }
            }
    }

    func closePreview() {
        dismiss()
    }

    func toggleMetadata() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isMetadataVisible.toggle()
        }
    }

    func shareCurrentPhoto() {
        guard let shareImage else { return }
        sharePayload = SharePayload(image: shareImage)
    }

    func loadPhotoDetails(for size: CGSize) async {
        let scale = max(displayScale, 1)
        let targetSize = CGSize(
            width: max(size.width * scale, 1200),
            height: max(size.height * scale, 1200)
        )

        async let previewImage = photoLibraryService.loadUIImageForPreview(
            localIdentifier: galleryImage.sourceId,
            targetSize: targetSize
        )
        async let photoMetadata = photoLibraryService.loadMetadata(localIdentifier: galleryImage.sourceId)

        let (loadedPreviewImage, loadedMetadata) = await (previewImage, photoMetadata)
        if let loadedPreviewImage {
            displayImage = loadedPreviewImage
        }
        metadata = loadedMetadata
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

// MARK: - ZoomableImageView

struct ZoomableImageView: UIViewControllerRepresentable {
    let image: UIImage
    @Binding var isAtMinimumZoom: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtMinimumZoom: $isAtMinimumZoom)
    }

    func makeUIViewController(context: Context) -> ZoomableImageViewController {
        let vc = ZoomableImageViewController()
        vc.image = image
        vc.onZoomScaleChanged = { isMinimum in
            DispatchQueue.main.async {
                context.coordinator.update(isAtMinimumZoom: isMinimum)
            }
        }
        return vc
    }
    
    func updateUIViewController(_ uiViewController: ZoomableImageViewController, context: Context) {
        uiViewController.onZoomScaleChanged = { isMinimum in
            DispatchQueue.main.async {
                context.coordinator.update(isAtMinimumZoom: isMinimum)
            }
        }

        if uiViewController.image != image {
            uiViewController.image = image
            uiViewController.updateImage()
        }
    }

    final class Coordinator {
        private var isAtMinimumZoom: Binding<Bool>

        init(isAtMinimumZoom: Binding<Bool>) {
            self.isAtMinimumZoom = isAtMinimumZoom
        }

        func update(isAtMinimumZoom: Bool) {
            guard self.isAtMinimumZoom.wrappedValue != isAtMinimumZoom else { return }
            self.isAtMinimumZoom.wrappedValue = isAtMinimumZoom
        }
    }
}

class ZoomableImageViewController: UIViewController, UIScrollViewDelegate {
    var image: UIImage?
    var scrollView: UIScrollView!
    var imageView: UIImageView!
    var onZoomScaleChanged: ((Bool) -> Void)?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never // We handle our own insets/centering
        view.addSubview(scrollView)
        
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        
        // Add double tap to zoom
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateImage()
    }
    
    func updateImage() {
        guard let image = image else { return }
        
        // Reset image view frame to image size
        imageView.transform = .identity
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size
        
        updateZoomScales()
        centerImage()
        notifyZoomScaleChanged()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Update scales on rotation/resize
        // We only reset zoom if we are at the minimum (i.e. not zoomed in by user)
        // or if scales haven't been set yet.
        
        if scrollView.zoomScale == scrollView.minimumZoomScale {
            updateZoomScales()
        }
        centerImage()
        notifyZoomScaleChanged()
    }
    
    func updateZoomScales() {
        guard let image = image else { return }
        let boundsSize = view.bounds.size
        if boundsSize.width == 0 || boundsSize.height == 0 { return }
        
        let xScale = boundsSize.width / image.size.width
        let yScale = boundsSize.height / image.size.height
        let minScale = min(xScale, yScale)
        
        // If image is smaller than screen, we might want max scale to be at least 1.0 or bigger
        // Standard behavior: minScale is "fit", maxScale gives some reasonable zoom (e.g. 5x)
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = max(minScale * 5.0, 3.0)
        
        scrollView.zoomScale = minScale
        notifyZoomScaleChanged()
    }
    
    func centerImage() {
        let boundsSize = scrollView.bounds.size
        var frameToCenter = imageView.frame
        
        // Center horizontally
        if frameToCenter.size.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2.0
        } else {
            frameToCenter.origin.x = 0
        }
        
        // Center vertically
        if frameToCenter.size.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2.0
        } else {
            frameToCenter.origin.y = 0
        }
        
        imageView.frame = frameToCenter
    }
    
    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            scrollView.setZoomScale(scrollView.maximumZoomScale, animated: true)
        }
    }
    
    // MARK: - UIScrollViewDelegate
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        notifyZoomScaleChanged()
    }

    private func notifyZoomScaleChanged() {
        guard scrollView != nil else { return }
        let isAtMinimum = abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.0001
        onZoomScaleChanged?(isAtMinimum)
    }
}
