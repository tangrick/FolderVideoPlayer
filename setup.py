"""py2app build: produces a fully standalone Video Player.app.

The result embeds its own Python and the PyObjC libraries, so it runs on a Mac
that has no Python installed at all.
"""

from setuptools import setup

PLIST = {
    "CFBundleName": "Video Player",
    "CFBundleDisplayName": "Video Player",
    "CFBundleIdentifier": "local.videoplayer",
    "CFBundleShortVersionString": "2.1",
    "CFBundleVersion": "2.1",
    "NSHumanReadableCopyright": "",
    "LSMinimumSystemVersion": "10.15",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSNetworkVolumesUsageDescription":
        "Video Player needs access to network volumes to play videos stored on them.",
    "NSRemovableVolumesUsageDescription":
        "Video Player needs access to removable volumes to play videos stored on them.",
    "NSDesktopFolderUsageDescription":
        "Video Player needs access to play videos stored on your Desktop.",
    "NSDocumentsFolderUsageDescription":
        "Video Player needs access to play videos stored in your Documents folder.",
    "NSDownloadsFolderUsageDescription":
        "Video Player needs access to play videos stored in your Downloads folder.",
}

setup(
    app=["player.py"],
    data_files=["icon.icns"],
    options={
        "py2app": {
            "iconfile": "icon.icns",
            "plist": PLIST,
            "packages": ["objc", "AVKit", "AVFoundation", "Cocoa", "Foundation", "AppKit"],
            # Only Tcl/Tk is safe to drop. Excluding stdlib modules such as
            # urllib breaks pathlib, which objc imports at startup.
            "excludes": ["tkinter", "_tkinter"],
            "argv_emulation": False,
        }
    },
    setup_requires=["py2app"],
)
