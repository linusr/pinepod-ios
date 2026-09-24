import AVFoundation
import MediaToolbox

/// Watches an item's decoded audio through an `MTAudioProcessingTap` and
/// reports entering and leaving silence with the item time where it happens.
/// The tap runs ahead of playback, so callers should act at that time rather
/// than on receipt. Taps run for file and progressive HTTP sources, not HLS.
final class SilenceDetector: @unchecked Sendable {
    /// Buffers quieter than this RMS level (dBFS) count as silent.
    static let thresholdDB: Float = -40
    /// Silence must last this long (episode time) before it is reported. With
    /// the tap's ~0.9 s lead, only pauses of about 2 s or more get sped up;
    /// shorter ones would flip the rate for a fraction of a second, which is
    /// audible as a stumble and saves almost nothing.
    static let minimumSilence: Double = 1.0

    private let onChange: @Sendable (_ isSilent: Bool, _ at: CMTime) -> Void
    private let thresholdAmplitude = pow(10, SilenceDetector.thresholdDB / 20)

    // Touched only on the audio render thread.
    fileprivate var sampleRate: Double = 44_100
    fileprivate var isFloat32 = true
    private var silentFrames: Double = 0
    private var isSilent = false

    init(onChange: @escaping @Sendable (_ isSilent: Bool, _ at: CMTime) -> Void) {
        self.onChange = onChange
    }

    /// An audio mix that feeds `track` through this detector.
    func audioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let clientInfo = Unmanaged.passRetained(self).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<SilenceDetector>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let detector = Unmanaged<SilenceDetector>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                detector.sampleRate = format.pointee.mSampleRate
                detector.isFloat32 = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && format.pointee.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
                var timeRange = CMTimeRange.invalid
                guard MTAudioProcessingTapGetSourceAudio(
                    tap, frameCount, bufferList, flagsOut, &timeRange, frameCountOut) == noErr else { return }
                let detector = Unmanaged<SilenceDetector>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                detector.analyze(
                    UnsafeMutableAudioBufferListPointer(bufferList), frames: frameCountOut.pointee, timeRange: timeRange)
            })

        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
              let tap else {
            Unmanaged<SilenceDetector>.fromOpaque(clientInfo).release()
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private func analyze(_ buffers: UnsafeMutableAudioBufferListPointer, frames: CMItemCount, timeRange: CMTimeRange) {
        guard isFloat32, frames > 0 else { return }
        var loudest: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            var sumOfSquares: Float = 0
            for index in 0..<count {
                sumOfSquares += samples[index] * samples[index]
            }
            loudest = max(loudest, (sumOfSquares / Float(count)).squareRoot())
        }

        if loudest < thresholdAmplitude {
            silentFrames += Double(frames)
            if !isSilent, silentFrames / sampleRate >= Self.minimumSilence {
                isSilent = true
                onChange(true, timeRange.isValid ? timeRange.end : .invalid)
            }
        } else {
            silentFrames = 0
            if isSilent {
                isSilent = false
                onChange(false, timeRange.isValid ? timeRange.start : .invalid)
            }
        }
    }
}
