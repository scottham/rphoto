
import SwiftUI
import UIKit

struct ImageDetailView: View {
    let galleryImage: GalleryImage

    @Environment(\.dismiss) private var dismiss

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
                .simultaneousGesture(previewGesture)

                VStack(spacing: 0) {
                    topControls
                    Spacer()
                    bottomControls
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
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

    var topControls: some View {
        HStack(spacing: 12) {
            Button(action: closePreview) {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45))
                    .clipShape(Circle())
            }

            Spacer()

            Text(String(format: "%.2f", galleryImage.similarityScore))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())

            Button(action: shareCurrentPhoto) {
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .disabled(shareImage == nil)
            .opacity(shareImage == nil ? 0.45 : 1)

            Button(action: toggleMetadata) {
                Image(systemName: isMetadataVisible ? "info.circle.fill" : "info.circle")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45))
                    .clipShape(Circle())
            }
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
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45))
        .clipShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isMetadataVisible = true
            }
        }
    }

    var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(.secondary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            Text("Photo Info")
                .font(.headline)

            Divider()

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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
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
        let scale = UIScreen.main.scale
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
