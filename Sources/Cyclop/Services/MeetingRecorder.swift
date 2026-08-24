import AVFoundation
import AppKit
import ScreenCaptureKit

/// Records a meeting: what the Mac plays and what the microphone hears.
///
/// Both halves come out of one ScreenCaptureKit stream — macOS 15 grew a
/// microphone tap on it — so there is no second capture session to keep in
/// step and both sides carry timestamps from the same clock. They are written
/// as two tracks and mixed down to one only when the recording stops: mixing
/// two live streams means resampling and drift correction, while keeping them
/// apart until the end costs nothing and lets AVFoundation do the mixing
/// offline, where it is a solved problem.
///
/// Nothing here starts on its own. Recording begins on the button that says so
/// and ends on the button that says so, and while it runs the menu bar icon is
/// a red dot — macOS shows its own indicators too, but this app's own switch
/// deserves to be visible in this app.
@MainActor
final class MeetingRecorder: ObservableObject {
    struct Session {
        /// What is being recorded, which is not always what the agenda is
        /// showing: a recording outlives the meeting that started it.
        let title: String
        let started: Date
    }

    @Published private(set) var session: Session?
    /// Whether the recording has outlived the meeting it was started for. Kept
    /// here rather than in the peek it raises: the panel is rebuilt whenever a
    /// display is plugged in, and a red row with the only Stop button in it
    /// must not be what a second monitor costs.
    @Published private(set) var overran = false
    /// Why the last attempt did not start, in words meant for the pane.
    @Published private(set) var failure: String?
    /// Called when the meeting's scheduled end has passed and the recording is
    /// still going — the panel comes down and asks. An event, like
    /// `CalendarStore.onAlert`, and kept out of the published state for the
    /// same reason.
    var onMeetingEnded: (() -> Void)?

    private var stream: SCStream?
    private var sink: AudioSink?
    private var endWatch: Timer?
    /// Between the press and the first sample there are two permission
    /// prompts, and the button stays on screen for all of them: `session` is
    /// only set once the stream is actually running. Without this, a second
    /// press on a button that looks like it did nothing starts a second stream
    /// — and the first one is overwritten here, so nothing ever stops it.
    private var starting = false

    var isRecording: Bool { session != nil }

    /// How long it has been going. Computed on the way out rather than kept
    /// fresh by a clock: the pills that show it count on their own, and the
    /// menu bar asks only when the menu opens. A ticking `@Published` would
    /// have woken the run loop and re-rendered the panel once a second for an
    /// hour, for a number nobody was looking at.
    var elapsed: TimeInterval {
        session.map { Date().timeIntervalSince($0.started) } ?? 0
    }

    /// Where the files land. Its own folder rather than Movies or Downloads:
    /// everything else Cyclop keeps lives here, and a recording is the app's
    /// own file until someone drags it out.
    static var folder: URL { Support.directory("Recordings") }

    static func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    // MARK: - Start

    func start(for meeting: CalendarStore.Meeting) {
        start(title: meeting.title, stamp: meeting.start, endingAt: meeting.end)
    }

    /// Records something that is not in the calendar at all — a call that
    /// started in a chat, a conversation nobody scheduled. The same recording
    /// in every other respect: what is being written does not depend on
    /// whether an event exists for it, and the half of the calls one actually
    /// wants kept are the ones nobody sent an invitation for.
    ///
    /// `end` is only the moment to come and ask, so an unscheduled recording
    /// simply has nobody to ask on its behalf — it runs until it is stopped.
    func start(title: String, stamp: Date = Date(), endingAt end: Date? = nil) {
        guard session == nil, !starting else { return }
        starting = true
        Task { await begin(title: title, stamp: stamp, endingAt: end) }
    }

    private func begin(title: String, stamp: Date, endingAt end: Date?) async {
        defer { starting = false }
        failure = nil

        // Asked first, and separately, because the two permissions fail
        // differently. A microphone that is refused still leaves a usable
        // recording of the call itself, so it is not a reason to stop.
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)

        // System audio rides on the screen recording permission. Its prompt is
        // shown once per app and never again, and a grant given while the app
        // is running is not picked up until it restarts — so there is no
        // waiting for an answer here, only saying where the switch is.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            failure = localized("Allow Cyclop in Settings → Privacy → Screen & System Audio Recording, then restart it")
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                failure = localized("No display to capture audio from")
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = AudioSink.systemSampleRate
            configuration.channelCount = AudioSink.systemChannels
            // Cyclop plays nothing, but a stream that captured its own process
            // would loop anything it ever did.
            configuration.excludesCurrentProcessAudio = true
            configuration.captureMicrophone = microphone
            // A stream always captures a picture; this one is asked for the
            // smallest and slowest picture there is, and nothing ever reads it.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 6

            let url = Self.url(title: title, stamp: stamp)
            let sink = AudioSink(url: url, wantsMicrophone: microphone)
            sink.onFailure = { [weak self] message in
                Task { @MainActor in self?.streamDied(message) }
            }

            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: configuration,
                                  delegate: sink)
            // The picture is subscribed to and thrown away. An audio-only
            // stream is legal, but one with no output attached at all has been
            // known to stop itself the moment it starts.
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            if microphone {
                try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
            }
            try await stream.startCapture()

            self.stream = stream
            self.sink = sink
            session = Session(title: title, started: Date())
            overran = false
            if let end { watchForEnd(end) }
        } catch {
            failure = error.localizedDescription
            stream = nil
            sink = nil
        }
    }

    /// The stream ended without being asked — the display went away, the
    /// permission was revoked mid-call. Whatever was written is kept.
    private func streamDied(_ message: String) {
        guard session != nil else { return }
        stop(mix: true)
        failure = message
    }

    // MARK: - Stop

    /// `mix` is what quitting turns off: flattening a two-hour recording takes
    /// its own seconds, and those are seconds the app is being asked to spend
    /// on the way out. The two-track file lands under the final name instead —
    /// it plays, it is just two tracks.
    func stop(mix: Bool = true, completion: (@Sendable () -> Void)? = nil) {
        guard session != nil else {
            completion?()
            return
        }
        let stream = self.stream
        let sink = self.sink
        self.stream = nil
        self.sink = nil
        session = nil
        overran = false
        endWatch?.invalidate()
        endWatch = nil

        Task.detached {
            try? await stream?.stopCapture()
            await sink?.finish(mix: mix)
            completion?()
        }
    }

    // MARK: - Timers

    /// One shot at the meeting's scheduled end. Nothing stops there: meetings
    /// run over, and cutting a recording mid-sentence is worse than one that
    /// runs long. The panel comes down and asks, and "keep going" is simply
    /// not pressing the button.
    private func watchForEnd(_ end: Date) {
        endWatch?.invalidate()
        guard end > Date() else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session != nil else { return }
                self.overran = true
                self.onMeetingEnded?()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        endWatch = timer
    }

    // MARK: - Naming

    /// Pinned to POSIX like every other stamp the app writes into a file name
    /// (`ScreenshotVault.stamp`): a locale with its own digits would otherwise
    /// name the files in them.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()

    /// Sortable date first, then the meeting. Slashes and colons are what a
    /// file name cannot hold; a title is free to contain both.
    ///
    /// Uniqued the same way screenshots are, and for a sharper reason: the same
    /// meeting recorded twice — a call rejoined after it dropped — would land
    /// on the same name, and the writer opens it by deleting what is there.
    private static func url(title: String, stamp when: Date) -> URL {
        let title = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(stamp.string(from: when)) \(title.isEmpty ? localized("Meeting") : title)"
        var url = folder.appendingPathComponent("\(base).m4a")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(attempt)).m4a")
            attempt += 1
        }
        return url
    }
}

/// Everything that touches sample buffers, off the main thread.
///
/// Buffers arrive on the capture queue many times a second and go straight
/// into an encoder; hopping to the main actor for each one would put the
/// panel's own thread in the path of a recording that must not glitch.
final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let systemSampleRate = 48_000
    static let systemChannels = 2

    let queue = DispatchQueue(label: "com.cyclop.recorder.audio")

    /// Called if the stream stops on its own.
    var onFailure: ((String) -> Void)?

    private let finalURL: URL
    private let workingURL: URL
    private let wantsMicrophone: Bool

    private var writer: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    /// When system audio first arrived. If the microphone has still said
    /// nothing a couple of seconds later, it is not going to — a device can be
    /// present, permitted and silent — and the recording starts without it
    /// rather than waiting forever for a track that will never open.
    private var firstSystemAudio: Date?
    private var finished = false

    init(url: URL, wantsMicrophone: Bool) {
        self.finalURL = url
        // Written under a different name, because what is written live is a
        // two-track file and what the folder should end up holding is not.
        self.workingURL = url.deletingPathExtension().appendingPathExtension("tracks.m4a")
        self.wantsMicrophone = wantsMicrophone
        super.init()
        try? FileManager.default.removeItem(at: workingURL)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error.localizedDescription)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, CMSampleBufferDataIsReady(buffer) else { return }
        switch type {
        case .audio: handleSystem(buffer)
        case .microphone: handleMicrophone(buffer)
        default: break  // the 2×2 picture, subscribed to and dropped
        }
    }

    private func handleSystem(_ buffer: CMSampleBuffer) {
        let first = firstSystemAudio ?? Date()
        firstSystemAudio = first
        if writer == nil {
            // Waiting on the microphone's first buffer, which is what names its
            // format — the writer's inputs cannot be added after it starts.
            guard !wantsMicrophone || Date().timeIntervalSince(first) > 2 else { return }
            start(microphoneFormat: nil, at: buffer.presentationTimeStamp)
        }
        append(buffer, to: systemInput)
    }

    private func handleMicrophone(_ buffer: CMSampleBuffer) {
        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(buffer) else { return }
            start(microphoneFormat: format, at: buffer.presentationTimeStamp)
        }
        append(buffer, to: microphoneInput)
    }

    private func start(microphoneFormat: CMFormatDescription?, at time: CMTime) {
        do {
            let writer = try AVAssetWriter(outputURL: workingURL, fileType: .m4a)

            let system = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.aac(sampleRate: Double(Self.systemSampleRate), channels: Self.systemChannels)
            )
            system.expectsMediaDataInRealTime = true
            guard writer.canAdd(system) else { throw RecorderError.cannotWrite }
            writer.add(system)
            systemInput = system

            // The microphone's own rate and channel count, read off its first
            // buffer. The AAC encoder converts neither: handed a mono 44.1 kHz
            // buffer against stereo 48 kHz settings it refuses the sample and
            // fails the whole file.
            if let microphoneFormat,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(microphoneFormat)?.pointee {
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: Self.aac(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
                )
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    microphoneInput = input
                }
            }

            guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotWrite }
            writer.startSession(atSourceTime: time)
            sessionStart = time
            self.writer = writer
        } catch {
            NSLog("Cyclop: recording could not start — \(error.localizedDescription)")
            onFailure?(error.localizedDescription)
            finished = true
        }
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let writer, let input, writer.status == .writing else { return }
        // The two taps open a fraction of a second apart, so the first buffers
        // of the later one can predate the session. They belong to a moment the
        // file does not have.
        guard let sessionStart, buffer.presentationTimeStamp >= sessionStart else { return }
        guard input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    // MARK: - Finish

    /// Closes the file. The first half runs back on the capture queue, because
    /// that is the thread the writer has been touched from all along and a
    /// stopped stream is not a promise that its last buffer has landed.
    func finish(mix: Bool) async {
        let writer: AVAssetWriter? = await withCheckedContinuation { continuation in
            queue.async {
                guard !self.finished, let writer = self.writer else {
                    self.finished = true
                    continuation.resume(returning: nil)
                    return
                }
                self.finished = true
                self.systemInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                continuation.resume(returning: writer)
            }
        }
        guard let writer else { return }
        await writer.finishWriting()
        guard writer.status == .completed else {
            NSLog("Cyclop: recording failed — \(writer.error?.localizedDescription ?? "unknown")")
            return
        }
        if mix {
            await mixdown()
        } else {
            try? FileManager.default.moveItem(at: workingURL, to: finalURL)
        }
    }

    /// Two tracks into one. An export with the M4A preset flattens every audio
    /// track it is given into a single mixed one, which is what anything that
    /// plays or transcribes the file expects to find. If it fails, the
    /// two-track file is kept under the final name rather than thrown away —
    /// it plays, it is just two tracks.
    private func mixdown() async {
        let asset = AVURLAsset(url: workingURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            try? FileManager.default.moveItem(at: workingURL, to: finalURL)
            return
        }
        do {
            try await export.export(to: finalURL, as: .m4a)
            try? FileManager.default.removeItem(at: workingURL)
        } catch {
            NSLog("Cyclop: mixdown failed — \(error.localizedDescription)")
            try? FileManager.default.moveItem(at: workingURL, to: finalURL)
        }
    }

    private static func aac(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: max(1, channels),
            AVEncoderBitRateKey: channels > 1 ? 128_000 : 64_000,
        ]
    }

    enum RecorderError: LocalizedError {
        case cannotWrite
        var errorDescription: String? { localized("Could not open the recording file") }
    }
}
