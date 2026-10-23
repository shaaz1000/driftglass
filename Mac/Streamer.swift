import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Captures the main display with ScreenCaptureKit and encodes it with the hardware HEVC
/// encoder. Frames are paced by acknowledgements from the phone: when too many are in
/// flight the newest capture is parked and sent as soon as the phone catches up, so a slow
/// network adds no lag, it only lowers the frame rate, and the last change always arrives.
final class Streamer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFormat: ((Data) -> Void)?
    var onFrame: ((UInt32, Data) -> Void)?
    var onStats: ((Double) -> Void)?

    private let queue = DispatchQueue(label: "driftglass.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var bitrate = 20_000_000

    private var inFlight = 0
    private let maxInFlight = 2
    private var parked: (CVPixelBuffer, CMTime)?
    private var last: (CVPixelBuffer, CMTime)?
    private var wantKeyframe = true
    private var seq: UInt32 = 0
    private var sentParams: Data?
    private var frameTimes: [CFTimeInterval] = []

    func start(bitrate: Int) async throws {
        queue.sync { self.bitrate = bitrate; self.reset() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "Driftglass", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int(CGFloat(display.width) * scale) & ~1
        let height = Int(CGFloat(display.height) * scale) & ~1

        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.capturesAudio = false

        queue.sync { makeEncoder(width: width, height: height) }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        queue.async {
            if let session = self.session { VTCompressionSessionInvalidate(session) }
            self.session = nil
            self.reset()
        }
    }

    func ack() {
        queue.async {
            self.inFlight = max(0, self.inFlight - 1)
            if let p = self.parked, self.inFlight < self.maxInFlight {
                self.parked = nil
                self.encode(p.0, p.1)
            }
        }
    }

    func requestKeyframe() {
        queue.async {
            self.wantKeyframe = true
            self.inFlight = 0
            // The screen may be idle, producing no new captures: re-encode the last one.
            if let l = self.parked ?? self.last { self.parked = nil; self.encode(l.0, l.1) }
        }
    }

    private func reset() {
        inFlight = 0; parked = nil; last = nil; wantKeyframe = true; sentParams = nil; frameTimes = []
    }

    // MARK: capture

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = sb.imageBuffer else { return }
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        let pts = sb.presentationTimeStamp
        last = (pb, pts)
        if inFlight >= maxInFlight {
            parked = (pb, pts)
            return
        }
        encode(pb, pts)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Driftglass capture stopped: \(error.localizedDescription)")
    }

    // MARK: encode

    private func makeEncoder(width: Int, height: Int) {
        if let session { VTCompressionSessionInvalidate(session) }
        var s: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                   codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard let s else { return }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 8 * 2, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 3600,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 60,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_MaximizePowerEfficiency: false,
        ]
        VTSessionSetProperties(s, propertyDictionary: props as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    private func encode(_ pb: CVPixelBuffer, _ pts: CMTime) {
        guard let session else { return }
        let opts: CFDictionary? = wantKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        wantKeyframe = false
        inFlight += 1
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: opts, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self else { return }
            self.queue.async {
                guard status == noErr, let sb else { self.inFlight = max(0, self.inFlight - 1); return }
                self.emit(sb)
            }
        }
    }

    private func emit(_ sb: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if isKey, let fd = sb.formatDescription, let params = parameterSets(fd), params != sentParams {
            sentParams = params
            onFormat?(params)
        }
        guard let block = sb.dataBuffer else { return }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        seq &+= 1
        onFrame?(seq, data)

        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        onStats?(Double(frameTimes.count))
    }

    private func parameterSets(_ fd: CMFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil) == noErr else { return nil }
        var out = Data([UInt8(count)])
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                               nalUnitHeaderLengthOut: nil)
            guard let ptr else { return nil }
            out.appendU16(UInt16(size))
            out.append(ptr, count: size)
        }
        return out
    }
}
