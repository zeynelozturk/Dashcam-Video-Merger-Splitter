@{
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
    AudioBoundaryRepairFadeSeconds = 0.002
    QuickValidationSeconds       = 2.0
    MinimalConsoleOutput         = $true
    SuppressFFmpegConsoleOutput  = $true
}
