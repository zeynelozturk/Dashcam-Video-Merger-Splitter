@{
    FFmpegPath                   = "ffmpeg.exe"
    FFprobePath                  = "ffprobe.exe"
    MinimumMatchFrames           = 5
    FrameRate                    = 30.0
    FrameRateWarningDifference   = 3.0
    UseParallelFrameHashing      = $true
    ParallelFrameHashWorkers     = 5
    UseParallelAudioMetadata     = $true
    ParallelAudioMetadataWorkers = 3
    QuickValidationSeconds       = 2.0
    MinimalConsoleOutput         = $true
    SuppressFFmpegConsoleOutput  = $true
}
