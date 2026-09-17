These utilites focus on Deepfly DF10 Pro car dashcam, but it may work with others too.

Installation

Download source code ZIP file, extract to a folder, and use .bat files.

=================================
Merge Dashcam videos.bat
=================================

Merges successive dashcam videos without reencoding (mostly). This is done by comparing
overlapping frames and reencoding a tiny part.

The resulting video should have smooth playback without any skipping.

Features

- You can directly supply videos in SD card.
- Sorts dragged files by parsed filename and if cannot, falls back to file name or modification date.
- Detects overlapping frames using hashes and creates smooth video transitions at merge points.
- Repairs short audio gaps by extending the final few seconds of audio without changing its pitch.
- Includes available audio by default.
- Provides an option to exclude audio.
- Handles files without audio.
- Checks free space before processing and refuses to continue when there is not enough space on the output drive or on the temp drive (usually C:).
- If the default TEMP location does not have enough free space, the script automatically tries other ready internal fixed drives for temp work files before failing.
- Sorts by parsed filename timestamp when available (using RecordingFilePrefix/EventFilePrefix patterns from config). If parsing is only partial, you can keep parsed order for recognized files and choose fallback sorting for unrecognized files, or switch fully to filename/date fallback.
- Initial input accepts either one folder or multiple files (no folder/file mixing). Folder mode scans only top-level supported video files (.avi, .mp4, .mov, .mkv).


Usage

Just follow instructions on screen. Quick overview:

- Either drag files onto the .bat file, or open the .bat file and drag files into its command window. At least two files are required.
- You may drag one folder as initial input instead of files. Subfolders are not scanned.
- If you have a large number of files (roughly 300+, depending on path length), dragging them all onto the .bat can fail silently (window closes instantly) because Windows itself imposes a hard limit on how much text Explorer can pass to a program at once. Drag the containing folder instead in that case - it counts as a single item and has no such limit.
- After the initial files are sorted, you may add event videos by dragging them into the command window. Press Enter without dragging to skip.
- The event/additional input step accepts files only (folders are rejected in that step).
- Audio inclusion will then be asked.
- Input order is decided before processing: parse-first sort, otherwise one-time fallback choice (filename or modified date).
- The destination choices are the last folder (default), the folder containing the videos, or Browse. The last selected folder is remembered for the next job.
- If you choose "Same folder as videos", output is written to a "Merged Videos" subfolder in that source folder.
- After selecting destination, a storage pre-check runs and merge stops if output or temp free space is insufficient.
- Press Enter at the audio question to include audio.

A report will be written to a file named after the merged video in the target folder.


Limitations

- G Sensor data is not preserved.
- Rear video channel is not preserved. It would make merged video much larger.


Configuration

- MergeDashcam.config.psd1 is a text configuration file. Open it with any text editor to change settings.
- Keep the configuration file in the same folder as MergeDashcam.ps1.
- FrameRate controls the playback rate of the merged video. The default is 30 fps.
- FrameRateWarningDifference controls when an input frame-rate warning is shown.
- RecordingFilePrefix and EventFilePrefix identify Deepfly DF10 recording and event files for its handoff rules.
- EnableAudioBoundaryRepair fills short audio tail gaps by stretching only the final part of the available audio without changing its pitch.
- AudioBoundaryRepairTailSeconds controls how much audio may be stretched. AudioBoundaryRepairMaximumGapSeconds limits repairs to short gaps; larger gaps retain silence.
- AudioBoundaryRepairCompensationSeconds slightly overextends repaired audio to account for FFmpeg atempo processing latency; excess audio is trimmed.
- AudioBoundaryRepairFadeSeconds applies a tiny edge fade to prevent clicks. Files without audio still receive silence normally.
- The remaining settings control parallel processing, validation, and console output.


=================================
Extract front and rear videos.bat
=================================

This batch file splits 2 video streams in DF10 dashcam recordings into two files.

Usage

- Drag file(s) to .bat file.
- Files ending with _front.avi and _rear. avi will be written in SOURCE folder.

=================================
Remove audio (create copy).bat
=================================

Strips audio from dashcam file, and saves it as a new file. Does not modify original file.

Usage

- Drag file(s) to .bat file.
- Files with -silent suffix will be created in the SOURCE folder.