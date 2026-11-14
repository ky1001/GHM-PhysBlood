#!/bin/bash
# Packs the shader pack zip that players download from the GitHub releases page:
#   dist/GHM_PhysBlood_Shaders_<version>.zip  and  dist/SHA256SUMS.txt
# Run native/build.sh first. GitHub Actions runs both for every release (.github/workflows/build.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

VER=$(sed -n 's/^GHMPB\.Version = "\(.*\)"/\1/p' addon/ghm_physblood/lua/autorun/ghm_physblood.lua)
[ -n "$VER" ] || { echo "no GHMPB.Version in the loader"; exit 1; }
NAME="GHM_PhysBlood_Shaders_$VER"

# the prebuilt shaders must be exactly the ones the addon's manifest (sh_shaderver.lua) expects
python3 - <<'EOF'
import os, re, sys
src = open('addon/ghm_physblood/lua/ghm_physblood/sh_shaderver.lua', encoding='utf-8').read()
pre = re.search(r'GHMPB\.ShaderPrefix\s*=\s*"([^"]+)"', src).group(1)
want = dict((k, int(v)) for k, v in re.findall(r'(\w+)\s*=\s*(\d+)', src.split('files = {', 1)[1]))
bad = []
for name, size in sorted(want.items()):
    p = os.path.join('prebuilt/shaders/fxc', pre + name + '.vcs')
    if not os.path.exists(p): bad.append(name + ' missing')
    elif os.path.getsize(p) != size: bad.append('%s is %d bytes, manifest says %d' % (name, os.path.getsize(p), size))
if bad: sys.exit('shader files do not match sh_shaderver.lua:\n  ' + '\n  '.join(bad))
print('%d shader files match the manifest' % len(want))
EOF

rm -rf dist
mkdir -p "dist/$NAME/garrysmod/shaders/fxc" "dist/$NAME/garrysmod/lua/bin"
cp prebuilt/shaders/fxc/ghmpbb74_*.vcs "dist/$NAME/garrysmod/shaders/fxc/"
cp native/out/gmcl_ghmpb_native_v5_win32.dll native/out/gmcl_ghmpb_native_v5_win64.dll "dist/$NAME/garrysmod/lua/bin/"
cp installer/Install_GHM_PhysBlood_Shaders.bat installer/Uninstall_GHM_PhysBlood_Shaders.bat "dist/$NAME/"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-__REPO__}"
sed "s#__REPO_URL__#$REPO_URL#g" installer/README.txt | sed 's/$/\r/' > "dist/$NAME/README.txt"
sed 's/$/\r/' LICENSE > "dist/$NAME/LICENSE.txt"
# batch files must have Windows line endings
for f in "dist/$NAME"/*.bat; do sed -i 's/\r$//; s/$/\r/' "$f"; done
( cd "dist/$NAME" && find . -type f ! -name SHA256SUMS.txt | sed 's#^\./##' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS.txt )
( cd dist && find "$NAME" -exec touch -d "2026-01-01 00:00:00" {} + && LC_ALL=C zip -X -q -r "$NAME.zip" "$NAME" )
( cd dist && sha256sum "$NAME.zip" "$NAME"/garrysmod/lua/bin/*.dll > SHA256SUMS.txt )
cat dist/SHA256SUMS.txt
