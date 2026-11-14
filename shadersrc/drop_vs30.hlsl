// GHM PhysBlood: flying droplets. Each particle is a quad whose 4 vertices share the particle centre in
// POSITION; TEXCOORD0 = (corner.x -1..1 across, corner.y +1 head / -1 end of the trail, radius_u,
// stretch + 100 * blood type + 1000 * oxygen level 0..9),
// TEXCOORD1 = (velocity.xyz u/s, trail length u).
// The quad is expanded here into a camera facing billboard along the screen direction of travel: the drop
// body (a sphere drawn out by its ligament stretch) at the front, its motion trail behind it. Both are
// scaled by how much of the motion is across the screen, so a drop flying at the camera stays round.
#include "common_vs_fxc.h"
struct VS_INPUT {
	float4 vPos  : POSITION;
	float4 vTex0 : TEXCOORD0;
	float4 vTex1 : TEXCOORD1;
};
struct VS_OUTPUT {
	float4 pos    : POSITION;
	float4 corner : TEXCOORD0; // x across (u), y along the axis from the centre (u), z radius (u), w stretch
	float4 vel    : TEXCOORD1; // xyz velocity dir (world), w trail length (u, on screen)
	float4 wpos   : TEXCOORD2; // world pos of this corner, w = view depth
	float4 axes   : TEXCOORD3; // axis along motion (xyz), w = blood type
	float4 eye    : TEXCOORD4; // xyz eye, w = oxygen saturation of the drop
};
VS_OUTPUT main(VS_INPUT v)
{
	VS_OUTPUT o;
	float3 c = v.vPos.xyz;
	float3 view = normalize(cEyePos - c);
	float3 vel = v.vTex1.xyz;
	float speed = length(vel);
	float3 dir = speed > 1e-3 ? vel / speed : float3(0, 0, 1);
	float3 axis = dir - view * dot(dir, view);
	float al = length(axis);
	axis = al > 1e-3 ? axis / al : normalize(cross(view, float3(0.577, 0.577, 0.577)));
	float3 side = normalize(cross(view, axis));
	float r = v.vTex0.z;
	float oxq = floor(v.vTex0.w / 1000.0 + 0.0001);
	float rest = v.vTex0.w - oxq * 1000.0;
	float btype = floor(rest / 100.0 + 0.001);
	float stIn = rest - btype * 100.0;
	float across = saturate(al);
	float stretch = 1.0 + (max(stIn, 1.0) - 1.0) * across;
	float trail = v.vTex1.w * across;
	// head end in front of the drop body, the trail end behind it
	float a = v.vTex0.y > 0.0 ? r * stretch * 1.05 : -(r * stretch * 1.05 + trail);
	float x = v.vTex0.x * r * 1.05;
	float3 wp = c + side * x + axis * a;
	o.pos = mul(float4(wp, 1.0), cViewProj);
	o.corner = float4(x, a, r, stretch);
	o.vel = float4(dir, trail);
	o.wpos = float4(wp, o.pos.w);
	o.axes = float4(axis, btype);
	o.eye = float4(cEyePos, oxq / 9.0);
	return o;
}
