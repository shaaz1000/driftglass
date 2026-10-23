// Tiny media helper for the Driftglass launch assets (no ffmpeg needed).
//   media info   <video>
//   media frames <video> <outdir> <count>
//   media blur   <in> <out> <cx> <cy> <r> [<cx> <cy> <r> ...]   normalised, top-left origin, r in widths
//   media blurimg <in.png> <out.png> <cx> <cy> <r> [...]
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let ctx = CIContext()

func spots(_ a: ArraySlice<String>) -> [(Double, Double, Double)] {
    let v = a.compactMap(Double.init)
    return stride(from: 0, to: v.count - 2, by: 3).map { (v[$0], v[$0 + 1], v[$0 + 2]) }
}

func blur(_ img: CIImage, _ spots: [(Double, Double, Double)]) -> CIImage {
    let e = img.extent
    var out = img
    for (cx, cy, r) in spots {
        let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: max(e.width * 0.006, r * e.width * 0.6)).cropped(to: e)
        let c = CIVector(x: e.minX + cx * e.width, y: e.maxY - cy * e.height)
        let rad = r * e.width
        let mask = CIFilter.radialGradient()
        mask.center = CGPoint(x: c.x, y: c.y)
        mask.radius0 = Float(rad)
        mask.radius1 = Float(rad * 1.25)
        mask.color0 = .white
        mask.color1 = .clear
        let m = CIFilter.blendWithMask()
        m.inputImage = blurred
        m.backgroundImage = out
        m.maskImage = mask.outputImage!.cropped(to: e)
        out = m.outputImage!.cropped(to: e)
    }
    return out
}

func writePNG(_ img: CIImage, _ path: String) {
    let cg = ctx.createCGImage(img, from: img.extent)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    switch args[1] {
    case "info":
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
        let t = try await asset.loadTracks(withMediaType: .video)[0]
        let (size, xf, fps) = try await t.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let d = try await asset.load(.duration)
        print("size \(size) transform \(xf) fps \(fps) duration \(d.seconds)")
    case "frames":
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
        let d = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let n = Int(args[4])!
        for i in 0..<n {
            let t = CMTime(seconds: d * (Double(i) + 0.5) / Double(n), preferredTimescale: 600)
            let (cg, _) = try await gen.image(at: t)
            writePNG(CIImage(cgImage: cg), "\(args[3])/f\(String(format: "%02d", i)).png")
        }
    case "blur":
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
        let s = spots(args[4...])
        let comp = try await AVMutableVideoComposition.videoComposition(with: asset) { req in
            req.finish(with: blur(req.sourceImage, s), context: nil)
        }
        let out = URL(fileURLWithPath: args[3])
        try? FileManager.default.removeItem(at: out)
        let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)!
        ex.videoComposition = comp
        try await ex.export(to: out, as: .mp4)
        print("wrote \(out.path)")
    case "render":
        // render <in> <out> <rot: 0|l|r> <start s> <end s> spots...   (spots in output orientation)
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let natural = try await track.load(.naturalSize)
        let rot = args[4]
        let s = spots(args[7...])
        let comp = try await AVMutableVideoComposition.videoComposition(with: asset) { req in
            var img = req.sourceImage
            if rot == "l" { img = img.oriented(.left) } else if rot == "r" { img = img.oriented(.right) }
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            req.finish(with: blur(img, s), context: nil)
        }
        if rot != "0" { comp.renderSize = CGSize(width: natural.height, height: natural.width) }
        comp.frameDuration = CMTime(value: 1, timescale: 60)
        let out = URL(fileURLWithPath: args[3])
        try? FileManager.default.removeItem(at: out)
        let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)!
        ex.videoComposition = comp
        let start = CMTime(seconds: Double(args[5])!, preferredTimescale: 600)
        let end = CMTime(seconds: Double(args[6])!, preferredTimescale: 600)
        ex.timeRange = CMTimeRange(start: start, end: end)
        try await ex.export(to: out, as: .mp4)
        print("wrote \(out.path)")
    case "gif":
        // gif <video> <out.gif> <fps> <width>
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
        let d = try await asset.load(.duration).seconds
        let fps = Double(args[4])!, width = CGFloat(Double(args[5])!)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: width, height: width * 4)
        let n = Int(d * fps)
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.gif.identifier as CFString, n, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<n {
            let (cg, _) = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(dest, cg, frameProps)
        }
        CGImageDestinationFinalize(dest)
        print("wrote \(n) frames")
    case "blurimg":
        let img = CIImage(contentsOf: URL(fileURLWithPath: args[2]))!
        writePNG(blur(img, spots(args[4...])), args[3])
    default:
        print("unknown command")
    }
}
sem.wait()
