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

- Select and drag file(s) to .bat file. Destination folder and audio inclusion will be asked.
- Press Enter at the audio question to include audio.

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