"""py2app build: produces a fully standalone FolderVideoPlayer.app.

The result embeds its own Python and the PyObjC libraries, so it runs on a Mac
that has no Python installed at all.
"""

from setuptools import setup

# Keep this in step with the git tag: release vN.M.P must ship version
# "N.M.P", otherwise Check for Updates compares mismatched numbering and
# never fires. The number must only ever go up — the update check asks
# whether the release is greater than what is installed, so renumbering
# downwards strands every existing copy for good.
#
# Which is exactly what happened here, on purpose. This repository restarted
# at 1.0.0 having reached 1.14.1 in the one it replaced, so copies installed
# from the archive will never see an update from here and have to be replaced
# by hand once. That was a deliberate, one-time choice; from 1.0.0 onwards the
# rule above holds again and must not be broken a second time.
#
#   bug fix or tweak  ->  bump the last part
#   new feature       ->  bump the middle, reset the last to 0
#   breaking change   ->  bump the first
PLIST = {
    "CFBundleName": "FolderVideoPlayer",
    "CFBundleDisplayName": "FolderVideoPlayer",
    "CFBundleIdentifier": "local.foldervideoplayer",
    "CFBundleShortVersionString": "1.3.0",
    "CFBundleVersion": "1.3.0",
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
            # VLCKit plays what AVFoundation will not — .flv, .webm, .avi and
            # the rest. One binary, statically linked, no plugin bundle.
            "frameworks": ["vendor/VLCKit.framework"],
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
