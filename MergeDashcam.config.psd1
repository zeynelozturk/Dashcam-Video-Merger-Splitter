@{
    # FFmpeg/FFprobe resolution order:
    # 1) Always check local .\ffmpeg\ffmpeg.exe and .\ffmpeg\ffprobe.exe first.
    # 2) If local files are missing, use FFmpegPath/FFprobePath below (fallback).
    #
    # FFmpegPath/FFprobePath examples:
    # - Local bundled files next to script: .\ffmpeg\ffmpeg.exe and .\ffmpeg\ffprobe.exe
    # - PATH lookup: ffmpeg.exe and ffprobe.exe
    # - Absolute paths: C:\Tools\ffmpeg\bin\ffmpeg.exe and C:\Tools\ffmpeg\bin\ffprobe.exe
    FFmpegPath                   = "ffmpeg.exe"
    FFprobePath                  = "ffprobe.exe"
    MinimumMatchFrames           = 5
    # Deepfly DF10 prefixes used for its event/recording handoff rules.
    RecordingFilePrefix          = "REC2_"
    EventFilePrefix              = "EVT2_"
    FrameRate                    = 30.0
    FrameRateWarningDifference   = 3.0
    UseParallelFrameHashing      = $true
    ParallelFrameHashWorkers     = 5
    UseParallelAudioMetadata     = $true
    ParallelAudioMetadataWorkers = 3
    EnableAudioBoundaryRepair    = $true
    AudioBoundaryRepairTailSeconds = 5.0
    AudioBoundaryRepairMaximumGapSeconds = 1.0
    AudioBoundaryRepairCompensationSeconds = 0.025
    AudioBoundaryRepairFadeSeconds = 0.002
    QuickValidationSeconds       = 2.0
    MinimalConsoleOutput         = $true
    SuppressFFmpegConsoleOutput  = $true
    # Stationary spans lasting at least this many seconds can optionally
    # be cropped out of the merged output (user is prompted at runtime).
    ParkedMinimumStationarySeconds = 180
    # Samples below this scene score count as low motion.
    ParkDetectionScoreThreshold   = 0.01
    # Classify a moment as stationary only when this fraction of samples
    # in the surrounding window are low motion. This rejects dark driving.
    ParkDetectionWindowSeconds = 60.0
    ParkDetectionStationarySampleRatio = 0.65
    # Brief spikes above threshold (e.g. pedestrians/headlight flicker)
    # are tolerated for this many seconds before splitting a parked run.
    ParkDetectionMotionSpikeToleranceSeconds = 4.0
    # Keep extra footage before parked spans so low-speed driving is not cut.
    ParkDetectionStartMarginSeconds = 30.0
    # Keep a small tail after parked spans to avoid hard boundary cuts.
    ParkDetectionEndMarginSeconds = 5.0
}
