#!/bin/zsh
# Builds dist/Earshot.zip, signs it for Sparkle and adds it to appcast.xml. Publishing stays manual.
#   scripts/release.sh 0.12.0
#   scripts/release.sh 0.12.0 --resign-uploaded   # the release exists: sign the zip already uploaded to it, not a new build
# The EdDSA private key lives in the login keychain (Sparkle's generate_keys, account "earshot");
# SPARKLE_ACCOUNT overrides the account.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:?usage: scripts/release.sh <version> [--resign-uploaded]}
RESIGN=0
[[ ${2:-} == --resign-uploaded ]] && RESIGN=1
[[ -z ${2:-} || $RESIGN == 1 ]] || { echo "unknown option ${2}" >&2; exit 1 }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" Info.plist }
SHORT=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MIN_OS=$(plist LSMinimumSystemVersion)
[[ $VERSION == "$SHORT" ]] || { echo "Info.plist has version $SHORT, not $VERSION" >&2; exit 1 }

# The zip is built from what is committed: commit the version bump first.
git diff --quiet HEAD -- || { echo "Uncommitted changes: commit them first" >&2; exit 1 }
[[ -z $(git ls-files --others --exclude-standard) ]] || { echo "Untracked files: commit or ignore them first" >&2; exit 1 }

# A zip's bytes differ on every build: signing a new one for a release that is already uploaded breaks every update.
command -v gh >/dev/null || { echo "gh is needed to check for an existing release" >&2; exit 1 }
if gh release view "v$VERSION" >/dev/null 2>&1; then
  (( RESIGN )) || { echo "Release v$VERSION exists. Bump the version, or pass --resign-uploaded to sign its uploaded zip" >&2; exit 1 }
else
  (( ! RESIGN )) || { echo "No release v$VERSION to re-sign" >&2; exit 1 }
fi

# Sparkle only offers a build newer than the installed one.
python3 -I - appcast.xml "$VERSION" "$BUILD" <<'PY'
import os, re, sys
path, version, build = sys.argv[1:]
if not os.path.exists(path):
    sys.exit(0)
def key(v):
    return tuple(int(p) if p.isdigit() else -1 for p in v.strip().split("."))
for item in re.findall(r"<item>.*?</item>", open(path, encoding="utf-8").read(), re.S):
    short = re.search(r"<sparkle:shortVersionString>(.*?)</sparkle:shortVersionString>", item)
    if short and short.group(1).strip() == version:
        continue  # the item this run replaces
    old = re.search(r"<sparkle:version>(.*?)</sparkle:version>", item)
    if old and key(old.group(1)) >= key(build):
        sys.exit(f"CFBundleVersion {build} must be greater than build {old.group(1).strip()} already in {path}")
PY

TOOLS=.build/artifacts/sparkle/Sparkle/bin
if (( RESIGN )); then
  ZIP=$(mktemp -d)/Earshot.zip
  gh release download "v$VERSION" --pattern Earshot.zip --output "$ZIP"
else
  ./build.sh --zip
  ZIP=dist/Earshot.zip
fi

[[ -x $TOOLS/sign_update ]] || { echo "Sparkle tools missing in $TOOLS (run swift package resolve)" >&2; exit 1 }
SIGNATURE=$("$TOOLS/sign_update" --account "${SPARKLE_ACCOUNT:-earshot}" -p "$ZIP")
LENGTH=$(stat -f %z "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
[[ -n $SIGNATURE ]] || { echo "sign_update returned no signature" >&2; exit 1 }

REPO=https://github.com/vladt99/earshot
python3 -I - appcast.xml "$VERSION" "$BUILD" "$MIN_OS" "$LENGTH" "$SIGNATURE" "$REPO" <<'PY'
import os, re, sys
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr
path, version, build, min_os, length, signature, repo = sys.argv[1:]
item = f"""    <item>
      <title>{escape("Earshot " + version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_os)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(f"{repo}/releases/tag/v{version}")}</sparkle:releaseNotesLink>
      <enclosure url={quoteattr(f"{repo}/releases/download/v{version}/Earshot.zip")} length={quoteattr(length)} type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>
"""
if os.path.exists(path):
    xml = open(path, encoding="utf-8").read()
else:
    xml = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Earshot</title>
    <link>%s</link>
    <description>Earshot updates</description>
    <language>en</language>
  </channel>
</rss>
""" % repo
# Re-running for the same version replaces its item.
same = re.compile(r"[ \t]*<item>(?:(?!</item>).)*<sparkle:shortVersionString>" + re.escape(version) + r"</sparkle:shortVersionString>.*?</item>\n?", re.S)
xml = same.sub("", xml)
anchor = re.search(r"[ \t]*<item>", xml) or re.search(r"[ \t]*</channel>", xml)
xml = xml[:anchor.start()] + item + xml[anchor.start():]
open(path, "w", encoding="utf-8").write(xml)
PY
xmllint --noout appcast.xml

if (( RESIGN )); then
  cat <<NEXT

Earshot $VERSION (build $BUILD): the uploaded zip re-signed, $LENGTH bytes, sha256 $SHA. appcast.xml updated.
Next step:
  git add appcast.xml && git commit -m "appcast: $VERSION" && git push
NEXT
else
  cat <<NEXT

Earshot $VERSION (build $BUILD): dist/Earshot.zip signed, $LENGTH bytes, sha256 $SHA. appcast.xml updated.
Next steps (the appcast goes live last, so no client sees it before the zip exists):
  1. git push
  2. gh release create v$VERSION dist/Earshot.zip --title "Earshot $VERSION" --notes "..."
  3. git add appcast.xml && git commit -m "appcast: $VERSION" && git push
NEXT
fi
