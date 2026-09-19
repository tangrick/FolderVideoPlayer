import CoreGraphics
import Foundation

/// Landmarks → the 112×112 crop SFace recognises.
///
/// This is the step the whole face feature is calibrated on. `FACE_MATCH_COSINE
/// = 0.30` was tuned against crops made this way (pitfall 28: the maintainer's real
/// cross-video faces peak at 0.326, against a different-person floor around
/// 0.1–0.2), so the crop has to come out the same as the engine's
/// `cv2.FaceRecognizerSF.alignCrop` did. It does: this transform reproduces
/// `alignCrop` to **cosine 0.9999995** on real faces, measured in
/// `docs/coreml-spike/face_align_parity.py`.
///
/// Two details are not arbitrary and were both measured:
///
///   - **The template** is the ArcFace 5-point template at 112×112, in the order
///     YuNet's own five landmarks come in (right eye, left eye, nose, right
///     mouth, left mouth — whatever the template calls them, the pairing is
///     point-for-point). Swapping the eye pair to match the template's
///     left-first naming is *worse*: cosine 0.16 against `alignCrop` versus 0.98.
///   - **Umeyama, not a least-squares affine.** The fit is a similarity
///     transform — uniform scale, rotation, translation, and **no reflection**.
///     A reflection in the middle is the classic way to get a mirrored face crop
///     that still looks plausible in a thumbnail.
/// One aligned face, in the two forms the rest of the feature needs.
///
/// The crop is produced once and handed over twice because the **cache key is a
/// hash of the pixels**: `engine.py` did `sha256(aligned.tobytes())[:32]`, where
/// `aligned` is a `(112, 112, 3)` BGR array — packed, three bytes per pixel, no
/// row padding. A `CGImage` on its own cannot be hashed to that, which is why
/// `bgr` is carried alongside rather than re-derived by drawing the image into
/// a buffer and hoping the stride matches.
struct AlignedCrop {
    /// For the embedder and for the thumbnail that goes on disk.
    let image: CGImage
    /// 112×112×3, BGR, top row first. What `FaceRegistry` hashes.
    let bgr: [UInt8]
}

enum FaceAlignment {

    /// The canonical five points at 112×112: (38.2946, 51.6963), (73.5318, 51.5014),
    /// (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041).
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]
    /// The crop side the model was converted for, and the template's scale.
    static let side = 112

    /// The similarity transform taking `landmarks` onto the template.
    ///
    /// Umeyama's closed form: centres, the cross-covariance of the centred
    /// point sets, an SVD of that 2×2 matrix, and a determinant check that
    /// forbids the reflection. Two dimensions, so the SVD is analytical — no
    /// Accelerate call is worth a dependency here.
    static func matrix(landmarks: [CGPoint]) -> CGAffineTransform? {
        guard landmarks.count == template.count else { return nil }
        let n = Double(landmarks.count)

        let sourceMean = mean(landmarks)
        let targetMean = mean(template)
        let source = landmarks.map { CGPoint(x: $0.x - sourceMean.x, y: $0.y - sourceMean.y) }
        let target = template.map { CGPoint(x: $0.x - targetMean.x, y: $0.y - targetMean.y) }

        // A = (1/n) Σ target·sourceᵀ — the 2×2 cross-covariance.
        var a11 = 0.0, a12 = 0.0, a21 = 0.0, a22 = 0.0
        for i in 0..<landmarks.count {
            a11 += target[i].x * source[i].x
            a12 += target[i].x * source[i].y
            a21 += target[i].y * source[i].x
            a22 += target[i].y * source[i].y
        }
        a11 /= n; a12 /= n; a21 /= n; a22 /= n

        // Analytical 2×2 SVD: A = U Σ Vᵀ via the eigen-decomposition of AᵀA.
        let ata11 = a11 * a11 + a21 * a21
        let ata12 = a11 * a12 + a21 * a22
        let ata22 = a12 * a12 + a22 * a22
        let trace = ata11 + ata22
        let determinant = ata11 * ata22 - ata12 * ata12
        let discriminant = max((trace * trace / 4) - determinant, 0).squareRoot()
        let l1 = trace / 2 + discriminant
        let l2 = max(trace / 2 - discriminant, 0)
        // Eigenvector for l1.
        var v1 = CGPoint(x: ata12, y: l1 - ata11)
        if abs(v1.x) < 1e-12 && abs(v1.y) < 1e-12 { v1 = CGPoint(x: 1, y: 0) }
        let v1Length = (v1.x * v1.x + v1.y * v1.y).squareRoot()
        v1 = CGPoint(x: v1.x / v1Length, y: v1.y / v1Length)
        let v2 = CGPoint(x: -v1.y, y: v1.x)

        let s1 = l1.squareRoot(), s2 = l2.squareRoot()
        // U = A V Σ⁻¹, guarding a degenerate second singular value.
        var u1 = CGPoint(x: (a11 * v1.x + a12 * v1.y) / max(s1, 1e-12),
                         y: (a21 * v1.x + a22 * v1.y) / max(s1, 1e-12))
        let u1Length = (u1.x * u1.x + u1.y * u1.y).squareRoot()
        if u1Length > 1e-12 { u1 = CGPoint(x: u1.x / u1Length, y: u1.y / u1Length) }
        let u2 = CGPoint(x: -u1.y, y: u1.x)

        // No reflection: if det(U)·det(V) < 0 the second singular value flips.
        //
        // `d` is ±1, NOT the singular values — they are already folded into `T`
        // by construction (`T = U diag(d) Vᵀ` is orthogonal), which is what
        // makes `scale` the whole of the scaling. Putting the singular values
        // in `d` as well scales the transform by ~s₁ a second time: on the
        // synthetic landmark set below that turned a 0.69 scale into 265.
        let detU = u1.x * u2.y - u2.x * u1.y
        let detV = v1.x * v2.y - v2.x * v1.y
        let flip = detU * detV < 0
        let d1 = 1.0, d2 = flip ? -1.0 : 1.0

        var r11 = u1.x * d1 * v1.x + u2.x * d2 * v2.x
        var r12 = u1.x * d1 * v1.y + u2.x * d2 * v2.y
        var r21 = u1.y * d1 * v1.x + u2.y * d2 * v2.x
        var r22 = u1.y * d1 * v1.y + u2.y * d2 * v2.y

        let variance = source.reduce(0.0) { $0 + $1.x * $1.x + $1.y * $1.y } / n
        guard variance > 0 else { return nil }
        let scale = (s1 * d1 + s2 * d2) / variance
        r11 *= scale; r12 *= scale; r21 *= scale; r22 *= scale

        return CGAffineTransform(
            a: r11, b: r21, c: r12, d: r22,
            tx: targetMean.x - (r11 * sourceMean.x + r12 * sourceMean.y),
            ty: targetMean.y - (r21 * sourceMean.x + r22 * sourceMean.y))
    }

    /// The aligned crop, or nil when the landmarks cannot produce one.
    ///
    /// **A hand-written bilinear warp, not `CGContext.draw`.** This is the one
    /// computation `FACE_MATCH_COSINE = 0.30` rests on, and Core Graphics will
    /// not reproduce it: a close-up face is a ~4× downscale, where every CG
    /// interpolation quality is a wide kernel doing real prefiltering, while
    /// `cv2.warpAffine` at `INTER_LINEAR` taps a flat 2×2. Measured against
    /// `cv2.alignCrop`'s own crop, the minimum cosine over 12 faces is 0.969
    /// at `.high` and 0.983 at `.low` — with a margin of 0.026 between the same
    /// person and a different one, that is not a rounding difference, it is a
    /// different feature. Matching the *algorithm* instead of the framework is
    /// what takes it to 0.9999.
    ///
    /// Two conventions are OpenCV's, and neither is Core Graphics':
    ///
    ///   - **Coordinates are pixel indices in both images**, so there is no
    ///     half-pixel offset anywhere. Drawing the image into a rect maps its
    ///     `[0, W] × [0, H]` extent onto the rect, which puts pixel *centres* at
    ///     +0.5 — a half-pixel shift that costs ~0.02 cosine by itself.
    ///   - **Outside the source is 0**, matching `borderValue = 0`. SFace reads
    ///     pixels, not alpha, so a transparent border would composite
    ///     differently from the engine's black one.
    static func align(_ image: CGImage, landmarks: [CGPoint]) -> AlignedCrop? {
        guard let transform = matrix(landmarks: landmarks),
              let source = pixels(image) else { return nil }
        let sourceWidth = image.width
        let sourceHeight = image.height
        // `warpAffine` is given the forward map and walks the destination, so
        // the sampling transform is the inverse.
        let inverse = CGAffineTransformInvert(transform)

        var bgr = [UInt8](repeating: 0, count: side * side * 3)
        var pixels32 = [UInt8](repeating: 255, count: side * side * 4)
        for v in 0..<side {
            for u in 0..<side {
                let x = inverse.a * CGFloat(u) + inverse.c * CGFloat(v) + inverse.tx
                let y = inverse.b * CGFloat(u) + inverse.d * CGFloat(v) + inverse.ty
                let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
                let fx = Double(x - CGFloat(x0)), fy = Double(y - CGFloat(y0))
                let flat = (v * side + u)
                for channel in 0..<3 {
                    let top = sample(source, sourceWidth, sourceHeight,
                                     x0, y0, channel) * (1 - fx)
                        + sample(source, sourceWidth, sourceHeight,
                                 x0 + 1, y0, channel) * fx
                    let bottom = sample(source, sourceWidth, sourceHeight,
                                        x0, y0 + 1, channel) * (1 - fx)
                        + sample(source, sourceWidth, sourceHeight,
                                 x0 + 1, y0 + 1, channel) * fx
                    let value = UInt8(min(max((top * (1 - fy) + bottom * fy).rounded(), 0), 255))
                    bgr[flat * 3 + channel] = value
                    pixels32[flat * 4 + channel] = value
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels32) as CFData) else { return nil }
        guard let image = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) else { return nil }
        return AlignedCrop(image: image, bgr: bgr)
    }

    /// Just the image, for callers that do not key a cache with it.
    static func crop(_ image: CGImage, landmarks: [CGPoint]) -> CGImage? {
        align(image, landmarks: landmarks)?.image
    }

    /// One channel of one source pixel, or 0 outside the image.
    private static func sample(_ source: [UInt8], _ width: Int, _ height: Int,
                               _ x: Int, _ y: Int, _ channel: Int) -> Double {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return Double(source[(y * width + x) * 4 + channel])
    }

    /// A CGImage as BGRA bytes, top row first — the same buffer the detector
    /// samples, so a frame reaches the crop without a second colour pipeline.
    static func pixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func mean(_ points: [CGPoint]) -> CGPoint {
        var x = 0.0, y = 0.0
        for p in points { x += p.x; y += p.y }
        return CGPoint(x: x / Double(points.count), y: y / Double(points.count))
    }
}
