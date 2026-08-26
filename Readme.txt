These utilites focus on DF10 car dashcam, but it may work with others too.


=================================
Merge Dashcam videos.bat
=================================

Sorts dashcam videos, compares overlapping frames and merges them in a single video.
The resulting video should have smooth playback without any skipping.

Features

- Compares overlapping frames via hash check.
- Adds audio if exist.
- Ignores missing audio.

Usage

- First copy files to a folder in hard drive.
- Select and drag file(s) to .bat file.
- Merged file will be written in SOURCE folder.

A report will be written to merge_result.txt

=================================
Extract front and rear videos.bat
=================================

This batch file splits 2 video streams in DF10 dashcam recordings into two files.

Usage

- Drag file(s) to .bat file.
- Files ending with _front.avi and _rear. avi will be written in SOURCE folder.

Requirements

- ffmpeg should be in PATH.