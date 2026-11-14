-- GHM PhysBlood: Crisis Response Blood splats recoloured for the other blood types (tools/make_crb_types.py, 1.26.7):
-- materials/ghm_physblood/crb/t<type>_bp<i>, i = the splat's number in GHMPB.CRBDecals (cl_crbdata.lua).
-- Red blood uses all 36 originals (bp1..36).
GHMPB.CRBTypeDecals = {
	[1] = { 2, 4, 7, 10, 12, 13, 15, 16, 17, 18 },   -- yellow
	[2] = { 2, 4, 7, 10, 12, 13, 15, 16, 17, 18 },   -- green
	[3] = { 2, 4, 7, 10, 12, 13, 15, 16, 17, 18 },   -- zombie
	[4] = { 2, 4, 7, 10, 12, 13, 15, 16, 17, 18 },   -- synth
	[5] = { 2, 4, 7, 10, 12, 13, 15, 16, 17, 18 },   -- robot
}
