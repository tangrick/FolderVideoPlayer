"""py2app build: produces a fully standalone FolderVideoPlayer.app.

The result embeds its own Python and the PyObjC libraries, so it runs on a Mac
that has no Python installed at all.
"""

from setuptools import setup

# Keep this in step with the git tag: release vN.M must ship version "N.M",
# otherwise Check for Updates compares mismatched numbering and never fires.
PLIST = {
    "CFBundleName": "FolderVideoPlayer",
    "CFBundleDisplayName": "FolderVideoPlayer",
    "CFBundleIdentifier": "local.foldervideoplayer",
    "CFBundleShortVersionString": "1.7",
    "CFBundleVersion": "1.7",
    "NSHumanReadableCopyright": "",
    "LSMinimumSystemVersion": "10.15",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSNetworkVolumesUsageDescription":
        "FolderVideoPlayer needs access to network volumes to play videos stored on them.",
    "NSRemovableVolumesUsageDescription":
        "FolderVideoPlayer needs access to removable volumes to play videos stored on them.",
    "NSDesktopFolderUsageDescription":
        "FolderVideoPlayer needs access to play videos stored on your Desktop.",
    "NSDocumentsFolderUsageDescription":
        "FolderVideoPlayer needs access to play videos stored in your Documents folder.",
    "NSDownloadsFolderUsageDescription":
        "FolderVideoPlayer needs access to play videos stored in your Downloads folder.",
}

setup(
    app=["player.py"],
    data_files=["icon.icns"],
    options={
        "py2app": {
            "iconfile": "icon.icns",
            "plist": PLIST,
            "packages": ["objc", "AVKit", "AVFoundation", "CoreMedia", "Cocoa",
                         "Foundation", "AppKit", "certifi"],
            # Only Tcl/Tk is safe to drop. Excluding stdlib modules such as
            # urllib breaks pathlib, which objc imports at startup.
            "excludes": ["tkinter", "_tkinter"],
            "argv_emulation": False,
        }
    },
    setup_requires=["py2app"],
)
