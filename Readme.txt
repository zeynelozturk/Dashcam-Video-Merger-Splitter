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

- Select and drag file(s) to .bat file. The first and last modified dates will be shown, then the destination folder and audio inclusion will be asked.
- The destination choices are the last folder (default), the folder containing the videos, or Browse. The last selected folder is remembered for the next job.
- Press Enter at the audio question to include audio.
- You may add more files at the first prompt by dragging them into the command window, then pressing Enter. Press Enter without dragging to skip.

A report will be written to a file named after the merged video in the target folder.

=================================
Extract front and rear videos.bat
=================================

This batch file splits 2 video streams in DF10 dashcam recordings into two files.

Usage

- Drag file(s) to .bat file.
- Files ending with _front.avi and _rear. avi will be written in SOURCE folder.

Requirements

- ffmpeg should be in PATH.