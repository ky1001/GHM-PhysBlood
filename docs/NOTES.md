# GHM PhysBlood - engine facts verified in-game (C: install, x86-64, build 2026.09.22)

Test harness: addons/ghmpb_devharness polls data/ghmpb_dev/cmd_cl.txt ("#<seq>" + Lua), logs to
data/ghmpb_dev/log_cl.txt, GHMPB_DEV.Shot(name) -> data/ghmpb_dev/<name>.jpg.
device_commit_files caches by stagedPath -> always stage under a NEW filename.
Game window is not capturable by computer-use screenshots (masked/black) -> use Shot().
Launch: garrysmod root ghmpb_launch_test.bat via Explorer double-click (Steam's registered GMod is E:, never use steam://).

VERIFIED
- screenspace_general (+ _8tex) with custom *_vs30/*_ps30 from Lua CreateMaterial works. Lua mats are "!name".
- mesh.Begin draws into RTs ONLY inside cam.Start2D/End2D (bare = nothing drawn). 3D context kills alpha writes.
- Float payload upload via mesh.TexCoord(n, s,t,u,v) + $tcsizeN 4 is exact into RGBA16161616F (negatives, >1 OK).
- render.OverrideBlend(true, ONE, ONE, ADD, ONE, ONE, ADD) + $copyalpha 1 = additive incl. alpha into f16.
- render.CapturePixels + ReadPixel on RGBA8 RT works.
- Model draws with SSG need $model 1 $softwareskin 1 $vertexnormal 1. SkinPositionAndNormal(0,...) gives posed world pos.
- NPC:DrawModel() from our hooks is unreliable (other addons set RenderOverride; also water views).
  => use a bonemerged ClientsideModel proxy (SetParent(ent), AddEffects(EF_BONEMERGE), SetNoDraw(true)) for ALL passes.
- UV-space passes into RTs: run in hook PostRender inside cam.Start3D(EyePos(),EyeAngles()) with
  render.EnableClipping(false). In PostDrawOpaqueRenderables they fail in water reflection/refraction views (clip planes).
- MRT (render.SetRenderTargetEx(1, rt)) with DrawModel works (f16 both targets).
- 5 views per frame on gm_construct: skybox, skybox-waterreflection, waterreflection, waterrefraction, main.
  Main view: bDepth=false, bSkybox=false, render.GetRenderTarget()==nil.
- Overlay: proxy:DrawModel() with MaterialOverrideByIndex in PostDrawOpaqueRenderables (main view) +
  render.UpdateScreenEffectTexture() and $basetexture _rt_FullFrameFB read at (VPOS+0.5)*(1/ScrW,1/ScrH): aligned.
- MaterialOverrideByIndex(i, noDrawMat) with UnlitGeneric {$no_draw 1} hides other submaterials.
- Model (DrawModel) passes into RTs: the engine masks ALPHA writes of render target 0 in the 3D context
  (RT1 of an MRT keeps alpha). render.OverrideAlphaWriteEnable(true, true) around the draw fixes it.
  render.SetWriteDepthToDestAlpha(false) does NOT.
- CreateMaterial with a name that already exists (Lua refresh, map change - the material system outlives the
  Lua state) returns a material that silently draws nothing. => per-Lua-state nonce in material names and a
  cache so each material is created once (GPU.CreateMat).
- Framebuffer composites (SSG over the scene): sample _rt_FullFrameFB with sRGB read ($linearread 0) and write
  with $linearwrite 0. $linearwrite 1 there darkens everything the overlay touches by ~22 % (measured).
- Hit positions (traces vs NPC hitboxes / ragdoll physics hulls) are 1-3 u off the skin: snap to the mesh
  (util.GetModelMeshes bind pose, per-bone vertex cache) before stamping.
- MRT with 3 targets (render.SetRenderTargetEx(1..2)) works in screenspace_general and _8tex (verified with a
  constant-output probe shader: all three targets receive their values).
- screenspace_general pixel shaders get c10 = 0 (no eye position): pass the eye from the vertex shader
  (cEyePosWaterZ) as an interpolant. $viewprojmat -> c11..c14 and $invviewprojmat -> c15..c18 arrive as rows.
- ITexture:GetColor returns black for most textures (no CPU copy). Mean albedo: draw the texture with
  surface.DrawTexturedRect into an 8x8 RT inside cam.Start2D, then render.CapturePixels / ReadPixel.
  render.DrawScreenQuadEx / DrawTextureToScreenRect draw nothing into that RT.
- render.Capture in PostRender includes the HUD (HUDPaint) but not Derma panels.
- The dev harness replays nothing after a map load: its first poll only records the current sequence number.
- ConVar:SetFloat / SetString on client convars apply immediately (unlike RunConsoleCommand, which is queued),
  so a preset can set many convars and tell its own change callbacks apart with a flag.
- Render targets can not be released from Lua (GetRenderTargetEx has no free): pools must be bounded by a budget.
- Measuring a texture's mean colour with surface.DrawTexturedRect blends with the texture's alpha: world
  textures that keep an envmap / specular mask in alpha come out almost black (a tan floor tile measured 0.03).
  render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD) around the draw copies the colour as is.
  An albedo that is too dark turns straight into far too much light on the blood (pink, see-through pools).
- screenspace_general: $linearread_<tex> 0 turns ON the hardware sRGB decode for that sampler and
  $linearwrite 0 turns ON the sRGB encode of the output (measured in 1.6.0: a constant debug colour came out
  exactly twice gamma-encoded, while a framebuffer pass-through matched the frame). Either let the hardware
  convert and do no conversion in the shader, or set $linearread 1 / $linearwrite 1 and convert in the
  shader - never both (before 1.6.0 both ran: every blood colour was washed out to pink / salmon and the
  model albedo read twice-decoded, too dark, so blood on bodies glowed). Float render targets are never
  sRGB decoded. The framebuffer, model textures and LDR cubemaps hold sRGB encoded values.
- Fixed camera test shots: render.RenderView({ origin, angles, fov, x=0, y=0, w=ScrW(), h=ScrH() }) inside a
  one-shot PostRender hook, then render.Capture: independent of where the player is looking.
- PlayerFootstep only runs server side in singleplayer (no client prediction), so client effects that need
  steps (footprints) take them from the distance walked instead.
- NPCs given SCHED_FORCED_GO on a map without a node graph do not move; tests move them with SetPos.
- Immediate-mode meshes (mesh.Begin/Position/TexCoord/AdvanceVertex every frame) cost ~6 Lua->C calls per
  vertex: a 16x16 grid is ~6000 calls, ~0.15 ms per patch per frame. Build an IMesh once (Mesh(mat) inherits
  the material's vertex format, e.g. $tcsize0..3 = 4) and IMesh:Draw() it with the bound material instead.
- A game window without focus runs at 20 fps (50 ms frames): frame-time measurements need the window focused
  (engine_no_focus_sleep does not exist in this build).
- Frame-time profiling from Lua: swap a module function for a no-op for a few seconds and compare the average
  FrameTime(); SysTime() around the Lua call gives its CPU share (GPU work shows only in the frame time).

- A net message sent unreliably (net.Start(name, true)) can arrive after a reliable one sent a tick later: the
  killing shot's hit message can arrive after the ragdoll hand-over, so the hit lands on a server ragdoll
  that the client has only just created and whose bones are not set up yet (GetBoneMatrix returns nil).
  Entity:SetupBones() or retrying a few frames later fixes the bone lookup.
- Engine particles (ParticleEmitter) keep their think function: SetThinkFunction + SetNextThink(CurTime())
  every frame lets Lua drive velocity, size and alpha (Stokes decay of a mist puff).
- render.Capture returns nil for a 2400x1350 region (window resized larger) while smaller regions work:
  capture at most 1600x900 (RenderView into x=0,y=0,w=1600,h=900 and capture that). It also returns nil
  while the window has no focus. RenderView's fov is the horizontal fov of the given w/h (no 4:3 rescale).
- device_commit_files uploads a file under /mnt/user-data/outputs when it is first written: rewriting the
  same path later and committing again sends the OLD content. Every command file needs a fresh path.
- Spawning drops from inside the Lua solver's own loop (P.Land -> P.Spawn) corrupts the swap-remove list;
  secondary drops (ricochet / crown splash) are queued and spawned after the pass (FlushChildren).

1.8.0 (crevice pools, brick test map):
- studiomdl turns $staticprop models by 90 degrees about z: SMD +y becomes world -x (a face modelled towards
  local -y ends up facing +x at entity yaw 0). Spawn code has to use the compiled orientation.
- studiomdl builds the convex pieces of a $concave collision model from shared vertices, which only merge
  when position, normal and uv are identical: give every collision box one normal / uv.
- VTF flags: 0x4 / 0x8 are CLAMPS / CLAMPT (not trilinear / anisotropic: those are 0x2 / 0x10). A clamped
  texture on a prop with uv outside 0..1 comes out as streaks of its edge texels.
- vbsp (this GMod build) removes world brush faces that lie under func_detail brushes, including the 1 cm
  gaps between them: the mortar at the bottom of detail-brick joints is not drawn (black), collision is fine.
  vbsp also hangs after "24 threads" (even -onlyents) once in a while; the light entities can instead be
  written straight into the BSP entity lump (tools/bsp_tool.py, new lump appended at the end of the file)
  and the map relit with vrad alone (7 s for the test map).
- The loaded map's BSP is locked by the game (pack lump): relighting needs a changelevel to another map
  first. RunConsoleCommand("changelevel", map) works from server Lua (unlike "quit").
- render.UpdateFullScreenDepthTexture() + render.GetResolvedFullFrameDepth(): _rt_ResolvedFullFrameDepth
  reads (0, 1, 1, 1) everywhere on the main view - no usable depth for screen-space ray marching.
- util.TraceLine with an `output` table reuses that table: a later trace overwrites the fields of an earlier
  result. Copy HitPos / HitNormal (Vector(tr.HitPos)) before tracing again.
- The ESC menu pauses a singleplayer game: timers stop, so the dev harness idles until it is closed.
- Readback positions of patch outflow are 8-bit uv of the patch (~0.16 u): traces started from them must
  start a little back from surfaces, or they start inside solid.

1.9.0 (blood types, colour mixing, blood supply, surface materials):
- Blood colours seen in game: npc_zombie BLOOD_COLOR_ZOMBIE (5), npc_headcrab BLOOD_COLOR_GREEN (2),
  npc_manhack DONT_BLEED (-1), citizens RED (0). The zombie's corpse is a server prop_ragdoll that turns into a
  C_ClientRagdoll shortly after; both carry the type (NW2 on the server one, a Lua field on the client one).
- util.GetModelInfo(mdl) works on both realms: SurfacePropName is the model's $surfaceprop, KeyValues holds a
  "surfaceprop" per collision solid. zombie/classic.mdl = zombieflesh, antlion.mdl = antlion, headcrab =
  alienflesh, kleiner / citizens / combine = flesh, manhack = metal, cardboard box = cardboard, mattress =
  carpet, chair = wood, player/skeleton.mdl = flesh (caught by the model name list instead).
  zombie/fast.mdl and zombie_soldier say "flesh": the NPC's blood colour decides for living NPCs.
- util.GetSurfacePropName(tr.SurfaceProps) gives the surface property of a world trace (brick, concrete,
  rock, ...), much finer than tr.MatType (brick and concrete are both MAT_CONCRETE).
- screenspace_general draws into 4 render targets at once (render.SetRenderTargetEx 1..3) and the additive
  override blend applies to all of them (stamps add into state, aux and the ghost export in one pass). The
  material still only binds 8 textures, so the neighbour patches' ghost cells come from a per-patch export
  target (h, second-type fraction, momentum) written as the 4th output of the simulation step.
- Flying drops are real size: a 1.8 mm drop 1.7 m away is ~2 px, so in-flight drops only show up close to
  the camera or with their motion trail.
- ghmpb_* client convars are archived: test settings (settle time, blood volume) stick until reset.

1.10.0 (pool levelling, arterial / venous oxygenation, colour settings, ragdoll wound position):
- Bullets on a server prop_ragdoll give a correct dmg:GetDamagePosition() (it was the calf when the calf was
  shot); GetReportedPosition() is zero for bullets. Weapons calling TakeDamage directly leave the position
  empty, so the wound needs the attacker's aim / a trace towards the body.
- The accumulator's alpha channel survives the readback clear when the clear is drawn (blit quad) with
  render.OverrideAlphaWriteEnable(true, false); the pool / stamp / sim passes still write it normally.
- With 4 render targets bound, screenspace_general writes COLOR0..3 and the override blend applies to all of
  them; unbound higher outputs are ignored (bodies bind 3, world patches 4).
- Pixel shader constants of screenspace_general are float32: packing two settings into one constant
  (integer part + fraction) keeps both exact enough (hue * 8 + normal depth, dry absorption * 100 + fabric).
- A ps_3_0 pixel shader that compiles fine can still fail at creation ("Failed to create shader" in red in the
  console, the material then draws nothing): the 1.10.0 sim step at ~4050 instruction slots (fxc estimate)
  failed, 3980 worked. Keep every pixel shader well below ~3500 slots (check with D3DDisassemble: the
  "approximately N instruction slots used" line). The sim step is therefore compiled as two variants
  (sim_ps30 world ~2960, simbody_ps30 ~2810) and the world surface noise is baked once into force.z.
- The Anatomy skeleton map of a model built in an entity's first frame has no bone names ("__INVALIDBONE__"):
  a prop_ragdoll spawned and shot moments later cached an empty map for its model, so every wound on that
  model was region "other" and the body contacts for pooling fell back to the middle. Only maps with bones
  are cached now.
- render.Capture of the whole 2400x1350 window returns nil, 1200x675 from the corner works: copy the back
  buffer into a 1600x900 RT (render.CopyRenderTargetToTexture scales) and capture that RT.

1.11.0 (explosion burst, NPC bases):
- Blast damage (util.BlastDamage / env_explosion / grenades): dmg:GetDamagePosition() is the centre of the explosion
  (outside the body); the force points away from it.
- Engine NPCs, DrGBase and ZBase run the death (OnNPCKilled) and make the corpse from inside their damage
  processing, i.e. before PostEntityTakeDamage; VJ Base calls OnNPCKilled via gamemode.Call and makes its corpse
  with ents.Create + hook.Call("CreateEntityRagdoll"); DrGBase makes corpses with ents.Create("prop_ragdoll") and
  removes the NextBot in the same tick (no CreateEntityRagdoll).
- PostEntityTakeDamage(ent, dmg, took): took is the return of OnTakeDamage; VJ returns 0 for immunities / god mode
  and 1 otherwise, some SNPC bases return nothing although they took the damage (-> compare health instead).
- Observed: addon folders added to garrysmod/addons while the game runs were not mounted by later map loads; new or
  changed files inside an addon folder that was mounted at start are picked up on the next map load.

1.11.1 (double stains, performance, map robustness):
- fxc never keeps screen-derivative instructions (ddx / ddy / fwidth, tex2D with implicit gradients) inside a dynamic
  branch: it hoists them - and everything they depend on - in front of it, and turns an early `return` into a select
  at the end. To really skip work for pixels without blood, every derivative has to be computed before a
  `[branch] if` and the code inside must be derivative free (tex2Dlod, analytic gradients). Check with the
  disassembly: the bulk of the instructions must sit between `if_` and `endif`.
- A pixel shader that uses more than 32 temporaries fails with X4505 "maximum temp register index exceeded"; values
  kept alive across a branch count against it (keep the pre-branch struct small, recompute cheap values inside).
- fxc shares identical tex2Dlod fetches (CSE) between a cheap test in front of a branch and the code inside it, and
  then hoists them all in front: sample the test a hair off (0.999 of a texel) so they stay separate.
- Static props are never passed to a Lua trace filter function (tested on gm_construct's sink: the filter was not
  called and the trace hit the prop), so a filter that rejects the world does not lose them.
- CTakeDamageInfo, traces: util.TraceLine with a Lua filter function costs more than a table filter; the table form
  is handled in C.
- GetRenderTargetEx for a new target ~0.4 ms, CreateMaterial (screenspace_general) ~0.8 ms: a world patch slot (10
  targets, 7 materials) ~10 ms, a body slot ~3 ms. Made during a fight they stall frames; they are pooled and made
  ahead after the map loads.
- render.CapturePixels waits for the GPU to finish the queued frame: a separate capture per measured texture cost up
  to ~20 ms right after an explosion. Everything that needs reading back rides on the one readback capture.
- A full collectgarbage("collect") of a ~40 MB Lua heap took ~120 ms in this build: avoid per-frame garbage
  (vectors, tables, strings) in hot loops.
- debug.setupvalue does not exist in the GMod client Lua state (debug.getupvalue does).
- Frame times of an unfocused game window are throttled (10-20 fps): measure with the window focused, or measure
  the CPU time of the code itself (SysTime) instead of the frame time.
- Other addons may wrap GHMPB functions (GHM FLESH wraps G.Entities.DrawStatic / DrawOverlays to draw its wounds
  right before the body blood): profiling a GHMPB function then includes their work.

1.12.0 (runs on walls, blood in water):
- The cell simulation alone cannot make convincing runs on walls at 3 mm cells: a spread stain is a 0.1-0.3 mm film whose
  flux (~h^2) is tiny, it slumps into a tall blob instead of shedding a rivulet (checked offline with tests/sim_hf.py, a
  NumPy port of the world step). Runs are therefore tracked as heads on the CPU (cl_runs.lua) that paint their trail.
- Water views on gm_construct (the lake, water surface z = -160): per frame the engine renders _rt_waterreflection (eye
  mirrored below the water plane, i.e. inside the water volume) and _rt_waterrefraction (eye = main eye) before the main
  view (render target nil). PostDrawOpaqueRenderables / PostDrawTranslucentRenderables run in each of them.
- Anything under the water surface is only seen from above through the refraction view: blood overlays drawn in the main
  view only vanished on submerged bodies. Drawing them again in the refraction view works (render.UpdateScreenEffectTexture
  there copies the refraction target; the overlay's screen-space lookups use that target's size).
- Lua ParticleEmitter particles under water were drawn in the main view (seen from under water) but not in the water
  refraction view (invisible from above). Sprites drawn from PostDrawTranslucentRenderables with render.DrawQuadEasy /
  DrawBeam (UnlitGeneric, $translucent, $vertexcolor/alpha) are drawn in the refraction view with its clip plane, but get
  no water fog from the engine: fog them by hand (render.GetFogMode / GetFogDistances / GetFogColor; the refraction view
  uses MATERIAL_FOG_LINEAR_BELOW_FOG_Z with the water height as fog z).
- util.TraceLine with mask CONTENTS_WATER | CONTENTS_SLIME finds where a segment enters a water volume; MASK_SHOT does not
  stop at water (drops fly into it and are only found by util.PointContents).
- util.Effect("waterripple") draws a ring on the water surface (scale / 8 = ring size); it is cheap enough for the bigger drops.
- render.RenderView shots: world patches whose overlay mesh has not been built yet (at most 6 meshes are built per frame,
  only for patches in the view being drawn) are missing from a single RenderView frame - render the view 2-3 frames in a
  row before capturing.
- console.log of this install had grown past 400 MB (-condebug appends forever).
- Eye under water (gm_construct lake): the engine draws two views into the screen per frame (render target nil for both,
  same origin and angles, both report MATERIAL_FOG_LINEAR): first what is above the water with a clip plane (copied into
  _rt_waterrefraction afterwards, seen through the surface from below), then the main view under water. There is no
  reflection / refraction RT pass then. The only way found to tell them apart is their order (the main view is the last).
- GHM FLESH draws its wounds once per frame (FrameNumber gate) from a wrapper around G.Entities.DrawStatic / DrawOverlays.
  Calling those from the refraction view (1.12.0) or from the first of the two screen passes made its wounds land in the
  wrong view (missing above water whenever a water surface was on screen, missing on bodies in water once the player
  dived). Only the main view calls the public functions now; the extra water views use RawDrawStatic / RawDrawOverlays.
- Engine blood decals: shooting a DONT_BLEED NPC or any prop_ragdoll still paints a blood splat on the model (the bullet's
  impact effect picks the decal from the flesh material, not from the blood colour). prop_ragdoll:GetBloodColor() is nil
  on the server. Entity:RemoveAllDecals() on the client removes them; done in PreRender (after the packets of the frame,
  before it is drawn) for a moment after each hit and once a second for bodies with blood.
- npc_citizen spawned on the gm_construct lake bottom (displacement) falls through it to z = -960 (hull vs displacement);
  standing ragdolls frozen in their reference pose work for water tests.

1.13.0 (hand prints, props, tyres, splashes, GHM FLESH):
- The stamp table packs the kind in 3 bits (0..7, row3.z) next to the expirated flag, the spine count and the second-type
  flag (1024) in a half float, which stays exact only up to 2048: there is no room for more kinds. Hand prints and tyre
  treads are variants of the footprint stamp (kind 5, |row3.x| = 2 / 3), finger streaks a variant of the smear (kind 3,
  |row3.x| = 5).
- Instruction slots (ps_3_0, d3dcompiler_47, /O3), measured with a small MinGW tool that calls D3DCompile + D3DDisassemble
  under Wine (/home/claude/tools/slots): stamp 1598 before 1.13.0, ~2270 with the hand print and tread; sim 3173, simbody
  2979, surface 2502, bodyfilm 1800.
- GHM FLESH (another project in the same install) switches its own bleeding off while PhysBlood is enabled
  (W.StartBleed returns when GHMPB.cv.enable is on) and fires hook.Run("GHMFL_ClientSever", ent, key, gib) on the client
  after a limb is cut off; the gib is a ClientsideRagdoll of the same model with gib.ghmflGib = true, and ent.ghmflGore
  .collapse[bone] marks the bones collapsed on either entity (severed on the body, not part of the limb on the gib).
  GHMFL.Anatomy.Get(ent).chain[key] lists the bones of the limb (its root first).
- Vehicles: Glide wheels are glide_wheel entities parented to the car (NetworkVars Radius, SideSlip, ForwardSlip,
  ContactSurface); LVS wheels lvs_wheeldrive_wheel (Radius, Width, GetBase, client GetSkid()); simfphys wheels
  gmod_sent_vehicle_fphysics_wheel (OnGround, SkidSound, GripLoss, GetBaseEnt). HL2 four-wheel vehicles place their
  wheels at the model's wheel_fl / wheel_fr / wheel_rl / wheel_rr attachments.
- Tested in game (ghmpb_bricks, 2026-09-30): the HL2 buggy faces +y at yaw 0 (its GetForward() is sideways to its
  motion, which read as permanent sideways slip: every track was a skid smear). The car's heading for HL2 vehicles is
  now the line from the rear to the front axle attachments.
- Probe latency: an answer comes with the next readback (every 0.3 s). A car at 400 u/s is 100+ u further on by then,
  so the tracks started well past the pools. Tyres now ask the ground 0.3 s ahead of themselves (a ring of 24 slots per
  wheel) and use each answer when they reach it; late answers fill the track in behind.
- HL2 citizens have three finger bones per hand (Finger0 thumb, Finger1 index, Finger2 the other three): no little
  finger. The palm frame uses the index and middle knuckles then.
- The palm vector in cl_hands is the palm's OUTWARD normal; the first version traced from the palm the wrong way (only
  the "side" fallback ever fired). A ragdoll's hand rests on its collision box with the bone axis ~2.4 u off the floor.
- A client ragdoll's bone matrices are only valid after it was drawn or SetupBones() was called: GetBoneMatrix(hand) is
  nil for a prop_ragdoll the camera has not seen yet (the first hand test found "no domain" for this reason).
- GHM FLESH's BuildBonePositions callback (Collapse, cl_gore.lua) calls SetBoneMatrix on every severed bone. Whenever
  the bones of a cut body are set up for a partial bone mask (a bonemerged child like PhysBlood's proxy drawing, extra
  views, lower LODs, Lua SetupBones) the engine prints "[ghm_flesh] SetBoneMatrix: Bone is unwriteable" for the bones
  outside the mask: ~90 per second from the engine alone with one cut body on screen, more while PhysBlood draws its
  layer on that body. PhysBlood no longer calls SetupBones on bodies FLESH has cut; the rest is on FLESH's side.
- Pools thicker than ~1 mm look the same dark red after a wipe: a tyre channel through a 4 mm pool is not visible (and
  in reality it flows back at once); what shows is the track leaving the pool.

1.14.0 (performance with a lot of blood, adaptive quality, fire):
- render.CapturePixels waits for the GPU to finish everything queued before it. Measured on the C: install with a
  heavy scene (two captures in a row): 20-35 ms for the first and 0.1 ms for the second in PostRender, 0.2-0.3 ms in
  PreRender (when the GPU keeps up). When the GPU is the bottleneck (a big dismemberment scene with GHM FLESH), even
  the PreRender read waits for the previous frame (20-55 ms per read); the read interval now grows with that wait.
- util.IntersectRayWithOBB returns the hit normal in the box's LOCAL space (axis-aligned, e.g. (0,-1,0)), not in
  world space; the hit position and fraction are in world space. PhysBlood used it as a world normal for drops
  hitting client ragdolls until 1.14.0 (the stain orientation and the snap's facing test were off).
- Vector methods, GetBoneMatrix, GetHitBoxBounds and WorldToLocal are C calls that LuaJIT cannot compile: a loop of
  160 DistToSqr calls per impact cost ~70 us. The same loop on plain numbers is ~10x faster (numbers read once per
  frame per body).
- The game window in the background: the engine holds the frame rate at ~20 fps (50 ms frames); engine_no_focus_sleep
  does not exist in this build (GetConVar returns nil). Frame times measured while unfocused say nothing about the
  blood; the governor holds its pressure then (system.HasFocus()).
- GHM Euphoria (another project in the install) hurts a downed NPC by 1 point of DMG_GENERIC every 1.2 s with the
  last attacker as attacker and inflictor and no force ("bleedout", sv_integration.lua), and forwards damage from its
  active ragdoll to the NPC with the original type. Burning NPCs go down, so fire deaths reached PhysBlood as generic
  damage: a new wound per tick. PhysBlood 1.14.0 treats <= 2 points of generic damage without force as a damage-over-
  time tick (no wound; a killing tick counts as the damage before it).
- Other Claude sessions drive the same C: game (their own dev harnesses); blood and hit messages from their tests
  show up in PhysBlood's counters. A test that counts drops has to track where they come from (wrap
  G.Particles.Spawn / Hang / Drips / Spray and record the callers).
- Stress scene for profiling (devharness/cmds/s41.lua + c116.lua): 10 npc_citizen and 3 prop_ragdolls near the camera
  on ghmpb_bricks, killed (DamageInfo with the world as attacker does not kill citizens: the killing blow uses the
  player as attacker), 12 s later two limbs of each cut with GHMFL.Gore.Sever -> 13 cut bodies, ~26 limbs.

1.14.1 (blood colours match):
- A world plane's type pair (S.planeTypes: a, b, volumes) is plane-wide; the per-pixel share of type b is in aux.w (live,
  mm of type-b blood) and in b of the baked aftermath (fraction). The patch-level p.btype used for drips, outflow and
  probes was S.MainType(plane) - the type with more volume on the whole plane - so it was wrong for any pool of the
  smaller type. Probes now draw a second pixel (row 126 of the readback target) from aux.w; fraction = aux.w / (h + s).
- Readback target rows 120-127 belong to the probes (tiles: < 240, i.e. rows 0-119; albedo tiles were allowed up to 250).
- Stamp kind 4 (push / wipe) adds no type volume in the shader (max(wet + stain, 0) = 0), but S.TypeSlot was called for
  it with the wiper's type and could switch the plane's second type.
- 1.14.1: type pairs per region (S.TypeKey(p) = plane # floor(i / 4), floor(j / 4)). The ghost-cell export carries the
  neighbour's second-type FRACTION relative to the neighbour's pair; sim_ps30 now remaps it per side with c15 / c16
  (f' = m0 + m1 f; m0 = [neighbour a == own b], m1 = [neighbour b == own b] - m0; identity (0, 1) inside a region). The
  sim materials default them to identity ($c15_y / $c15_w / $c16_y / $c16_w = 1 at creation).
- Slot materials keep the shader set they were created with until the map changes: a new shader set deployed into a
  running game only reaches newly created materials.


## Multiplayer and Z-City (1.15.0) - from source, not yet verified in game
- GMod's `hook.Call` runs an event's hooks one after another and stops at the first that returns anything other than nil
  (false included). Z-City's `EntityTakeDamage` hook "homigrad-damage" ends with `return !ent:IsNPC()` for every body
  with an organism, so it stops every damage hook after it. ULib (required by Z-City) replaces the hook library and
  supports priorities: `HOOK_MONITOR_HIGH` (-2) hooks run first and their return values are ignored. Without ULib,
  `hook.Call` is looked up by the engine on each event (ULib's own replacement relies on this), so a wrapper works.
  1.17.0, measured in game (x86-64 build 2026.09.22): wrong - a wrapper put on the global hook.Call after start-up saw
  no engine event at all (not even Think), and with PhysBlood's hooks moved out of the table no hit arrived; an
  addon's hook returning false (GHM FLESH / other gore addons here) hid every hit in plain mode too. Now every other
  hook of the two damage events is wrapped in the hook table (see 1.17.0 in-game pass).
- Z-City (sv_util.lua "ResponsiveHits") sets `SetBloodColor(-1)` on players at PlayerSpawn and on NPCs in a timer 0
  after OnEntityCreated, keeping the real colour in `ent.bloodColorHitFix`.
- Z-City players: damage is blocked (`return true`) and taken by `ply.organism` (`org.lasthit = CurTime()` when it
  processed a hit); a knocked-down player's damage goes to `ply.FakeRagdoll` via `TakeDamageInfo`. NW entities:
  `ply:GetNWEntity("FakeRagdoll")`, `rag:GetNWEntity("ply")`, `ply:GetNWEntity("RagdollDeath")` (set in DoPlayerDeath,
  before PlayerDeath). Server hook "Ragdoll_Create"(ply, rag) runs for both. Client hook "Fake"(ply, rag).
- Z-City client blood: `hg.addBloodPart(pos, vel, mat, w, h, artery, kishki, owner)` (vel in units/s; its own sim
  uses 4x gravity), `hg.addBloodPart2(pos, vel, mat, w, h, time, water, owner)` (wound code passes the owner as a 9th
  argument), drawn and simulated in PostDrawTranslucentRenderables "bloodpartciels" (which also paints its decals);
  net "hg_bloodimpact", "addfountain", "bloodsquirt", "bloodsquirt2" (local functions, not hg.*); wound drips in hook
  "Player-Ragdoll think" from `ply.wounds` / `ply.arterialwounds` ({amount, localPos, localAng, boneName, time}).
- Z-City is AGPL-3.0: nothing of it is copied; PhysBlood only calls / replaces its public functions at run time.


## 1.16.0 - battle size, per-surface looks, creature tracks (verified in game on gm_construct in 1.17.0)
- Battle level (cl_battle.lua): level = clamp(max((combatants - 12) / 28, (hits/s - 6) / 34, (bleeders - 8) / 24));
  up by <= 0.5 per update (0.5 s), down by 0.05. The governor (cl_governor.lua) uses max(pressure, level x k) for global
  budgets (Pg) and max(pressure, level x w) per place (Pl: w = 0 in view within 700 u, 0.55 in view within 1600 u, 1
  otherwise). So near blood in view only loses detail to the frame-time pressure, as in 1.14.0.
- Far drops (cl_particles.lua P.SpawnFar): FAR_DT 1/60 s, chords of 8 steps per trace, the hit velocity interpolated
  at the hit fraction; 160 traces a frame shared by all far drops; landing deferred to P.Land with a copied trace. A
  first version with 1/30 s steps landed 3.4 u off; 1/60 s with 8-step chords lands within 0.4 u.
- Surface look id: SC2.w (world patches only) = smooth mode (0..3) + 4 x debug view (0..4) + 32 x G.SurfaceMatId
  (0..17), decoded in ghmpb_surface_main.h; ghmpb_setMat(id) in ghmpb_shade.h sets static globals (bodies never call
  it: their defaults reproduce the old shading exactly - soak 0, scat 1, crack 1, no halo / grain / sparkle). Id 0
  (sealed / plain) is unchanged too.
- Soaked look: Kd = lerp(dry crust absorption, wet absorption x dilute, soak x fresh); the static layer sets fresh =
  exp(-layerDry x 0.15 x brown), so soaked blood browns slowly in the aftermath (snow: brown 0.25). Halo: 4 taps of
  the film at haloR texels around the pixel outside the stain, tinted (damp grey / pink / serum); a damp halo dries out
  in the static layer. Grain multiplies h and s by a noise (value noise / Voronoi stones / anisotropic blades) that
  thick blood (h 0.3 .. 1.2 mm) levels out.
- Absorption retune: kabs (1/s) / cap (mm): snow 1.2 / 5, sand 0.75 / 3, paper 0.55 / 0.8, carpet 0.45 / 1.6, soil
  0.25 / 1.8, brick 0.12 / 0.6, plaster 0.09 / 0.45, concrete 0.06 / 0.4, wood 0.06 / 0.35, stone 0.015 / 0.12, ice
  0.01 / 0.2. New field dryk multiplies the drying rate (c2.z): snow 0.6, ice 0.5. MAT_CONCRETE and the surface
  props "concrete" / "asphalt" now map to concrete (was stone); "ice" to ice (was glass).
- Creature tracks: stamp kind 5 with |row3.x| = 4 + shape (0 pad, 1 claw, 2 three toes, 3 paw); sign = side (mirror).
  Areas (x R_mm^2, measured with tests/creature_preview.py): pad 2.5, claw 0.53, toes 0.54, paw 0.78 - the same in
  stamp_ps30.hlsl and cl_footprints.lua (AREA), so the film printed equals sole load x 0.38. Profiles: feet
  { forward, right, group, outward yaw }, two groups stepping in turn (headcrabs / antlions diagonal pairs). Unknown
  NPCs: humanoid = head + spine + arms / thighs; soles only if legs on both sides AND upright (OBB height >= 1.2 x its
  length / width; players always); legless humanoid = nothing; anything else = generic pads / paws from the OBB.


## 1.17.0 - elements
- Element word: c3.w = flashlight on + 2 x (frost 4 bits + 16 boil 4 + 256 fizz 3 + 2048 glow type 3 + 16384 glow 4
  + 262144 char 4) < 2^23, decoded on use in ghmpb_shade.h (ghmpb_elemField: floor((w + 0.5) / div), exact in fp32
  below 2^23). Decoding into static globals at the top of main took temp registers for the whole shader and pushed
  the world shaders over the ps_3_0 limit (32 temps): decode where used. World patches skip the in-film bubbles / char
  (GHMPB_WORLD) and draw the foam after the film shading in ghmpb_surface_main.h (dynamic layer only).
- Element stamps (boil 10, vaporise 11, acid 12, shove 13) are a pass of their own (elem_ps30), same impact table
  and targets as stamp_ps30 (kind 4 with spin = op): inside stamp_ps30 the extra branch exceeded the temp registers.
  They read the previous state (st[3 - cur], one step old) and track what they took per texel so several
  applications in one pass never take more than was there. The sim clamps s >= 0 (acid / vaporise take stain away).
- Sim parameters per patch / body (GPU.SimParams el): heat -> drying x (1 + 60 heat; 20 in the first build was too slow to see fire dry a pool), clotting x (1 + 6 heat) (and
  0.4 heat / s with coagulation off); frost -> viscosity x (1 + 80 f^2), pinning x (1 + 6 f), drying x (1 - 0.95 f),
  absorption x (1 - f), no clotting. Heat over 0.5 cancels frost.
- Freezing: snow 1/90 s, ice 1/50 s, StormFox 2 below 0 C outdoors (sky trace) clamp(-T / 10, 0.2, 3) / 120 s; thaw
  0.02 / s. Steam: fresh spots (S.Impact kinds 0 / 1 > 150 mm3, merged within 10 u, 8 per patch) for 55 s while the
  patch is cold or StormFox 2 says < 8 C outdoors.
- Server wet map = sv_history records, now also kept in single player while ghmpb_sv_elements is on (sending stays
  multiplayer-only). Wet: pool ghmpb_sv_wet_time x clamp(sqrt(vol / 20000), 0.6, 2.5); drips x 0.2 x clamp(sqrt(vol /
  1500), 0.5, 2); spatter x 0.1. Dry: heat accumulated > 4 x clamp(vol / 20000, 0.5, 3). Frozen: r.cold (snow / ice
  under it or StormFox sub-zero outdoors) and older than 40 s, unless thawed by heat.
- Discharge: seeds = wet records within 28 u (+ their radius) of the source; breadth-first through records whose discs
  come within 18 u, path length < ghmpb_sv_elec_range, at most 64 records; victims = players / NPCs / NextBots on the
  ground with their feet within radius + 10 u (|dz| < 22) of a record; damage = ghmpb_sv_elec_damage x clamp(strength,
  0.2, 2) x clamp(1 - path / range, 0.25, 1), DMG_SHOCK, 0.4 s per victim, 0.35 s per 64 u cell; EL.zapping guards
  against the shock's own damage / sounds setting off another discharge.
- Sources by sound (EntityEmitSound): ambient/energy/zap|spark|newspark|weld, stunstick spark / impact / fleshhit,
  electric_explosion, superphys_small_zap, rollermine shock / taunt -> discharge at the floor under the sound;
  "thumper" + "hit"/"thump" -> shock wave. Ammo with ENERGYBEAM / PLASMA / BURN / SHOCK / DISSOLVE damage types ->
  elements at the bullet's hit (PostEntityFireBullets).
- Char marks: engine decals (util.DecalEx, LightmappedGeneric $decal material over materials/ghm_physblood/char1-3,
  tools/gen_chartex.py), one per 6 u cell per 20 s, only where a probe reads dried blood (s > 0.04, h < 0.03) after
  2.5 s of heat (0.6 s plasma).

## 1.17.0 - in-game pass (gm_construct, single player, October 2026)
- Footprints: all walkers classify as designed (citizen soles, headcrab pads, antlion claws, vortigaunt and crow three
  toes, manhack nothing). Feet probe the blood at their own lateral offset (citizen 3.6 u, headcrab 5, antlion 13,
  vortigaunt 5, crow 1.2): the first run poured 4 narrow 9 ml dots per lane and only the crow stepped in one; with
  pools across the lane every walker printed (citizen 8, headcrab 40, antlion 12, vortigaunt 7, crow 18 prints).
- Live patch cap: 144 patches made in one frame (the 16-surface test) left the last spots' blood waiting for a slot
  for good - eviction only ran when a patch was created, and by then every slotted patch was busy (bakeNow / needSlot)
  or the settle time was 600 s. Update now evicts the quietest patch (quiet >= 1.5 s, one per frame) while patches
  holding impacts still wait for a slot (cl_surfaces.lua, Evict(minQuiet)). TakeSlot is no longer called again in a
  frame once it failed.
- Frozen blood: the hoarfrost was coarse noise (crackPos x 0.6) at up to 65 % white - pools on ice / snow turned into
  white-and-grey camouflage blotches. Now fine (x 3.2), at most 32 % over the red; the glaze and glints stay.
- Bubbles (boiling / acid fizz): one bubble in every cell read as a regular dot grid. About half the cells hold one,
  of different sizes, anywhere in the cell (ghmpb_bubble); acid cells larger (crackPos x 0.7, was 0.9).
- Pale half moon over fresh pools seen from ~50 deg above: ghmpb_debug_view 3 (reflections / highlights only) showed
  it, ghmpb_reflections 0 did not remove it, the sun was not visible there - the key light of the local light field
  (measured: probe directions differed by 14 deg between the two patches the pool straddled, one nearly along the
  mirror direction) on a mirror-smooth, still mounded pool, clamped at spec 2. The key lobe is now capped at 0.04
  after the light-unit scale and widened to roughness 0.4 (was 0.22), so it changes slowly with the probe direction; the screen-space reflection takes the relief normal at 35 % and its grazing gate is
  stricter (1 - 1.8 R.N), so sloped fresh pools no longer reflect the lit floor beyond them.
- Material system reload (mat_specular toggled, other video settings): materials made before it that sample a
  texture draw nothing afterwards - bound by name at creation or SetTexture'd alike - while constant-output
  materials (blit) still work and materials made after it work. Detection: a 4 x 4 float canary target filled by
  blit and copied into the readback target (pixel 127, 126) by a peek material that samples it; two wrong reads ->
  R.Rebuild (cl_render.lua): clear, new GPU.session nonce (fresh material names), slot pools and slot counters reset
  (render targets are found again by name), budget body / patch counts reset, client files included again (as a
  Lua refresh), profiler re-instrumented. Char decal materials now go through GPU.CreateMat too (session names).
- Hook priority: see 1.15.0 above. Wrap mode: PhysBlood's hooks stay in the table; each other hook of
  EntityTakeDamage / PostEntityTakeDamage is replaced by a wrapper that first runs PhysBlood's handler, once per event
  (event key: entity, damage info object, type, position, attacker, engine tick - not the amount, which a hook that
  ran before the wrapping caught up may have scaled), then the addon's own function with its results unchanged
  (entity-keyed hooks get their key passed through). Checked every second; priority off or ULib puts the originals
  back. The engine mock (tests/mp_mock) now keeps the hook.Call it saw first, like the game.
- Test setup notes: NPCs spawned for a test are only sent to the client while in the player's PVS (a test spot behind
  a wall from the player's position: AddOriginToPVS in SetupPlayerVisibility). A burning citizen runs off its pool.

## 1.17.0 - big-fight performance pass (gm_construct, 30 citizens bleeding, ~12 hits/s, governor off)
- Measured with the dev harness (devharness/cmds/s_perf6.lua + c_perf7.lua: real frame time from a SysTime
  PreRender timer - RealFrameTime is clamped at 100 ms and hid the worst of it). Same scene before / after:
  frame 126.2 ms (7.9 fps, p90 190) -> 99.7 ms (10.0 fps, p90 121); blood off 45.9 ms. The blood's own CPU time
  (profiler laps) 40.0 -> 29.5 ms; the blood's share of the frame 80 -> 54 ms (-33 %).
- Per part before -> after (ms per frame): wounds 5.3 -> 2.9, hands 3.6 -> 1.2, smear 1.6 -> 1.0, bodies:gpu 3.5 -> 1.8
  (body sim passes 62 -> 31, force renders 19.5 -> 5.8, stamp renders 24 -> 16.5), body impacts 3.6 -> 1.7 (110 -> 45),
  world patch steps 71 -> 38 (world:gpu 4.9 -> 4.3: stepping is not most of it), drop spawns 233 -> 85 a frame
  (thinning x2.65, same blood). Unchanged: drops in flight stay at the 1400 cap (the native step spends its 3 ms
  trace budget, landings included), draw:world old ~4.1 ms for 278 settled layers on screen (15 us each),
  draw:bodies old ~3.4 ms (includes GHM FLESH's wound layer).
- What changed: one longer step instead of two when a frame is slower than 1.25 steps (world patches up to 2.5 steps /
  0.1 s, bodies up to 0.12 s - the shaders' flux is bounded, stable at these lengths); body force fields re-rendered
  at most every other frame below 20 fps; a wound's new emitter merges into a live one of the same kind on the same
  bone within 2.6-5 u (rate and reservoir add up); skin stamps from wounds gathered and stamped every 0.2 s; body
  impact merge radius grows with the fight; flying-drop thinning (P.Thin: spawn rate over 600/s or the list over
  60 % full -> up to 3x fewer, bigger drops; forensic spatter too); hands / smear check the 4 nearest every tick and
  the rest round-robin within ~1 ms; light probes shared on a 32 u grid with a 14-probe-a-frame budget (older probes
  of the same layer reused up to 3 s) - at 8 fps the 0.12-0.5 s cache ages had expired every frame for every layer;
  matrix constants uploaded from 16 numbers (no tables), the flashlight looked up once a frame, model material
  counts cached per body; every settled world layer has its own material (constants set once).
- Not CPU: ~25 ms of the 54 were outside the blood's laps (GPU, Lua GC, engine) - see the second pass below.

## 1.17.0 - big-fight performance, second pass (same scene; NPCs now named so GHM Euphoria leaves them standing)
- The stress test's NPCs get a targetname: GHM Euphoria does not knock named NPCs down. Without it Euphoria turned the
  shot NPCs into ragdolls and back (body swaps every few seconds), which changed the scene (12 hits/s instead of 18)
  and was involved in the crashes below. Numbers of this pass are therefore heavier than the first pass's (18 hits/s,
  31 combatants) and the blood-off baseline itself moved between game launches (28-39 ms): compare A - B.
- Result (runs 275-279): A full 66-77 ms (13-15 fps), blood off 28-35 ms; the blood's share ~38-44 ms (first pass 54,
  before 80). The blood's own CPU ~29 ms, ~5 ms of it GHM Flesh's wound layer (it is drawn from inside our body pass:
  measured by drawing it from its own hook instead, our body pass alone is 1.3 ms). Lua garbage of the blood
  ~2.0-2.5 MB a frame (first pass ~2.6-3.7).
- Ablations (run 278, frame ms): full 74, no live overlays 79, no settled layers 79, no body sim 72, no world sim 66,
  no drop drawing 74, blood off 35. Within the noise (+-5 ms) only the world simulation shows: the frame is CPU-bound
  now; drawing is not what limits it.
- Flying drops: the list sat at its 1400 cap. The solver's trace budget (3 ms) counted the landings, ~40 us each:
  ~60 landings ate it, ~100 drops a frame were traced, each drop was looked at every ~1 s and new ones were refused at
  the cap. Landings are counted apart now (N.costPer = handing segments over + trace + corpse test): ~470 segments a
  frame, 360-500 drops in flight. Thinning also follows the solver (P.thinK: spawns over 45 % of the segments a frame,
  or landing work over 2.5 ms a frame -> up to 6x fewer, bigger drops), thinned drops do not break up in the air (they
  burst back into 2-6 and undid it), and the count / thinning are worked out once a frame (the C++ count walked its
  list for every spawn).
- Settled floor blood (~280 layers on screen): drawn in the main view only - the water's refraction view shows only
  what is under the surface, so layers / patches / bodies that do not reach into water are left out of it (with the
  gm_construct lake on screen every layer was drawn twice, and the two view sizes made every layer set its constants
  twice a frame). Every layer carries an element state (cl_elements gives each patch one, mostly all zero): only
  boiling / fizzing / glowing ones count as animated now (EL.Word >= 16) - all layers had been set every frame.
  Result: ~20 of ~190 layers set a frame, draw:world old 4.1 -> ~2 ms.
- Garbage: GPU.UploadImpacts writes the impact table straight into the mesh (8 tables per impact before), GPU.Quads /
  FullQuad without a closure and tables per call, impact positions as numbers (im.px / py / pz), one impact record
  for all patches of the same plane a splat reaches over, bed samples with two reused vectors (~0.4 MB a frame while
  new patches trace their beds; the bed budget also shrinks in a fight, V.BedMul), wound emitters from the per-frame
  bone frames (U.BoneFrame) instead of a bone matrix + LocalToWorld each, the native module v5 filling two reused
  tables (Segments / RenderData) - the world update went from ~0.9 MB to ~0.3 MB a frame.
- Patch lookup: live patches first, the impact's own cell first, plain-number geometry, the last patch tried first;
  a splat's neighbour on the same plane by its key.
- Readback: the interval follows the measured GPU wait more (rbMs x 0.05): ~28 ms per read in the fight, every ~1.4 s.
- Lua refresh / ghmpb_rebuild: cl_native keeps the loaded module on G.Native (a refresh used to lose it until the next
  map), cl_entities clears GHM Flesh's wrap flag so Flesh wraps the new functions again.

## Crash under GHM Euphoria body swaps (October 2026) - not reproduced without Euphoria's dev harness
- Four minidumps (Sep 30 20:27, Oct 1 02:21, 14:19, 15:14 UTC; GarrysMod/crashes) have the same stack: a DEP fault
  executing heap memory, from lua_shared's C-function call (`call rdi` under lua_pcall) during a client hook that
  client.dll calls through CLuaGamemode::Call (id 0xa4, from a game-system update - Think). The "C function" address
  points at a Lua upvalue object: a Lua closure was dispatched as a C function - a freed or corrupted function object
  in the client Lua heap.
- The two crashes today came while GHM Euphoria's dev harness was running its tests (hostname ghmeu_test) and the
  PhysBlood stress test was shooting NPCs that Euphoria knocked down (14:19: during a config change; 15:14: 3.7 s in).
- Experiments with Euphoria's addon on but its harness off (game launched without +hostname ghmeu_test), 30 unnamed
  NPCs knocked down and swapped by Euphoria: blood off on the client - 166 swaps in 45 s, no crash; blood on,
  PhysBlood's hand-over (Render.Transfer) skipped - 166 swaps, no crash; blood on with the hand-over, every step logged -
  174 swaps, no crash. So neither PhysBlood's blood load nor its hand-over crashes on its own; something only present
  with Euphoria's dev harness running is involved. Not resolved here (GHM Euphoria's files are another session's).
- gmcl_ghmpb_native (v4 / v5) is the only third-party binary module loaded in all dumps (it always is); reviewed: it
  keeps no Lua references, uses at most 10 stack slots and the ILuaBase vtable has no virtual destructor (MinGW and
  MSVC agree on the layout).
- Dev harness: devharness/cmds/s_perf9.lua is shared-game safe (others' NPCs and ragdolls left alone, the player and
  the AI settings put back, aborts when an NPC that is not ours is made or hurt); c_prof_head.lua profiles allocation
  and time per function with the collector stopped for 25 frames.

## 1.18.0 - explosion dust, fresh blood, flies (shader build b66)
- ps_3_0 temp registers (32) are the binding limit of the film shaders, not instruction slots. fxc at /O3 schedules for
  latency: it hoists independent work (all three specular lights at once, both Kubelka-Munk layers' four-band values,
  loop-invariant normalize() out of loops, constant registers copied into temps) and runs out of registers on the world
  shaders at the smallest change - the same source swung between r28 and "X4505" depending on unrelated edits. What
  worked (measured with tools/slots - D3DCompile + D3DDisassemble, "| temps r0..rN" - and a liveness pass over the debug
  listing, tools/live/live.py):
  * the film shading split in two (ghmpb_filmSpec: normals, highlights, reflection; ghmpb_filmDiffuse: the layers), the
    world shader's screen-space reflection mixed in between them
  * the lights in a [loop] over 3 (selected, then normalised); the two layers in a [loop] with a [branch] per layer
  * the surface material values in a 64 x 8 F16 table texture (GPU.MatTable, 2 x 2 texels per value block so bilinear
    lookups are exact; two lookups of one row offset by a fraction of a texel so fxc does not merge and keep them)
    instead of ~14 static globals decoded at the top of main
  * irradiance E passed into the film functions instead of the low-passed frame (one float3 less alive)
  * the world film shaders (surface_ps30, surfstatic_ps30) compiled at /O1 (tools/build_shaders.sh): /O3 r31+ or over,
    /O1 r29 / r28 at about the same instruction count (live 3432 slots, static 3202). Bodies stay /O3 (r30 / r29).
  * the cubic fit of the sRGB curve (ghmpb_toLinearFast) RAISED register use on the body shader (r29 -> r31): fxc
    vectorises it and keeps more alive than pow's per-channel sequence - kept the exact curve where single values are
    decoded
- The accumulator's z is the dust a live layer caught (elem_ps30 op 14, additive). The readback clear wrote 0 to rgb:
  now a multiply blend (BLEND_ZERO, BLEND_SRC_COLOR) of (0, 0, 1) keeps z (and alpha write off keeps w).
- Dust storage: live world / body layers acc.z; settled world layers a pooled RGBA8 target of their own (b = dust / 2,
  half the layer's resolution, only for layers that caught dust); baked bodies the alpha of their aftermath target
  (bake_ps30 c0.w = 1 adds acc.z / 2; the alpha was a constant 1 on bodies). Dust kind (+ soot) per layer / body, the
  kind with the most deposited dust wins; shaders get kind + 16 x soot.
- Dust is drawn in passes of its own (dustworld_ps30 / dustbody_ps30 over worlddust_vs30 / modeldust_vs30 - the blood's
  vertex shaders with a little more depth bias), alpha blended, right after the layer kind it covers so they read the
  same frame copy for their irradiance. Only layers with dust are drawn twice.
- Dust events: the server's blast path (damage with DMG_BLAST, once per blast within 160 u / 0.6 s) and explosion
  sounds ("explode" / "explosion", not loops, physcannon, energy, "distant", sound level < 100 or ambient_generic /
  env_soundscape - the map's ambience) both go through EL.Blast: wave + flash + dust (radius clamp(2.2 x damage,
  150, 520), strength clamp(damage / 90, 0.4, 1.5)). Thumpers: a little dust (220 u, 0.25). With GHM PhysFX loaded
  (global GHM_PFX) the cloud particles are left to it; only the deposit on the blood stays.
- Ground kind: seven traces around the blast (centre + 40 u ring), majority of G.DustKindOf; water under it (or no
  ground within 260 u) = none; strength x (1 - height / (1.2 r)). Six pulses over 4.6 s (weights 0.18 .. 0.14, 1.5 x
  strength at the centre in total) over a disc growing from 0.55 r to r; soot share clamp(0.75 - d / 0.6 r, 0, 0.75).
- Flies (CPU only): swarms per 96 u cell of world layers with >= 2500 mm3 of blood on floors, and per ragdoll in the
  body domains; count = cap x clamp((age - 20 s) / 120 s) x weather x (indoors 0.45) x ghmpb_flies_amount; weather from
  StormFox 2 (temperature (T - 8) / 10, night x 0.25, rain x 0.3). Landing spots on pools come from the GPU pool
  probes (G.Smear.RequestProbe: wet h > 0.02 always, dried s > 0.05 half the time); on bodies the wounds (G.Wounds
  bodies[ent].wounds, bone + local position) and the face. Swarms beyond 1400 u are not simulated one by one; coming
  back into range their flies start on the blood. Disturbed by people moving within 56 u, wounds on the body, blasts.
  Drawn as three vertex-coloured quads per fly in one mesh (render.SetColorMaterial), lit by render.GetLightColor.
- In-game pass 1 (b65, gm_construct, October 2026): no Lua errors; dust reaches live and settled layers; flies come and
  render. Fixed in b66:
  * dust read as a uniform bright orange sheet: the soaked tint was exp(-mua x 0.06 mm) - at blood's green / blue
    absorption that leaves red-orange at full brightness. Light scattered inside a soaked granular layer crosses the
    blood between the grains many times: path 0.32 mm (snow, diluted by its melt: 0.1), per grain (soakG = soak x
    clamp(0.25 + 1.1 (1 - grain noise) + 0.4 (1 - d))) so grains sticking out of a thick crust stay lighter, wet
    darkening x 0.5 (snow 0.8), + 0.028 white from the grains' own surfaces (red-brown, not pure red). Coverage
    smoothstep(0.80 - 0.42 d, 0.95 - 0.42 d, t), d capped at 1.25: specks and rafts for a little dust, a holed crust
    for a lot (was saturate((t + 0.75 d - 0.85) x 5): full cover from d ~ 1).
  * the meniscus rim was a dark outline from above: rimT scale 9 -> 6, darkening 0.45 -> 0.25.
  * flies found no landing spots: a pool of 30 000 mm3 is a few units across in a 40 u layer, so random points of
    the layer missed it (~3 %). S.Impact notes where blood landed (>= 30 mm3, per 96 u cell of the layer centre, the
    12 largest kept, dropped 10 s after the cell's blood is gone); 85 % of the probes start within 1.3 x the splat
    radius of a note.
  * the buzz "stuck near players": it played every 3.5 - 6 s at each swarm's centre within 320 u, landed or not, and
    scattered flies circled the centre at 30 - 70 u - around whoever had scared them. Now: a short clip (HL2's
    ambient/creatures/flies1-5 are 0.4 - 1.1 s, no loop points) from the fly in the air nearest the player, every
    2.5 - 5 s per swarm (faster with more in the air), at most one per 1.2 s overall, sound level 50, none within 300 u
    of no fly in the air; scared flies go 110 - 170 u off on the far side from the disturbance (F.Disturb keeps
    sw.fleeFrom) until calm; a person standing within 28 u of the swarm centre keeps them off.
  * env_explosion with nothing in reach sent no dust: no damage, and its sound is played by the explosion temp entity
    on the clients, not seen by the server's EntityEmitSound. Server: AcceptInput "Explode" on env_explosion
    (iMagnitude), EntityRemoved of npc_grenade_frag / grenade_ar2 / rpg_missile / apc_missile / grenade_helicopter /
    npc_satchel / npc_tripmine and of broken explosive props (model: explosive, gascan, propane, PHX bombs; health
    <= 0) - not during a map cleanup. Client: EntityEmitSound of the explosion effect's sound (BaseExplosionEffect /
    weapons/explode*) within 4000 u -> G.Dust.Blast(pos, 264, 1.3, nil, "cl"); the server's event for the same blast
    (within 1 s and half the radius, source "sv") is not added again.
- b67 (Lua only, shaders still b66) - the buzz was still "stuck near players" after b66. Cause: body swarms formed on
  any ragdoll with blood, including the LIVING - GHM Euphoria knocks a player or NPC down into a prop_ragdoll (the
  owner hidden, GHMEU_Rag on it; PhysBlood's domain and wounds move onto the ragdoll with living = true) and Z-City's
  fake ragdolls. The swarm's clock was the domain's creation, so a player bloodied minutes earlier had a full swarm
  on him the moment he went down, buzzing at the orbit camera and following him about. Now a body swarm needs a corpse
  (F.DeathTime): W.bodies[ent].dead (death time), else not in F.LivingRagdolls() (alive players' GHMEU_Rag /
  FakeRagdoll, any npc_* with GHMEU_Rag) and not G.LivingRagdoll (Z-City), else a W body moved over from a living
  character (no corpseT0) is alive; a ragdoll without wounds of its own (a prop ragdoll with blood on it) is a corpse
  since first seen. The clock starts at death. Flies also keep off pool blood within 48 u of a living ragdoll. And the
  buzz is heard only within F.HEAR_DIST = 160 u (falloff (1 - d / 160)^2, sound level 45, at most one per 2 s, 3 - 6 s
  per swarm): walking through a bloody battlefield is no longer one long buzz. (Checked: GHM SoundTrace detours
  sound.Play but passes "ambient/" sounds through at their own position.)
- b68 - "still hearing flies when ragdolling happens". Two causes:
  * a knocked-down NPC is hidden by GHM Euphoria (SetNoDraw) and an EF_NODRAW entity is not sent to the clients at
    all, so its GHMEU_Rag never reaches them; and a character with no blood before it went down has no PhysBlood
    hand-over, so the first hit on its ragdoll made a corpse body (corpseT0). Now the server marks the living
    ragdolls itself (sv_compat.lua: NW2 bool "ghmpb_alive" while GHM_EU.Chars[rag].mode == "alive", every 0.5 s);
    G.LivingRagdoll and the flies read it. Flies also need the body to lie still: its centre is checked every frame
    for the bodies within the simulation range, a move > 3 u takes them off and keeps newcomers away for F.STILL = 8 s.
  * most of what was heard is GHM FLESH's own flies (cl_fx.lua: a buzz every 0.3 - 0.9 s at sound level 62, up to
    900 u), driven by its decay (cl_decay.lua): IsCorpse = any ragdoll, so a living character's knock-down ragdoll
    starts rotting (deathT), its body goes back to the player / NPC when he gets up (FLESH R.Transfer has no living
    flag, deathT is kept) and he rots on, with the flies, from then on. Not PhysBlood's code (GHM FLESH files are not
    edited from this project): the fix for it is in "Claude outputs/GHM_FLESH_flies_fix.md". Applied at the user's
    request to the C: install's GHM FLESH (cl_decay.lua: no rot on a living ragdoll - ghmpb_alive / GHMPB.LivingRagdoll /
    a living player's GHMEU_Rag or FakeRagdoll - and deathT cleared once the body is on a living character again;
    cl_fx.lua: each fly's state in its think closure - the weak table keyed by the particle userdata lost them, so the
    flies died at their first think and only the buzz was left - and flies 0.32 - 0.46 u, was 0.18 - 0.28).
  * PhysBlood's pool swarms check their landing spots again (the oldest every 2.5 s): a spot whose blood is gone
    (washed away, smeared off, soaked in, burnt off) is dropped and the flies on it take off; 10 empty probes in a row
    with no spots left and the pool's flies leave (still probed every 2 s: blood there again brings them back).

## 1.18.1 - drag smears, props in blood, blood type colours (shader build b67)
- Found in the 1.18.0 feature clips: a dragged body left no smear (0 smears, 0 pushes for the whole session), a barrel
  rolled through a pool without wiping it or picking anything up, and a yellow pool had red beads at its edge.
- Smears: cl_smear Parts() cached the contact-part list per model even when it was empty. A ragdoll seen in its first
  client frame reports no bones (GetBoneCount 0 / invalid names), so the model got an empty list for the rest of the
  session - every body of that model, no smears, no pool pushes, no pickups. Only non-empty lists are cached now (the
  same for cl_hands' "no hands" rig). Not GHM Matter: its Jolt debris world is separate from VPhysics, and its body
  layer skips ragdolls. Not the menu settings either (ghmpb_smear_amount 0.74 only thins the smear).
  tests/mp_mock/test_client_smear_props.lua reproduces it (fails on 1.18.0, passes now).
- Props: the contact footprint was kept in the prop's own frame and only redone after it turned ~6 degrees, and the
  ground trace started at the lowest corner of the box. A rolling drum lost contact every tick (its turned box reaches
  under the floor - the trace started inside the ground) and never smeared. Now: ground traced down from the middle of
  the box; contact points from a grid (up to 4 x 4) over the box seen from below, traced up against the prop alone, in
  world space, redone whenever the prop moved or turned (a resting prop keeps its points); at most 6 of them stamp.
  The path is the movement of the contact patch, so sliding, dragging and rolling all smear.
- Props and pools: a probe answer takes ~0.3 s - a drum at 170 u/s was 50 u past a small pool by then and the answer
  was thrown away (it was looked up near the prop's current position). Probes are now queued per prop with where they
  were asked, the motion at that moment and the trace; each answer wipes / shoves the pool and picks up blood where it
  was asked. Resting soak uses the latest answers near each point.
- Props' carried blood: OnUnderside counts the whole volume itself. It relied on E.Impact calling back, which it does
  not when it joins a stamp to the previous one at the same spot (slow drags) or has no room for the prop
  (ghmpb_max_entities): blood picked up and never counted, never smeared. E.Impact's join path now calls back too
  (for blood landing on props), skipping the props' own pickups (extra.props).
- Blood types: a world patch that only ever received blood by flowing in from a neighbour kept the default type 0 and
  oxygen 0.75 - its outflow beads at the patch border (hanging-drop sites on a floor), drips, footprints and probes
  were red next to a yellow or green pool. The patch takes the type and oxygen of the blood flowing in (S.StepAll, when
  a neighbour joins a step with no blood of its own).
- Colours (ghmpb_common.h, cl_util MUA): yellow absorbed too much green - thick pools came out orange-brown, not the
  mustard yellow of its body albedo: 4-band mu_a (0.6, 0.5, 1.6, 16) -> (0.5, 0.42, 0.6, 20), 3-band (1.2, 2.2, 18) ->
  (0.9, 1.2, 16). Zombie read as the same dark brown as venous red: green band 13 -> 7 (4-band), 13 -> 8 (3-band), an
  olive cast. Thick pools (sRGB, unlit): red (96, 24, 20), yellow (141, 125, 51), green (50, 101, 53), zombie (58, 44, 27).
- In game (C: install, Oct 3, gm_construct hall, the user's own settings): the drag clip logged 1164 smears, 292
  pushes and 292 pickups (1.18.0: 0 / 0 / 0); the props clip 575 smears, 38 pushes, 38 pickups and 3 splashes (the
  drum leaves a track past the pool, the dropped machine splashes and gets splashed); the blood-type clip shows no
  hanging beads or resting drops by the pools and every patch there holds its own type. No Lua errors on load.
- Not PhysBlood: a hollow prop landing hard (the washing machine) turned black - GHM Matter's DMM shell drawing
  (ghm_matter_dmm). Blood on props draws correctly with GHM Matter on (devharness test 314); the props clip runs with
  ghm_matter_deform 0 and ghm_matter_dmm 0 (restored after the clip).

## 1.19.0 - pools, froth, fast drops (shader build b68) - from source, not yet verified in game
- Asked for (Oct 4): more noticeable pools that the floor texture does not overshadow; fast drops that leave elongated
  stains with a droplet travelling on in a rivulet; pools that squiggle and deform with the geometry and the slope, and
  nearby pools that join on contact; frothy, shiny bubbles.
- Looked at the 1.18 clips first: pools on gm_construct's concrete read as flat maroon decals - the grain printed
  through, little gloss (F0 0.022 in a dim hall), straight cell-grid edges.
- Pool look (ghmpb_pool_look, world layers; bodies get 0): thick wet blood gets F0 x (1 + 1.3 pool) plus a meniscus term,
  specW x 1.5, optical depth x 1.45, and the substrate behind it is blended to the patch's mean albedo (Rpx -> SC18.rgb:
  the floor is seen through a scattering layer). Packed into SC1.y with the type pair: pair + 64 (pool * 10 + 32 froth * 10).
- Contact line (sim, floors / slopes up to gl 200 cm/s^2): aux.y of a dry cell next to the blood is
  0.4 count8 + 0.45 ring8(r 2.2) + 5 if opposite cells (ring pairs, or 5 cells out on axes / diagonals) hold > 0.12 mm;
  capF's floor goes 0.5 -> 0.2 there. numpy (tests/sim_hf.py, mirrored): two pours 42 cells apart join with a neck,
  volume exact to 1e-12, an 80 deg wall run identical to 1.18 pixel for pixel.
- Slopes: pforce bakes lanes into the pin noise along the downhill direction (2..7 deg ramp in, out above ~40 deg). In
  numpy the effect on a 25 ml pour at 4-8 deg is modest (wavier sides of the tongue) - the bulk flow dominates.
- Froth: stamp c2.z = ghmpb_froth on floors (0 on steep patches and bodies, whose aux.z is the column weight); share by
  kind - splat: (speed - 250) / 900 x (0.3 + 0.7 oxy), source 0.08 + 0.5 (oxy - 0.55) / 0.4, expirated 0.85. The sim
  carries frothy volume in aux.z (out / in with the edge and levelling transfers, not across patch borders) and decays
  it exp(-0.017 (1 + 2.5 cf) t). Shading: the film's air-bubble domes get denser and taller with froth (f.froth), and
  froth lightens the blood through o.dmul plus a pale pink seed in the highlights (no extra value through the light loop).
- ps_3_0 temp registers (live world shader, /O1): the additions took it over 32. Back to r0..r31 by: decoding late-used
  constants from max(const, -x) with x >= 0 computed at the use (fxc hoisted every constant-only decode - element
  fields, the type pair, fabric, hue, the pool look, the debug view - to the top and held them), a grey F0 as one
  scalar, the ice glint as a tight Blinn-Phong instead of a second GGX, the halo folded into one value.
  surfstatic r26 (was r28), stamp r31, sim r30, bodyfilm r31.
- Fast drops (ghmpb_drop_slide): P.Land stretches world stains x (1 + 1.2 amount f (1 - sin^2 a)), f = (vt - 140) / 520;
  12-45 % of the drop goes to R.Slide (cl_runs) from 1.15 R e ahead: a head with a velocity, contact-line drag
  (2.2 + 3 rough) v + 40 + 90 rough u/s^2, gravity x 0.3 only on gentle slopes; trail stamps kind 7 at 0.75 width; it
  keeps 0.45 ul for the final bead; on a steep face it turns into a run below 6 u/s. tests/mp_mock/test_client_slide.lua:
  a 8 ul drop at 400 u/s along the floor -> stain x 1.43, 2.16 ul slides 3.4 u (65 mm), 3 trail stamps and a bead, volume
  exact; on a wall it becomes a run. test_client_look.lua: every pair / setting decodes exactly in single precision.
- 1.19.0, second pass (same day, shader build b69) - asked for: "better bleeding visual, not that long stamping streak but
  natural", "more blood wetness and reflection like fluid". In the 1.18 clips the blood on bodies was a flat, matte,
  dark-maroon patch with a smooth cut-out edge (mouth / chin) and long thin streaks of even width (down the neck, down a
  vest); fast spray flew as long dark lines.
  - Wet look on bodies: the pool look now reaches the body film shaders (E.LookPair packs it into their SC1.y; no froth):
    from ~0.015 mm a wet film gets F0 x up to 2.8, highlights x 1.5, turns glossy sooner (roughness blend 0.008-0.14 mm,
    was 0.015-0.25), and the key light's sheen cap on bodies is 0.12 (0.04 kept on the world - 1.17.0 half moon). No
    extra optical depth on bodies (thick blood there is dark enough). World pools: from 0.06 mm (was 0.1), F0 x 2.8.
  - Runs on bodies (simbody): the diagonal pinning on steep parts 1.8 -> 1.3 - a run spreads a little sideways, wider and
    uneven, instead of one thin streak of the same width.
  - Body edges: a second, finer octave of the organic edge warp (0.7 texel) - ragged at texel scale, not a cut-out.
  - Fast drops: the speed stretch of the stain is at most x 1.5 now (1 + 0.45 f (1 - sin^2 a)); the droplet carries the
    motion on. Flying drops: the motion trail is capped at 12 drop radii (was 28) - spray reads as drops, not lines.
  - Registers: surface r31, surfstatic r26, bodyfilm r29, bodystatic r30, sim r30, simbody r29, stamp r31.

## 1.20.0 - PBR blood (look)
- Why 1.19 read as juice / jelly: the irradiance E = blurred framebuffer / texture-mean albedo was taken per channel, so
  albedo errors (gamma-space mip mean, displacement blend textures, model textures with baked shading / phong) became
  coloured, too strong light - in-game pools measured 1.2-2x the floor's red and 14-25x too much green / blue (thin,
  orange, see-through). Now ghmpb_irradiance: luminance ratio with an albedo floor of 0.08, only 30 % of the light's
  colour kept. visH saturates (0.55 (1 - e^(-h/0.12)) + 0.2 (1 - e^(-s/0.15))): level pools, relief only at the rim.
  No pool-look boosts, no key-light sheen, no fresh-pool swell; F0 0.027 wet / 0.04 dry crust, liquid roughness 0.03.
- Optics checked against spectral ground truth (tools/pbr/spectral.py: Prahl Hb / HbO2, mu_s' 1.6 (600/lambda), KM,
  CIE 1931 fit): thick oxygenated pool sRGB ~(99, 11, 14) at a 0.25 floor's light. musWet4 fitted to (1.54, 1.54, 1.14,
  1.72) (mean error 4 sRGB steps, was 6). Dried blood refitted (tools/pbr/fitdry.py) with ageing (aftermath layers):
  fresh mu_a (10, 2.6, 13, 14.5) S (0.75, 0.8, 0.7, 0.6) -> aged (14, 4.4, 11.5, 14) S (1.1, 1.05, 1.1, 0.9); a crust
  that kept its surface gets a Saunderson term (n 1.5). Flying drops are opaque (KM diffuse transmission only).
- Settings: ghmpb_pool_look is now "Wetness" (thinner films read as liquid above 1, tacky / dull below), ghmpb_reflections
  "Shine" (now scales highlights too), ghmpb_gloss "Gloss (sharpness)". The floor blur under pools (hideK) is fixed 0.9.
- Registers: surface r30, surfstatic r25, bodyfilm r28, bodystatic r27. Shader set ghmpbb70. tools/pbr/render.py renders
  1.19 vs 1.20 offline. Not yet seen in game (GHM tests it himself).

## 1.20.1 - mirrored UVs (legs bled on both sides)
- Character models often map both legs / arms / face halves onto one mirrored texture region. Body blood lives in UV
  space, so a hit on one shin painted the shared texels and showed on both legs; the force / position passes of the
  shared texels came from whichever copy was rasterised last, so runs, gravity and drips of one leg were the other's
  (blood in the wrong place).
- ModelInfo rasterises each material's UV triangles into a 64x64 grid per UV winding; both windings significant
  (> 4 % of the UV area each) and overlapping (>= 8 cells, > 15 % of the smaller) = mirrored. Such a part gets a twin
  sub (hand 1 / hand 2, the twin at the small size; at most two per body; ghmpb_uv_mirror 0 turns it off; if the budget
  has no room the twins are dropped and the part shares as before). ghmpb_uvcheck prints the result for a model.
- Shaders keep their half by hand = (dP/du x dP/dv) . N from screen derivatives (ghmpb_uvHand: ddx P x ddy P times
  ddx u ddy v - ddx v ddy u - the same sign in the UV-space passes and on screen, whatever the mesh winding). Codes:
  stamp c2.w (applied as an output mask at the end - stamp is at r31; a clip at the top overflowed), elem c2.w, force
  c3.w = motion + 4 * code, dustaft c2.x, body film / static SC2.w = bump + 4 * code, body dust DC3.x. Layers of a body
  with twins are drawn in two passes (one material override per index per draw). Shader set ghmpbb71.

## 1.21.0 - blood takes on the surface's normal map
- World: the engine gives Lua no texture coordinates of world faces, so cl_bsptex.lua reads the map file once (a
  coroutine, ~4 ms a frame): planes, texdata names / sizes, texinfo (texture axes over the texture size, lightmap axes),
  faces (plane, side, texinfo, displacement flag, lightmap mins / size). B.Lookup(pos, normal, texName): faces of that
  texture on the plane (displacements: any plane facing up) whose lightmap rectangle holds the point (score = distance
  outside, units). Compressed lumps -> off for the map. Tested on maps/ghmpb_bricks.bsp (10594 faces, 400 / 400 points
  found).
- S.AssignBump(p): $bumpmap of the patch's material (+ $ssbump flag) and the face's texinfo; meshes carry the texture
  coordinate in t0.w / t1.w (on the plane, as the engine maps the face) and t2.w = relief + 2 * kind. The world film
  shader reads it on s3 (the force field it held there was only used for the texel size: now 40 u * 1.905 * tx), builds
  the frame from the texture coordinate's derivatives (+u, +v as the bodies), ssbump -> normal over Source's bump basis;
  relief patches shift the coordinate with the parallax march (affine in patch uv, from derivatives). surface r28,
  surfstatic r25.
- ghmpb_filmPre: fill = smoothstep(0.15 rd, rd, h + s / 4), rd = relief depth (mm) per kind of surface (material table
  row 3 .y: glass 0.02 .. gravel 2.5; bodies lerp(0.15, 0.6, fabric)).
- pforce_ps30: the normal map's curvature - (div of -n.xy / n.z in the patch's texel axes) - added to curv (grooves are
  concave: thin blood creeps along grout and joints) and its tilt raises the contact-line pinning. c1.zw / c3 = the
  texture coordinate as an affine function of patch uv, c2.w = kind + 0.99 * strength (relief depth / 0.9).
- ghmpb_surface_normals 0 turns it off. Shader set ghmpbb72.

## 1.21.1 - fix: no blood on the world (1.21.0)
- 1.21.0's ForceBake (cl_surfaces.lua, line ~812) called BumpUV and read WHITE, both locals declared further down the
  file: in Lua that is a global read - nil - so every live world patch's force bake raised an error. S.Update stopped
  there each frame, and with it the rest of the GPU block in cl_render (material table upload, dust, and the readback
  that turns the bodies' run-off into drips): no blood on floors / walls, fewer drips. Both moved above ForceBake.
- tests/mp_mock/test_globals.lua: every global any addon file reads (luajit -bl, GGET) must be on the allow list - this
  class of bug fails the suite now (checked: it flags the 1.21.0 file).
- cl_render: the GPU parts (bodies, world, material table, dust, readback) each run in a pcall of their own; after a
  failed part the render target stack / MRT / blend overrides are put back.

## 1.21.2 - fix: a shot into the back of a head bled onto the back / shoulders
- The wound's bone came from the nearest hitbox to the server's hit point. Hitboxes overlap (head / neck / upper chest),
  and inside several boxes the one with the nearest centre won - often the chest for a point low on the back of the
  head. The snap to the skin then searched the chest's mesh points (and its parent / children), and projected the
  point onto the tangent plane of one up to 12 u away: the wound (and all its weeping, stamped at the same place)
  landed on the neck / shoulders / upper back.
- The per-bone snap points were every n-th vertex in model order. Vertices crowd into the face, so the back of a head
  kept a handful of points (synthetic test head: 1 of 160) - even with the right bone a hit there snapped ~4 u off.
- Now: U.EntitySurface also returns the bone of the hitbox the client's ray struck (tr.HitBox; prop_ragdoll: the
  physics bone) when the hit point lies on that bone's hitbox; failing that, U.NearestBone(ent, pos, hitgroup) only
  looks at the boxes of the hit group the server reported (bullets; ignored if > 12 u away). The exit wound uses the
  bone of its own trace. E.Impact gets that bone (no second guess from the snapped point).
- U.Thin: per-bone snap points are cell means on a grid (one per cube and facing direction), the cube growing until
  <= 240 remain - spread evenly over the surface.
- SnapToMesh / RefSnapToMesh: nearest point accepted up to 7 u (was 12), and the point stays put if it would move more
  than 4.5 u onto the plane or the plane's point is more than 3.5 u away along the skin.
- tests/mp_mock/test_client_snap.lua (synthetic person, dense face, sparse back of head, overlapping chest box): fails 5
  checks on 1.21.1, passes now.
- ghmpb_debug_hits 1: red = server hit point, green = wound on the skin + normal, bone name on screen and in console.

## 1.22.0 - lite renderer (no custom shaders): what a Steam Workshop install runs - from source, not yet verified in game
- Why: the GMA whitelist has no shaders/fxc/*.vcs (and no lua/bin modules), so a Workshop install has no shaders.
  ghmpb_render_mode 0 (default) = shaders when shaders/fxc/<prefix>surface_ps30.vcs and stamp_ps30.vcs exist, else lite;
  1 = shaders, 2 = lite. Switching clears the blood (R.ClearAll). Settings > Quality > Renderer.
- cl_lite.lua wraps the addon's entry points (the original runs while lite is off; wrappers are recognised when the
  file runs again, R.Rebuild / Lua refresh): S.Impact / E.Impact -> lite, S.Element 0, E.Element false,
  S.GetPatch nil (no world patches ever made), S/E.WarmSlot false (no render targets), S/E.Update + Draw* no-op,
  E.Get -> the lite body record, Smear.RequestProbe -> answered at once from the lite stains / pools,
  Contact.Grid / NearBlood -> the lite stains, Dust.GpuPass / Draw* no-op, Dust.Any false. cl_render: the GPU block
  of PostRender is replaced by L.Update(dt), PostDrawOpaqueRenderables draws L.DrawWorld (main view only), no frame
  copy for drops, R.Transfer -> L.Transfer, DecalsOff false (body blood is decals), R.ClearAll -> L.Clear.
  cl_particles P.Draw: lite -> L.DrawDrops (same collected drops / hanging drops / run beads).
- World: every stain is a quad from one 1024 atlas (materials/ghm_physblood/lite/stains.vtf, tools/gen_litetex.py:
  4 splats, 2 oblique drops, pool, run, smear, shoe, creature pad, hand, tyre, mist, small drop, bead) with two passes:
  stain_mod.vmt (Modulate, $mod2x, vertex colour = transmittance of the layer, gamma, x 0.5: it darkens / tints the lit
  surface under it - lightmaps, shadows, flashlight exact) and while wet stain_shine.vmt (UnlitGeneric $additive with
  env_cubemap x 0.1 x ghmpb_reflections, vertex colour = the blood's own lit colour x (1 - T^(1/2.2)) from
  render.ComputeLighting at the stain: a thick layer shows dark red, not the near black Modulate alone gives).
  Transmittance: U.BloodTrans (the 4-band model of cl_util, layer = stain thickness in mm). Dry: brown, darker with
  thickness (ghmpb_color_dry). Wet time = drytime x (0.35 + 0.8 h) (pools x 1.5, absorbent surfaces x 0.5).
  Polygon offset from $decal, 0.04 u off the surface.
- Sizes: kind 0 radiusU is the stain radius already (Fo.Stain / spreadRadiusU), elongation min(clamp(1/sinA, 1, 6) x
  stretch, 8) on oblique cells along the tangential velocity; kind 3 / 7 a quad from the point back along the path;
  kind 5 prints by spin (1 shoe, mirrored for the right foot; 2 hand; 3 tyre; 4..7 creature pad), alpha by freshness;
  kind 6 mist; kind 4 nothing. More than 6 small stains (< 40 ul) in one 6 u cell within a second are skipped.
- Stains collect in an open list (drawn per frame) and are baked into static IMeshes of 192 (or after 2 s); a baked
  batch is rebuilt once when its last stain dries (one batch a frame); over ghmpb_lite_stains (default 3000) the oldest
  batches go.
- Pools (kind 1 on floors, n.z > 0.7): one record per pool (max 96, then the oldest becomes a static stain), target
  radius from volume at 1.6 mm, growing with tau 2.5 s x viscosity; drops / pours landing in a pool add to it; room to
  grow is traced in 8 directions (ground filter, flat within 1.2 u) as it grows - blocked on less than half the sides
  it moves away from there, else it stops; pools on the same plane within 0.95 (r1 + r2) join (volume-weighted centre).
- Bodies: engine model decals (util.DecalEx, VertexLitGeneric $decal materials per shape and blood type:
  b{wound,splat,drip,mist}_{0..3}.vmt, $color2 set from U.BloodColour so the colour settings apply). Kind 2 wound,
  kind 6 mist, else splat (size 4.8 x stain radius); a splat where one went on within 1.2 s is skipped, at most 18 per
  1.2 s per body. Wound outflow (kind 1 from W's emitters every 0.2 s): a run per source (bone-local), every 30 ul its
  tip steps 0.85 u downhill along the skin (gravity minus its normal part, U.SnapToMesh onto the mesh, the nearest
  bone there) and leaves a drip decal; facing up it gathers (one bigger decal), overhanging or off the mesh it stops;
  after 24 steps further blood drips off the tip (G.Particles.Drips). Decals are recorded in bone space (30, wounds
  kept) and put on again on the corpse (R.Transfer -> RemoveAllDecals + re-shoot 0.06 s later).
- Drops: camera-facing quads stretched along the velocity (head ru x stretch, tail ru + motion blur), drop.vmt,
  colour from U.BloodColour x the drops' light probe.
- Not in lite: liquid flow on surfaces, film relief / refraction / froth / clotting, live drying, bodies' smears
  (they need the body's wet map), dust in the blood, blood on bodies under water washing off.
- tests/mp_mock/test_client_lite.lua (mode switching + wrappers, stains of every kind, pools grow / join / stop at a
  ledge, probes, batches bake / dry / cap, drops, body decals / runs / drip-off / transfer / colour settings).
- Workshop package: tools/build_workshop.py -> ghm_physblood/ (addon.json, stripped Lua, materials), ghm_physblood.gma
  (GMA v3 as gmad writes it, verified by reading it back), icon.jpg. Test content (brick map, props, their materials,
  the bricktest entities) stays out. Upload: gmpublish create -addon ghm_physblood.gma -icon icon.jpg.

## 1.23.0 - fluid-simulated blood bursts (VAT mesh particles) - from source, not yet verified in game
- Source data: Houdini fluid VAT exports for Unreal (per effect: SM_*.pskx, T_*_P.hdr position texture, T_*_N.hdr, MI_*.json
  with "Number Of Frames", "Position Min" / "Position Max"), in the user's AssetsVAT folder. Decoding (verified offline,
  tools/bake_vat.py): the mesh is a triangle soup (3 wedges per triangle); UV0 addresses the position texture (column =
  vertex, rows = frame 0's block); frame f = rows + f * rowsPerFrame (rowsPerFrame = rows used by UV0, frames = height /
  rowsPerFrame - the MI frame count is wrong for OmniRT_02); position = min + texel * (max - min) in Unreal cm, absolute
  (fluid mode: the rest mesh's triangles are placeholders). Local +X is where the blood is thrown (crown rises along +X,
  ribbons run along +X). The N textures did not decode to unit normals (the exporter's normal-map handling): normals are
  computed from the welded geometry instead. OmniEroded_01 uses the same position texture as Omni_11 (skipped); the
  T1000 FloorBlobs (rigid-body VAT of liquid metal) are not blood (skipped).
- Bake: per frame weld (1e-3), quadric decimation to <= 900 triangles (pyfqmr, borders kept), smooth normals, cm -> units
  / 1.905, Y mirrored (Unreal left-handed) with the winding; empty tail frames dropped (area < 10 % of the largest);
  119-frame sims keep every 2nd frame (15 fps). 12 effects, 5.6 MB: data_static/ghmpb/vat/<name>.dat (format in the
  script header). Materials materials/ghm_physblood/vat/blood_0..3.vmt: VertexLitGeneric, white base, flat normal map,
  phong 48 / boost 6, env_cubemap 0.12, halflambert, nocull; $color2 set in game from U.BloodColour (type 0..3).
- cl_vat.lua: after the map loads, every effect is read (header + frame offsets) and its frames built into IMeshes,
  ~2 ms a tick (mesh.Begin on an IMesh; falls back to BuildFromTriangles if this build does not take an IMesh), one of
  each kind first. Drawn in PostDrawOpaqueRenderables (main view) with SuppressEngineLighting: the ambient cube from
  cl_lighting's probe SH (x 0.75) and its key light as a local directional light (phong shine). Kinds: back (entry
  wounds, thrown between -dir and the skin normal, size 0.32 + 0.18 S, speed x 2.2), fwd (exits, along the shot, 0.45 +
  0.2 S, x 1.8), blunt (blows on exposed blood, cuts along the sweep), heavy (blasts, from W.Blast), jet (arterial beats,
  one per 0.9 s per jet, jet speed > 80), crown (drops >= 1.6 mm, >= 220 u/s on floors, 4 a second, not twice in a 12 u
  cell within 1.5 s). Not beyond 2500 u or out of view; ghmpb_vat_max at once (oldest goes). ghmpb_vat 0 frees the
  meshes. ghmpb_vat_info, ghmpb_vat_test [kind] [size] [speed]. Settings > Splatter > Fluid bursts (VAT).
- tests/mp_mock/test_client_vat.lua (reads the real .dat files: frames, bounds, normals, indices; warm-up builds all 12;
  spawn / draw / end / cap; crown and jet rate limits; toggle frees; the vertex-table fallback).
- Workshop: the bursts go up with it (the user made the sims himself in LiquiGen); build_workshop.py --without-vat leaves them out.

## 1.23.1 - colour of the VAT bursts per blood type
- cl_vat V.Colour(bt): U.BloodColour(bt, 0.75, 120) (the Look settings: brightness, hue, density - all blood), then the
  type's hue (HSV turn, ghmpb_vat_<red|yellow|green|zombie>_hue -1..1 = -40..+40 deg), then x the type's brightness
  (ghmpb_vat_<type>_bright) x ghmpb_vat_bright, in linear light -> the type's material $color2.
- Settings > Splatter > Fluid bursts (VAT): brightness for all bursts, a swatch + brightness + hue per type, reset.
- test_client_vat: only the type's bursts change; red + towards orange, - towards crimson / purple; yellow + towards
  green; the overall brightness scales every type.

## 1.23.2 - fix: no blood on gm_falleritus8 (and maps like it) - from source and the map file, not yet verified in game
- The map (Workshop 706081041, gm_falleritus8.bsp, v19): a ragdoll-drop map. Spawn at z ~14720, landing areas around
  z ~-14000 (world -14912..15936, ~28,700 u between them); func_rotating x 123, trigger_teleport, func_water_analog.
  Compiled without lighting: lumps 8 (LDR lighting) and 53 (HDR lighting) both length 0 - it renders fullbright.
  Nothing in it blocks the addon (no damage filters, no decal settings, no server / client commands); the causes were
  in the addon:
- (1) Far blood never existed. cl_render drops hits > 9000 u from the camera (too far to simulate), and single player
  broadcast everything and kept no catch-up (sv_history sent only in multiplayer): bodies landing at the bottom while
  the player stood at the spawn bled nowhere. Now (sv_core Send) hits and deaths go live only to players within
  G.LIVE_RANGE (9000 u, measured from the view entity) - single player too; the history keeps the rest and hands it
  out when the player comes near (sv_history SendOn: single player too). The client's cut is LIVE_RANGE + 1500.
  Counter: "sv: blood event kept for later (no player near it)".
- (2) Fresh corpses never bled from impacts. The 1.14.0 rule (a corpse with no wound and no blood on it does not start
  bleeding from bumps - meant for burned / shocked bodies) stopped every dropped ragdoll. Now (cl_wounds) a hit >=
  W.HARD_IMPACT (60) opens a clean corpse (0.7 strength); >= W.SMASH_IMPACT (150, a long fall) it bursts open: a spray
  (14..42 drops), a pour onto the floor under it (G.Surfaces.Impact straight down within 64 u), a VAT blunt burst.
  Light bumps (< 60) on clean corpses: still nothing. Counter W.smashes (ghmpb_diag).
- (3) Unlit maps lit the blood black. render.ComputeLighting may read black on a map without baked lighting, which
  turned drops, bursts and the lite renderer's shine black. cl_lighting L.MapUnlit() reads the BSP header once per map
  (both lighting lumps empty); there a black probe (all 6 samples < 0.02) is taken as white ambient light; cl_lite
  L.Light the same. A lit map's dark corners stay dark.
- ghmpb_diag: map lighting (baked / none), live range, corpses smashed open; the catch-up line covers far blood too.
- Tests: tests/mp_mock/test_server_far.lua (near hit live and not re-sent; far crush at 20,000 u: not live, kept,
  handed out once when the player comes near; far kill's pool on arrival), test_client_corpse_impact.lua (45: nothing;
  80: a wound; 400: spray + pour + counted), test_client_unlit.lua (headers: unlit / LDR / HDR-only / missing; one read
  per map; a black probe on an unlit map reads white, on a lit one stays black). test_server_elements updated (single
  player keeps records with elements off).

## 1.23.3 - fix: blood simulated but never drawn on maps with a 2D skybox only (gm_falleritus8_2008)
- The map the report was about is gm_falleritus8_2008 (Workshop 259337103, BSP v20, the same map decompiled with VMEX
  and compiled again; no lighting either, no sky_camera). The player's ghmpb_diag on 1.23.2: 16,069 world impacts
  painted, 314 patches made, a live patch under the crosshair, the simulation running - but no "frames: blood drawn"
  counter and no draw:world / draw:bodies in the frame profile: the PostDrawOpaqueRenderables hook never got past
  its first line. Drops and flies (translucent hooks) were drawn.
- Cause: the hooks returned on their 2nd argument (bDrawingSkybox). GMod wiki, GM:PostDrawOpaqueRenderables: "In case
  of 2D skyboxes it is possible for this hook to always be called with this parameter set to true." A map without a
  3D skybox (no sky_camera) - common in older and decompiled maps - drew no world or body blood and no VAT bursts.
- G.ScenePass(depth, sky, sky3d) (sh_config): true unless the depth pass or the 3D skybox's view (isDraw3DSkybox).
  Used by every render hook of the addon (ghmpb_draw, ghmpb_drops, ghmpb_vat, flies, elements, water clouds, the hit
  debug view) and U.IsMainView.
- Safety net: if the opaque pass never reached the blood in a frame (another addon's PostDrawOpaqueRenderables hook
  returning a value ends the event for every hook after it), ghmpb_drops (translucent pass) draws the layers and the
  VAT bursts there, once (R.screenDrawn / V.drawnFrame per frame). Counter "frames: blood drawn late (...)".
- ghmpb_diag: "drawing: frames drawn N of M simulated | drawn late | main view with the skybox flag".
- The same check is in GHM FLESH (cl_util U.IsMainView / IsWaterView: ghmfl_draw, ghmfl_draw_late, ghmfl_glass),
  GHM Ballistic Damage (GHM_BD_World, _Debris, _ElemMarks, _ElemGlows, _Glass, _QuickMarks) and GHM Matter
  (GHMM_Craters, _Debris, _ElementLooks, _Arcs, _GlassRipple, _GlassCracks): note left for those chats in the C:
  copy's data/GAME_NOTE_2d_skybox_render_flag.txt. Nothing of theirs was changed.
- tests/mp_mock/test_client_skybox.lua (3D skybox view skipped, main view drawn once; 2D skybox main view drawn and
  counted; depth pass skipped; opaque pass cut short by another addon -> drawn late once, with the bursts; a reflection
  view with the flag skipped).
- Also in that diag: 10 fps (97 ms a frame) with the addon at 0.9 ms of it - the rest is the map / other addons.

## 1.24.0 - no long lines: stain length limit, short skids, straighter runs, smash burst - from source, not yet verified in game
- The player's screenshot (gm_falleritus8_2008, October 2026): long needle streaks and thin wiggly lines over the floor /
  wall below a ledge where bodies land. Four sources, reproduced offline with tests/splat_preview.py (a NumPy port of
  stamp_ps30's droplet stain on a dry floor, drops landing ballistically with P.Land's rules):
  * Needles: the stain's length / width is 1 / sin(a) (up to 8) x the drop's stretch (ligaments, ricochet x (1 + 1.4 f),
    fast-drop x up to 1.5), capped at 10, plus a tail of up to ~0.85 R e and "skid lanes" past e = 4. Fast, flat drops (a
    body sliding or tumbling past at 1000+ u/s, spray skimming a floor) all came out at 10x. Now U.SplatShape (cl_util)
    limits it to ghmpb_streak_max (3.5 by default, ~16 deg; 10 = the old look) before the stamp: the speed is kept (the
    shader's energy / splash use it), only the angle the stamp sees is steepened, and the stretch is limited to
    1 + 0.35 (max - 1) when over. Stains within the limit are untouched. Called by S.Impact, E.Impact and the lite
    renderer (L.WorldImpact; its own e is also capped by the setting). No shader change (the tail and lanes follow e).
  * Thin rivulets on floors: the sliding droplets of 1.19.0 (R.Slide) started at min(0.12 vts, 70) u/s with up to 45 % of
    the drop - lines up to ~20 cm from any drop faster than 140 u/s along the floor. ghmpb_drop_slide 1 is now a short
    skid: only above 260 u/s along the surface, 8-23 % of the drop, min(0.045 vts, 22) u/s (~1-3 u). 2 = the 1.19 rivulet.
  * Wiggly runs on walls: meander waves (0.06 + 0.22 rough) / (0.02 + 0.06 rough) rad, catches kinking the heading by up to
    +-0.25 rough rad, heading limited to 43 deg - looping lines on concrete. Now (0.025 + 0.07 rough) / (0.008 + 0.02 rough),
    kinks +-0.1 rough, heading within 26 deg (test: 0.11 u sideways over 6.5 u of run).
  * Smears of fast-skimming parts: a 0.1 s contact step of a part moving at 400-800 u/s was a 40-80 u smear line. The smear
    fades out from 400 to 800 u/s (cl_smear Move); pushes / wipes of blood already there unchanged.
- Fall smash (1.23.2) sprayed around the body's surface normal + 0.4 z (often sideways: drops skimming the floor or a
  wall). Now G.Particles.Burst (cl_particles): from the floor under the body, all round (evenly spread azimuths),
  15-60 deg up, 50..150 + 30 k u/s, r0 0.7 mm, 16 k drops (Splatter sliders apply) - a ring of short teardrops pointing
  outwards round the pour.
- Menu (Splatter > Droplets): "Longest drop stain (length / width)" ghmpb_streak_max; "Fast drops skid on" 0 / 1 / 2.
- Tests: test_client_streaks.lua (any angle x stretch -> <= 3.5; speed kept; direction kept; untouched within the
  limit; a wall at 1500 u/s; ligament drop; settings 2 and 10), test_client_slide.lua (short skid 1.1 u / 1.24 ul;
  setting 2 long 6.4 u; < 260 u/s no skid; a wall run stays within 26 deg and 0.11 u sideways), test_client_corpse_impact
  (the burst: up from the floor, 15-60 deg).

## 1.25.0 - reflection probes, the map's lights, opaque thick blood, smoother edges, dried colour - from source, NOT verified in game (shader build b73)
- Reflection probes (cl_probes.lua): blood is grouped per 256 u cell (live patches weight 2, settled layers 1); the
  ghmpb_reflect_probes (2) groups that matter most (closest, in front, most blood; a group with a probe keeps it at x1.4)
  get a probe: a cube map rendered with render.RenderView from 10 u above the middle of the group (out of solid), one
  128 x 128 face at a time in PostRender into a face target with its own depth (MATERIAL_RT_DEPTH_SEPARATE), copied into
  the group's 512 x 512 RGBA8 atlas. Faces within ghmpb_reflect_budget ms a second (token bucket, at most one a frame,
  a quarter of it while the adaptive quality holds the frame rate), the face that waited longest x the group's score
  first; the face looking into the surface at a quarter. After each face the 6 blurred 32 x 32 faces are worked out from a
  copy (render.CopyTexture to a scratch atlas) by direction (probeblur_ps30: 24 taps in a ~22 deg cone): seamless.
  A new probe starts with the map's cubemap (probeenv_ps30: env_cubemap into the faces, mip 3.5 for the blurred ones) and
  counts as rendered (header flag) once all six faces were drawn. Our own blood hooks skip the probe views (P.rendering).
  Three failed views switch the probes off (fallback only). Lite renderer: no probes.
- Atlas layout (ghmpb_common.h): faces at (f % 3, f / 3) x 128 in the order +X -X +Y -Y +Z -Z with RenderView angles
  (0 0 0) (0 180 0) (0 90 0) (0 -90 0) (-90 0 0) (90 0 0) - screen x along Angle:Right, y along Angle:Up
  (ghmpb_cubeFace / ghmpb_faceDir; checked against Source's AngleVectors in tests and offline); blurred faces in a row
  from (0, 256); data from x = 384: (384,0) centre x/y 16 bit, (385,0) centre z, sphere radius / 8, rendered flag; rows
  1..4 lights: (x, y) | (z, range / 64, type) | (colour, (log2 I + 4) / 24) | (spot dir, cos outer). Positions 16 bit over
  +-16384 u (0.5 u). Read raw ($linearread_texture5 1); blood without a probe reads the fallback atlas (the map's cubemap
  + the lights around the camera, refreshed every 2 s); before that is filled, materials hold
  materials/ghm_physblood/probe_default.vtf (64 x 64, grey faces, zero data - tools/gen_probetex.py).
- The films (ghmpb_shade.h): s5 is the atlas (was env_cubemap). ghmpb_probeEnv: parallax correction against the probe's
  sphere (radius = median distance of 14 traces, 48..1000 u) when rendered, sharp / blurred faces by roughness
  (0.04..0.26), reflBoost; envOcc only for a probe that still holds the map's cubemap. World SSR x0.35 where the group's
  probe is rendered (its grazing rays land on the floor beyond the pool: it read as see-through).
- Lights (cl_maplights.lua): the BSP world light lump (54 HDR, else 15; 88 / 100-byte dworldlight_t by lump version),
  point and spot lights with VRAD falloff (1 / (c + l d + q d^2)) and cones; light_dynamic, env_projectedtexture,
  point_spotlight entities and other players' flashlights (type 3, framebuffer units like the local flashlight term).
  M.Pick(pos): strongest radiance at the probe (traced clear, MASK_SOLID_BRUSHONLY, cached 3 s), 4 at most; I = radiance
  x d^2 at the probe so the shader's 1 / d^2 matches there. In the film: a loop of 4 GGX highlights (x k for light units).
  ghmpb_map_lights 0 = none.
- Opaque thick blood: in the Kubelka-Munk loop the background under a layer gives way to the layer's own R inf
  (a - sqrt(a^2 - 1)) by smoothstep(0.1, 0.45 mm) wet, (0.2, 0.7) dried - a pool shows only the blood's colour.
  World: the floor under wet blood blurred to its mean fully (hideK smoothstep(0.02, 0.3) - was 0.9 x (0.02, 0.4)). Drops:
  no refraction (the scene behind sampled straight, only through chords < 0.8 mm).
- Edges: coverage AA width fwidth x 1.1 (min 2e-4, was x 0.75 / 1e-4); the surface grain of concrete / brick / plaster /
  paper / carpet / sand / snow / soil about half as strong and half the frequency (it speckled stain edges at a texel).
- Froth: impacts trap much less (fz from (speed - 450) / 1800 x (0.15 + 0.6 oxy), was (speed - 250) / 900 x (0.3 + 0.7 oxy));
  bubbles on bright blood only above 82 % oxygen, fewer per cell, the froth veil 0.3 (was 0.45) - the pale dotted rings.
- Dried stains: rim darkening 2.6 (was 1.6) and the rim measured wider (x 0.9); per-stain variation of age (browner /
  redder patches) and density (x 0.72..1.32) from two value noises.
- Instruction slots (ps_3_0): surface 3749 (r0..r30), surfstatic ~3440, bodyfilm 2720, bodystatic 2542, stamp 2734
  (r31), probeblur 124, probeenv 25 - surface is the closest to the ~4000 that failed in 1.10.0.
- Menu: Look > Reflections and lights. ghmpb_diag: probe and light lines.
- Tests: test_client_probes.lua (face mapping vs RenderView angles; data texels round trip as the shader decodes them;
  BSP light lump read; picks: blocked / facing away excluded, falloff reproduced, flashlights; grouping, placing, fallback;
  budget; binding; off switches), test_globals (MATERIAL_RT_DEPTH_SEPARATE). Offline: tools/pbr/render_124.py.
- To verify in game first: that render.RenderView into the face target from PostRender draws the scene (x / y / w / h,
  aspect 1, fov 90 horizontal), that env_cubemap binds as $basetexture of probeenv, the cost of a face on a heavy map
  (ghmpb_diag "ms a face"), and that the faces sit the right way round (a wall to the north reflected north).
