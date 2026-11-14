# GHM PhysBlood: write the shader pack manifest into lua/ghm_physblood/sh_shaderver.lua
# Run it for every build whose shaders change, with the new version:
#   python make_shader_manifest.py <pack>/garrysmod/shaders/fxc <addon>/lua/ghm_physblood/sh_shaderver.lua 1.26.6 "<what changed>"
# The game compares the installed shader files with these sizes (cl_shadercheck.lua) and asks players with an older pack
# to install this one. The prefix (GHMPB.ShaderPrefix) is read from sh_shaderver.lua; only files with it are listed.
import os, re, sys
fxc, lua, version = sys.argv[1], sys.argv[2], sys.argv[3]
notes = sys.argv[4] if len(sys.argv) > 4 else ''
src = open(lua, encoding='utf-8').read()
m = re.search(r'GHMPB\.ShaderPrefix\s*=\s*"([^"]+)"', src)
if not m: raise SystemExit('no GHMPB.ShaderPrefix in ' + lua)
pre = m.group(1)
url = re.search(r'url\s*=\s*"([^"]*)"', src)
page = re.search(r'page\s*=\s*"([^"]*)"', src)
source = re.search(r'source\s*=\s*"([^"]*)"', src)
url = url.group(1) if url else 'https://github.com/ky1001/GHM-PhysBlood/releases/latest'
source = source.group(1) if source else 'https://github.com/ky1001/GHM-PhysBlood'
page = page.group(1) if page else 'https://steamcommunity.com/sharedfiles/filedetails/?id=3824094759'
files = sorted(f for f in os.listdir(fxc) if f.startswith(pre) and f.endswith('.vcs'))
if not files: raise SystemExit('no %s*.vcs in %s' % (pre, fxc))
rows = []
for i in range(0, len(files), 4):
    rows.append('\t\t' + ' '.join('%s = %d,' % (f[len(pre):-4], os.path.getsize(os.path.join(fxc, f))) for f in files[i:i + 4]))
block = '''-- (1.26.6) the shader pack this version is built for: the size of each of its files (tools/make_shader_manifest.py writes
-- this block - rerun it, with the new version, for every build whose shaders change). cl_shadercheck.lua compares the
-- installed files with it and asks players whose files come from an older pack to install this one.
GHMPB.ShaderPack = {
	version = "%s",
	notes = "%s",
	url = "%s",
	source = "%s",
	page = "%s",
	files = {
%s
	},
}
''' % (version, notes.replace('"', "'"), url, source, page, '\n'.join(rows))
start = src.find('-- (1.26.6) the shader pack this version is built for')
if start >= 0:
    end = src.find('\n}\n', start) + 3
    src = src[:start] + block + src[end:]
else:
    src = src.rstrip('\n') + '\n\n' + block
open(lua, 'w', encoding='utf-8', newline='\n').write(src)
print('%s: %d files, version %s' % (lua, len(files), version))
