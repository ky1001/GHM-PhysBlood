#!/usr/bin/env python3
"""
GHM PhysBlood - NumPy preview of the creature tracks of stamp_ps30 (1.16.0): pad / leg tip, claw stab, three toes,
paw - each wet, drying and nearly dry - plus a short headcrab and antlion trail laid out like cl_footprints.lua.
Same formulas as the shader (vnoise is a stand-in for ghmpb_vnoise). Also prints the measured area of each shape
against the area cl_footprints.lua assumes (AREA table).
usage: creature_preview.py [out.png]
"""
import sys, math
import numpy as np
from PIL import Image
def smoothstep(a,b,x):
    t=np.clip((x-a)/(b-a),0,1); return t*t*(3-2*t)
def vnoise(x,y):
    ix,iy=np.floor(x),np.floor(y); fx,fy=x-ix,y-iy
    u=fx*fx*(3-2*fx); v=fy*fy*(3-2*fy)
    def h(a,b): return np.abs(np.modf(np.sin(a*127.1+b*311.7)*43758.5453)[0])
    return (h(ix,iy)*(1-u)+h(ix+1,iy)*u)*(1-v)+(h(ix,iy+1)*(1-u)+h(ix+1,iy+1)*u)*v
sq=lambda x:x*x
def sdTaper(px,py,r1,r2,h):
    px=np.abs(px); b=(r1-r2)/h; a=math.sqrt(max(1-b*b,0))
    k=-b*px+a*py
    d1=np.hypot(px,py)-r1; d2=np.hypot(px,py-h)-r2; d3=a*px+b*py-r1
    return np.where(k<0,d1,np.where(k>a*h,d2,d3))
def shape(sh,x,y,fresh,seed):
    en=1+0.12*(vnoise(x*5+seed*13,y*5+seed*13)-0.5)
    if sh==3:
        hw=0.5-0.12*(x+0.3)
        lobes=1-0.12*smoothstep(0,0.25,-(x+0.45))*(1-np.abs(np.sin(y/hw*3)))
        mainP=1-smoothstep(0.85,1.0,np.hypot((x+0.3)/0.42,y/hw)*en/lobes)
        toes=np.zeros_like(x)
        for t in range(4):
            ang=(t-1.5)*0.55; rr=0.66 if t in (1,2) else 0.5
            cx,cy=0.1+rr*math.cos(ang), rr*math.sin(ang)*1.15
            toes=np.maximum(toes,1-smoothstep(0.8,1.0,np.hypot((x-cx)/0.17,(y-cy)/0.13)*en))
        shp=np.maximum(mainP,toes)
    elif sh==2:
        toes=np.zeros_like(x)
        for t in range(4):
            ang=[0,0.62,-0.62,math.pi][t]; ln=[0.9,0.72,0.72,0.45][t]
            tdx,tdy=math.cos(ang),math.sin(ang)
            tt=np.clip(x*tdx+y*tdy,0,ln+0.1)
            dist=np.hypot(x-tdx*tt,y-tdy*tt)
            wdt=np.where(tt>ln,0.06,0.16*(1-0.35*tt/ln))*en
            toes=np.maximum(toes,(1-smoothstep(wdt*0.6,wdt,dist))*np.where(tt>ln,0.8,1.0))
        ball=1-smoothstep(0.14,0.24,np.hypot(x,y)*en)
        shp=np.maximum(toes,ball)
    elif sh==1:
        sdC=sdTaper(y,x+0.15,0.3,0.03,1.1)/en
        stab=1-smoothstep(-0.03,0.03,sdC)
        drag=(1-smoothstep(0.04,0.1,np.abs(y+0.04*np.sin(x*7+seed*9))))*smoothstep(-0.95,-0.55,x)*(1-smoothstep(-0.3,-0.1,x))
        drag=drag*0.45*(0.6+0.4*vnoise(x*6,seed*31+0*x))
        shp=np.maximum(stab,drag)
    else:
        rr=np.hypot(x,y)*en
        shp=(1-smoothstep(0.8,1.0,rr))*(0.6+0.4*smoothstep(0.35,0.85,rr)*(1-fresh)+fresh*0.4*(1-smoothstep(0.35,0.85,rr)))
        shp=(1-smoothstep(0.8,1.0,rr))*((0.6+0.4*smoothstep(0.35,0.85,rr))*(1-fresh)+fresh)
    thr=(1-fresh)*0.55
    return shp*smoothstep(thr-0.12,thr+0.12,vnoise(x*2.5+seed*29,y*2.5+seed*29))
AREA={0:2.5,1:0.53,2:0.54,3:0.78}
N=160
g=np.linspace(-1.4,1.4,N); X,Y=np.meshgrid(g,-g)   # x right = forwards, y up = left... (image: forwards to the right)
tiles=[]
for sh in range(4):
    row=[]
    a=shape(sh,X,Y,1.0,0.3); meas=a.sum()*(2.8/N)**2
    print("shape %d: measured area (wet, no breakup) %.2f R^2, assumed %.2f" % (sh, shape(sh,X,Y,1.0,0.3).sum()*(2.8/N)**2, AREA[sh]))
    for fresh in (1.0,0.5,0.15):
        d=shape(sh,X,Y,fresh,0.37+sh)
        img=np.stack([1-0.35*d,1-0.95*d,1-0.95*d],-1)
        row.append(img)
    tiles.append(np.concatenate(row,1))
grid=np.concatenate(tiles,0)
# trails: headcrab (pads, diagonal pairs) and antlion (claws splayed) walking to the right
def trail(feet,r,stride,shp,W=900,H=220,scale_u=2.0):
    canvas=np.zeros((H,W))
    yy,xx=np.mgrid[0:H,0:W]
    ux=(xx-40)/scale_u; uy=(H/2-yy)/scale_u   # units: forwards +x, +y = left
    pos=0.0; grp=1; L=1.0
    while pos*scale_u<W-80:
        for f in feet:
            if f[2]!=grp: continue
            sgn=-1 if f[1]<0 else 1
            yaw=math.radians(f[3]*sgn)
            cx,cy=pos+f[0], -f[1]       # right = -y
            fx,fy=math.cos(yaw),-math.sin(yaw)
            lx=((ux-cx)*fx+(uy-cy)*fy)/r
            ly=(-(ux-cx)*fy+(uy-cy)*fx)/r*(-1 if sgn<0 else 1)
            canvas=np.maximum(canvas,shape(shp,lx,ly,min(L/0.28,1),pos*0.13))
        L*=0.64; pos+=stride; grp=3-grp
        L=max(L,0.0)
    return np.stack([1-0.35*canvas,1-0.95*canvas,1-0.95*canvas],-1)
hc=trail([(6,-5,1,0),(6,5,2,0),(-5,-6,2,0),(-5,6,1,0)],0.6,10,0,scale_u=6.0)
L0=1.0
an=trail([(18,-12,1,25),(18,12,2,25),(-16,-14,2,150),(-16,14,1,150)],1.5,28,1,scale_u=2.0)
W=grid.shape[1]
def fit(im):
    out=np.ones((im.shape[0],W,3)); w=min(W,im.shape[1]); out[:, :w]=im[:, :w]; return out
full=np.concatenate([grid,fit(hc),fit(an)],0)
out=sys.argv[1] if len(sys.argv)>1 else "creature_preview.png"
Image.fromarray((np.clip(full,0,1)*255).astype(np.uint8)).save(out)
print("wrote",out)
