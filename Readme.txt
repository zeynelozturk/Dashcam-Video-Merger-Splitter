These utilites focus on DF10 car dashcam, but it may work with others too.


=================================
Merge Dashcam videos.bat
=================================

Merges multiple dashcam videos without reencoding (mostly). This is done by comparing
overlapping frames and reencoding tiny part.

The resulting video should have smooth playback without any skipping.

Features

- Internally sorts dragged files by modified date.
- Compares overlapping frames via hash check.
- Adds audio if it exists (default).
- Offers the option to exclude audio.
- Ignores missing audio.

Usage

- Either drag files onto the .bat file, or open the .bat file and drag files into its command window. At least two files are required.
- After the initial files are sorted, you may add event videos by dragging them into the command window. Press Enter without dragging to skip.
- Audio inclusion will then be asked.
- The destination choices are the last folder (default), the folder containing the videos, or Browse. The last selected folder is remembered for the next job.
- Press Enter at the audio question to include audio.

A report will be written to a file named after the merged video in the target folder.

Configuration

- MergeDashcam.config.psd1 is a text configuration file. Open it with any text editor to change settings.
- Keep the configuration file in the same folder as MergeDashcam.ps1.
- FrameRate controls the playback rate of the merged video. The default is 30 fps.
- FrameRateWarningDifference controls when an input frame-rate warning is shown.
- The remaining settings control parallel processing, validation, and console output.

=================================
Extract front and rear videos.bat
=================================

This batch file splits 2 video streams in DF10 dashcam recordings into two files.

Usage

- Drag file(s) to .bat file.
- Files ending with _front.avi and _rear. avi will be written in SOURCE folder.

Requirements

- ffmpeg should be in PATH.