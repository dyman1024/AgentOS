#!/usr/bin/env python3
"""Build, notarize and staple a Developer ID release. Does not publish artifacts."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import subprocess
from urllib.parse import urlparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--identity", required=True, help="Developer ID Application signing identity")
parser.add_argument("--team", required=True)
parser.add_argument("--notary-profile", required=True, help="Existing notarytool Keychain profile name")
parser.add_argument("--feed-url", required=True)
parser.add_argument("--public-key", required=True, help="Sparkle Ed25519 PUBLIC key")
parser.add_argument("--build-number", required=True, type=int)
parser.add_argument("--output", default="release-output")
args = parser.parse_args()
try:
    valid_key = len(base64.b64decode(args.public_key, validate=True)) == 32
except (ValueError, TypeError):
    valid_key = False
feed = urlparse(args.feed_url)
if not valid_key or not feed.hostname or feed.username or feed.password or not args.identity.startswith("Developer ID Application:") or urlparse(args.feed_url).scheme != "https" or args.build_number < 1:
    parser.error("A Developer ID Application identity, HTTPS feed and positive build number are required")
repo = Path(__file__).resolve().parent.parent
os.chdir(repo)
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
archive = out / "AgentOS.xcarchive"
if archive.exists():
    parser.error("Output already contains an archive; choose a fresh output directory")

def run(*command):
    subprocess.run([str(value) for value in command], check=True)

run("make", "ui-kit", "engine-check", "project")
run("xcodebuild", "-project", "AgentOS.xcodeproj", "-scheme", "AgentOS", "-configuration", "Release", "-packageAuthorizationProvider", "netrc",
    "-destination", "generic/platform=macOS", "-archivePath", archive, "archive",
    "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=" + args.identity, "DEVELOPMENT_TEAM=" + args.team,
    "CURRENT_PROJECT_VERSION=" + str(args.build_number), "INFOPLIST_KEY_SUFeedURL=" + args.feed_url,
    "INFOPLIST_KEY_SUPublicEDKey=" + args.public_key, "INFOPLIST_KEY_SUVerifyUpdateBeforeExtraction=YES")
options = out / "ExportOptions.plist"
options.write_bytes(plistlib.dumps({"method": "developer-id", "teamID": args.team, "signingStyle": "manual", "signingCertificate": args.identity}))
run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", out / "export", "-exportOptionsPlist", options)
app = out / "export/AgentOS.app"
run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
submission = out / "notary-submission.zip"
run("ditto", "-c", "-k", "--keepParent", app, submission)
run("xcrun", "notarytool", "submit", submission, "--keychain-profile", args.notary_profile, "--wait")
run("xcrun", "stapler", "staple", app)
run("xcrun", "stapler", "validate", app)
run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
run("ditto", "-c", "-k", "--keepParent", app, out / ("AgentOS-" + str(args.build_number) + ".zip"))
print("Release prepared. Generate a signed Sparkle appcast, then verify on a clean Mac before publishing.")
