AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Brick wall section (blood test)"
ENT.Author = "GHM PhysBlood"
ENT.Category = "GHM PhysBlood"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.Model = "models/ghmpb/brick_wall.mdl"

function ENT:SpawnFunction(ply, tr, cls)
	if not tr.Hit then return end
	local ent = ents.Create(cls)
	local yaw = IsValid(ply) and (ply:GetPos() - tr.HitPos):Angle().y or 0
	ent:SetPos(tr.HitPos + Vector(0, 0, 0))
	ent:SetAngles(Angle(0, math.Round(yaw / 90) * 90, 0))
	ent:Spawn()
	ent:Activate()
	return ent
end

function ENT:Initialize()
	self:SetModel(self.Model)
	if SERVER then
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then phys:EnableMotion(false) end
	end
end

function ENT:Draw()
	self:DrawModel()
end
