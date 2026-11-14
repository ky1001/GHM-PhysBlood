// =====================================================================================================
// GHM PhysBlood - native droplet solver (gmcl_ghmpb_native_v5_win64.dll / _win32.dll, require("ghmpb_native_v5"))
//
// Runs the flying-blood physics for the Lua side (lua/ghm_physblood/cl_native.lua):
//   * integration with gravity and air drag from the drop's own Reynolds number (Schiller-Naumann: Stokes drag
//     for mist-sized drops, which stop within ~0.5 m, quadratic drag for large ones) and its flattening at high
//     air Weber numbers (a 4.6 mm drip falls at the measured 7.6 m/s terminal velocity)
//   * aerodynamic break-up (air Weber number > 12 bag break-up into 2-3 drops, > 40 catastrophic into 4-6)
//   * surface-tension relaxation of ligament drops (stretch -> 1) and spin decay
//   * coalescence: drops that meet in flight merge (volume and momentum conserving) - arterial jets and
//     coughs turn into realistic larger drops and streams
// Collision traces stay in Lua (engine traces), so the module only talks to GMod through the public Lua
// C API (ILuaBase) and does not depend on any engine interface -> GMod updates cannot break it.
//
// Lua API (global table ghm_physblood):
//   Spawn(x,y,z, vx,vy,vz, r_mm, spin, stretch, ownerIndex, grace, oxy, btype, broke, flags) -> id
//   Step(dt, gx,gy,gz)
//   Segments(max) -> { id, x0,y0,z0, x1,y1,z1, ownerIndex, age, grace, ... }  (10 numbers each)
//                    round robin; only returned drops advance their traced position (no tunnelling)
//   Hit(id) -> vx,vy,vz, r_mm, spin, stretch, oxy, btype, ownerIndex, flags   (removes the drop)
//   Kill(id)
//   RenderData() -> { x,y,z, vx,vy,vz, r_mm, stretch + 100*btype + 1000*oxygen level 0..9, ... } (8 numbers each)
//   Count(), Clear(), Version()
// v5 (1.17.0): Segments(max, tbl) and RenderData(tbl) fill the given table in place and return the number of values
//   written (entries past it are left over from earlier frames): no new table - and no table growing - every frame
//   (with ~1400 drops in flight that was ~0.3 MB of Lua garbage a frame). Without a table they work as before.
// =====================================================================================================
#include "GarrysMod/Lua/Interface.h"
#include <cmath>
#include <cstdint>
#include <vector>
#include <unordered_map>
#include <algorithm>

using namespace GarrysMod::Lua;

namespace
{
	const char* kVersion = "ghm_physblood native 5.0.0";

	constexpr double kUnitsPerMM = 1.0 / 19.05;
	constexpr double kMetersPerUnit = 0.01905;
	constexpr double kRhoAirOverBlood = 1.2 / 1060.0;
	constexpr double kRhoAir = 1.2;
	constexpr double kSigma = 0.055;          // N/m, blood surface tension
	constexpr double kMuAir = 1.8e-5;         // Pa s
	constexpr double kLife = 6.0;             // s
	constexpr size_t kMaxDrops = 8000;

	struct Vec { double x, y, z; };
	inline Vec operator+(Vec a, Vec b) { return { a.x + b.x, a.y + b.y, a.z + b.z }; }
	inline Vec operator-(Vec a, Vec b) { return { a.x - b.x, a.y - b.y, a.z - b.z }; }
	inline Vec operator*(Vec a, double s) { return { a.x * s, a.y * s, a.z * s }; }
	inline double dot(Vec a, Vec b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
	inline double len(Vec a) { return std::sqrt(dot(a, a)); }

	struct Drop
	{
		uint32_t id;
		Vec pos, vel, traced;
		double r;          // mm
		double spin;       // rad/s
		double stretch;    // >= 1
		double age, grace;
		double oxy;
		int btype;
		int owner;
		int flags;         // 1 = expirated (air bubbles)
		bool broke;
		bool dead;
	};

	std::vector<Drop> g_drops;
	std::unordered_map<uint32_t, size_t> g_index;
	uint32_t g_nextId = 1;
	size_t g_cursor = 0;

	// cheap deterministic RNG (xorshift)
	uint32_t g_rng = 0x9E3779B9u;
	double rnd()
	{
		g_rng ^= g_rng << 13; g_rng ^= g_rng >> 17; g_rng ^= g_rng << 5;
		return (g_rng & 0xFFFFFF) / double(0x1000000);
	}
	double rndRange(double a, double b) { return a + (b - a) * rnd(); }
	Vec rndDir()
	{
		double z = rndRange(-1.0, 1.0), t = rndRange(0.0, 6.283185307), s = std::sqrt(std::max(0.0, 1.0 - z * z));
		return { s * std::cos(t), s * std::sin(t), z };
	}

	double volOf(double r) { return 4.18879 * r * r * r; }

	// drag coefficient of a blood drop: Schiller-Naumann sphere drag from the air Reynolds number, raised by
	// the flattening of the drop at higher air Weber numbers
	double dragCd(double speedMS, double dM)
	{
		double re = std::max(kRhoAir * speedMS * dM / kMuAir, 1e-3);
		double cd = (re < 1000.0) ? 24.0 / re * (1.0 + 0.15 * std::pow(re, 0.687)) : 0.44;
		double weAir = kRhoAir * speedMS * speedMS * dM / kSigma;
		return cd * std::min(1.0 + 0.18 * weAir, 3.0);
	}
	double radiusOf(double v) { return std::cbrt(std::max(v, 1e-6) / 4.18879); }

	void reindex()
	{
		g_index.clear();
		for (size_t i = 0; i < g_drops.size(); i++) g_index[g_drops[i].id] = i;
	}

	uint32_t add(const Drop& d0)
	{
		if (g_drops.size() >= kMaxDrops) return 0;
		Drop d = d0;
		d.id = g_nextId++;
		if (g_nextId == 0) g_nextId = 1;
		d.dead = false;
		g_index[d.id] = g_drops.size();
		g_drops.push_back(d);
		return d.id;
	}

	void compact()
	{
		size_t w = 0;
		for (size_t i = 0; i < g_drops.size(); i++)
			if (!g_drops[i].dead) g_drops[w++] = g_drops[i];
		g_drops.resize(w);
		if (g_cursor >= w) g_cursor = 0;
		reindex();
	}

	// ---------------------------------------------------------------- coalescence (spatial hash)
	struct CellKey { int x, y, z; bool operator==(const CellKey& o) const { return x == o.x && y == o.y && z == o.z; } };
	struct CellHash { size_t operator()(const CellKey& k) const { return (size_t)((k.x * 73856093) ^ (k.y * 19349663) ^ (k.z * 83492791)); } };

	void coalesce()
	{
		const double cell = 2.0;   // units
		std::unordered_map<CellKey, std::vector<size_t>, CellHash> grid;
		grid.reserve(g_drops.size() * 2);
		for (size_t i = 0; i < g_drops.size(); i++)
		{
			const Drop& d = g_drops[i];
			if (d.dead) continue;
			CellKey k{ (int)std::floor(d.pos.x / cell), (int)std::floor(d.pos.y / cell), (int)std::floor(d.pos.z / cell) };
			grid[k].push_back(i);
		}
		for (auto& kv : grid)
		{
			const CellKey& k = kv.first;
			for (size_t a : kv.second)
			{
				Drop& A = g_drops[a];
				if (A.dead) continue;
				for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++)
				{
					auto it = grid.find(CellKey{ k.x + dx, k.y + dy, k.z + dz });
					if (it == grid.end()) continue;
					for (size_t b : it->second)
					{
						if (b <= a) continue;
						Drop& B = g_drops[b];
						if (B.dead || A.dead) continue;
						// drops of one spray start almost on top of each other: only drops that have had time
						// to separate (and then meet again) can coalesce
						if (A.age < 0.08 || B.age < 0.08) continue;
						double reach = (A.r + B.r) * kUnitsPerMM * std::max(1.0, 0.5 * (A.stretch + B.stretch));
						Vec dp = A.pos - B.pos;
						if (dot(dp, dp) > reach * reach) continue;
						Vec dv = A.vel - B.vel;
						// high relative speed -> the drops bounce / shatter instead of merging
						if (len(dv) > 60.0) continue;
						double va = volOf(A.r), vb = volOf(B.r), vs = va + vb;
						A.pos = (A.pos * va + B.pos * vb) * (1.0 / vs);
						A.vel = (A.vel * va + B.vel * vb) * (1.0 / vs);
						A.traced = (va >= vb) ? A.traced : B.traced;
						A.spin = (A.spin * va + B.spin * vb) / vs;
						A.stretch = std::min(4.0, std::max(A.stretch, B.stretch) + 0.3);   // the merged drop oscillates
						A.oxy = (A.oxy * va + B.oxy * vb) / vs;
						A.r = radiusOf(vs);
						A.grace = std::max(A.grace, B.grace);
						A.age = std::min(A.age, B.age);
						B.dead = true;
					}
				}
			}
		}
	}

	// ---------------------------------------------------------------- Lua helpers
	void setNum(ILuaBase* LUA, int idx, double v)
	{
		LUA->PushNumber((double)idx);
		LUA->PushNumber(v);
		LUA->SetTable(-3);
	}
}

// ------------------------------------------------------------------------------------------------ API
LUA_FUNCTION(L_Version)
{
	LUA->PushString(kVersion);
	return 1;
}

LUA_FUNCTION(L_Spawn)
{
	Drop d{};
	d.pos = { LUA->GetNumber(1), LUA->GetNumber(2), LUA->GetNumber(3) };
	d.vel = { LUA->GetNumber(4), LUA->GetNumber(5), LUA->GetNumber(6) };
	d.traced = d.pos;
	d.r = std::max(0.03, LUA->GetNumber(7));
	d.spin = LUA->GetNumber(8);
	d.stretch = std::max(1.0, LUA->GetNumber(9));
	d.owner = (int)LUA->GetNumber(10);
	d.grace = LUA->GetNumber(11);
	d.oxy = LUA->GetNumber(12);
	d.btype = (int)LUA->GetNumber(13);
	d.broke = LUA->GetNumber(14) != 0.0;
	d.flags = LUA->IsType(15, Type::Number) ? (int)LUA->GetNumber(15) : 0;
	d.age = 0.0;
	LUA->PushNumber((double)add(d));
	return 1;
}

LUA_FUNCTION(L_Step)
{
	double dt = LUA->GetNumber(1);
	Vec g = { LUA->GetNumber(2), LUA->GetNumber(3), LUA->GetNumber(4) };
	if (dt <= 0.0) return 0;
	dt = std::min(dt, 0.1);
	std::vector<Drop> born;
	for (Drop& p : g_drops)
	{
		if (p.dead) continue;
		p.age += dt;
		if (p.age > kLife) { p.dead = true; continue; }
		double sp = len(p.vel);
		double ru = p.r * kUnitsPerMM;
		double dM = 2.0 * p.r / 1000.0;
		double cd = dragCd(sp * kMetersPerUnit, dM);
		double k = 3.0 * kRhoAirOverBlood * cd / (8.0 * ru);
		// (exact exponential decay: mist-sized drops are stiff)
		p.vel = p.vel * std::exp(-k * sp * dt) + g * dt;
		p.pos = p.pos + p.vel * dt;
		p.stretch = 1.0 + (p.stretch - 1.0) * std::exp(-dt / 0.09);
		p.spin *= std::exp(-dt * 0.8);
		// aerodynamic break-up
		if (!p.broke && p.r > 0.35)
		{
			double vm = sp * kMetersPerUnit;
			double We = kRhoAir * vm * vm * (2.0 * p.r / 1000.0) / kSigma;
			if (We > 12.0)
			{
				p.broke = true;
				int parts = (We > 40.0) ? 4 + (int)(rnd() * 3.0) : ((rnd() < 0.5) ? 2 : 3);
				double left = volOf(p.r);
				for (int c = 0; c < parts - 1; c++)
				{
					double share = left * rndRange(0.25, 0.5);
					left -= share;
					Drop ch = p;
					ch.vel = p.vel + rndDir() * (sp * 0.08);
					ch.r = radiusOf(share);
					ch.broke = true;
					ch.stretch = 1.8;
					ch.spin = p.spin + rndRange(-60.0, 60.0);
					ch.grace = std::max(0.0, p.grace - p.age);
					ch.age = 0.0;
					born.push_back(ch);
				}
				p.r = radiusOf(left);
			}
		}
	}
	for (const Drop& b : born) add(b);
	coalesce();
	compact();
	return 0;
}

LUA_FUNCTION(L_Segments)
{
	size_t maxN = (size_t)std::max(0.0, LUA->GetNumber(1));
	if (maxN == 0) maxN = g_drops.size();
	const bool inPlace = LUA->IsType(2, Type::Table);
	if (inPlace) LUA->Push(2); else LUA->CreateTable();
	size_t n = g_drops.size();
	if (n == 0)
	{
		if (inPlace) { LUA->PushNumber(0.0); return 1; }
		return 1;
	}
	size_t count = 0;
	int idx = 1;
	for (size_t c = 0; c < n && count < maxN; c++)
	{
		if (g_cursor >= n) g_cursor = 0;
		Drop& d = g_drops[g_cursor++];
		if (d.dead) continue;
		count++;
		setNum(LUA, idx++, d.id);
		setNum(LUA, idx++, d.traced.x); setNum(LUA, idx++, d.traced.y); setNum(LUA, idx++, d.traced.z);
		setNum(LUA, idx++, d.pos.x); setNum(LUA, idx++, d.pos.y); setNum(LUA, idx++, d.pos.z);
		setNum(LUA, idx++, d.owner);
		setNum(LUA, idx++, d.age);
		setNum(LUA, idx++, d.grace);
		d.traced = d.pos;
	}
	if (inPlace) LUA->PushNumber((double)(idx - 1));
	return 1;
}

LUA_FUNCTION(L_Hit)
{
	uint32_t id = (uint32_t)LUA->GetNumber(1);
	auto it = g_index.find(id);
	if (it == g_index.end() || it->second >= g_drops.size() || g_drops[it->second].dead) return 0;
	Drop& d = g_drops[it->second];
	d.dead = true;
	LUA->PushNumber(d.vel.x); LUA->PushNumber(d.vel.y); LUA->PushNumber(d.vel.z);
	LUA->PushNumber(d.r); LUA->PushNumber(d.spin); LUA->PushNumber(d.stretch);
	LUA->PushNumber(d.oxy); LUA->PushNumber(d.btype); LUA->PushNumber(d.owner);
	LUA->PushNumber(d.flags);
	return 10;
}

LUA_FUNCTION(L_Kill)
{
	uint32_t id = (uint32_t)LUA->GetNumber(1);
	auto it = g_index.find(id);
	if (it != g_index.end() && it->second < g_drops.size()) g_drops[it->second].dead = true;
	return 0;
}

LUA_FUNCTION(L_RenderData)
{
	const bool inPlace = LUA->IsType(1, Type::Table);
	if (inPlace) LUA->Push(1); else LUA->CreateTable();
	int idx = 1;
	for (const Drop& d : g_drops)
	{
		if (d.dead) continue;
		setNum(LUA, idx++, d.pos.x); setNum(LUA, idx++, d.pos.y); setNum(LUA, idx++, d.pos.z);
		setNum(LUA, idx++, d.vel.x); setNum(LUA, idx++, d.vel.y); setNum(LUA, idx++, d.vel.z);
		setNum(LUA, idx++, d.r);
		// v3: blood type, v4: oxygen level 0..9 (bright arterial / dark venous) for the drop shader
		double oxq = std::floor(std::max(0.0, std::min(1.0, d.oxy)) * 9.0 + 0.5);
		setNum(LUA, idx++, d.stretch + 100.0 * (double)std::max(0, std::min(d.btype, 7)) + 1000.0 * oxq);
	}
	if (inPlace) LUA->PushNumber((double)(idx - 1));
	return 1;
}

LUA_FUNCTION(L_Count)
{
	size_t n = 0;
	for (const Drop& d : g_drops) if (!d.dead) n++;
	LUA->PushNumber((double)n);
	return 1;
}

LUA_FUNCTION(L_Clear)
{
	g_drops.clear();
	g_index.clear();
	g_cursor = 0;
	return 0;
}

GMOD_MODULE_OPEN()
{
	g_drops.reserve(2048);
	LUA->PushSpecial(SPECIAL_GLOB);
	LUA->CreateTable();
	LUA->PushCFunction(L_Version);    LUA->SetField(-2, "Version");
	LUA->PushCFunction(L_Spawn);      LUA->SetField(-2, "Spawn");
	LUA->PushCFunction(L_Step);       LUA->SetField(-2, "Step");
	LUA->PushCFunction(L_Segments);   LUA->SetField(-2, "Segments");
	LUA->PushCFunction(L_Hit);        LUA->SetField(-2, "Hit");
	LUA->PushCFunction(L_Kill);       LUA->SetField(-2, "Kill");
	LUA->PushCFunction(L_RenderData); LUA->SetField(-2, "RenderData");
	LUA->PushCFunction(L_Count);      LUA->SetField(-2, "Count");
	LUA->PushCFunction(L_Clear);      LUA->SetField(-2, "Clear");
	LUA->SetField(-2, "ghm_physblood");
	LUA->Pop();
	return 0;
}

GMOD_MODULE_CLOSE()
{
	g_drops.clear();
	g_index.clear();
	return 0;
}
