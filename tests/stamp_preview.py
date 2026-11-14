#!/usr/bin/env python3
"""
GHM PhysBlood - NumPy preview of the contact stamps of stamp_ps30 (1.13.0): the hand print (soaked, drying, nearly
dry) and a tyre tread strip whose freshness fades along its length. Same formulas as the shader (vnoise is a
stand-in for ghmpb_vnoise, so the breakup pattern differs in detail).
usage: stamp_preview.py [out.png]
"""
import numpy as np
from PIL import Image
def smoothstep(a,b,x):
    t=np.clip((x-a)/(b-a),0,1); return t*t*(3-2*t)
def hash12(p):
    return np.modf(np.sin(p[...,0]*127.1+p[...,1]*311.7)*43758.5453)[0]%1.0
def vnoise(x,y):
    ix,iy=np.floor(x),np.floor(y); fx,fy=x-ix,y-iy
    u=fx*fx*(3-2*fx); v=fy*fy*(3-2*fy)
    def h(a,b): return np.abs(np.modf(np.sin(a*127.1+b*311.7)*43758.5453)[0])
    return (h(ix,iy)*(1-u)+h(ix+1,iy)*u)*(1-v)+(h(ix,iy+1)*(1-u)+h(ix+1,iy+1)*u)*v
sq=lambda x:x*x
def hand(x,y,fresh,seed):
    en=1+0.07*(vnoise(x*5+seed*13,y*5)-0.5)
    # palm: tapered rounded box, wrist (x=-1) narrower than the knuckles (x=0.05)
    hw=0.36+0.1*np.clip((x+1)/1.0,0,1)
    pqx=np.abs((x+0.47)/0.53)*en; pqy=np.abs((y-0.02)/hw)*en
    pr=np.power(np.maximum(pqx**2.6+pqy**2.6,1e-6),1/2.6)
    palm=1-smoothstep(0.88,1.0,pr)
    hollow=np.exp(-(sq(x+0.36)/0.07+sq(y-0.02)/0.05))
    c1=smoothstep(0.008,0.03,np.abs(x-(-0.02+0.18*y)))            # distal crease
    c2=smoothstep(0.008,0.03,np.abs(x+0.22+0.25*y))*smoothstep(-0.35,-0.2,y)   # proximal crease (not across the thumb pad)
    c3=smoothstep(0.008,0.03,np.abs(np.hypot((x+0.62)/1.25,(y-0.36)/0.8)-0.34))  # life line round the thumb pad
    crease=(0.35+0.65*c1)*(0.35+0.65*c2)*(0.35+0.65*c3)
    palm=palm*(1-0.55*hollow*(1-fresh*0.6))*crease
    spread=0.04+0.08*seed
    fingers=np.zeros_like(x); tips=np.zeros_like(x); knuck=np.zeros_like(x)
    for f,(yb,fx0,flen,fw0) in enumerate([(0.33,0.06,0.78,0.095),(0.11,0.08,0.84,0.1),(-0.11,0.06,0.8,0.095),(-0.32,0.0,0.64,0.08)]):
        a=yb*spread*2.5; fd=(np.cos(a),np.sin(a))
        rx,ry=x-fx0,y-yb
        t=np.clip(rx*fd[0]+ry*fd[1],-0.14,flen)
        dist=np.hypot(rx-fd[0]*t,ry-fd[1]*t)
        w=fw0*(1-0.15*np.maximum(t,0)/flen)
        cap=1-smoothstep(w*0.75,w,dist)
        joints=(0.4+0.6*smoothstep(0.01,0.03,np.abs(t-flen*0.42)))*(0.4+0.6*smoothstep(0.01,0.03,np.abs(t-flen*0.72)))
        fingers=np.maximum(fingers,cap*joints)
        tips=np.maximum(tips,cap*np.exp(-sq((t-flen*0.88)/0.1)))
        knuck=np.maximum(knuck,np.exp(-(sq(x-fx0+0.07)/0.012+sq(y-yb)/0.008)))
    td=np.array((0.72,0.69)); td=td/np.linalg.norm(td)
    trx,try_=x+0.42,y-0.4
    tt=np.clip(trx*td[0]+try_*td[1],0,0.58)
    tdist=np.hypot(trx-td[0]*tt,try_-td[1]*tt)
    tw=0.13-0.03*tt/0.58
    thumb=(1-smoothstep(tw*0.8,tw,tdist))*(0.4+0.6*smoothstep(0.01,0.03,np.abs(tt-0.3)))
    tips=np.maximum(tips,thumb*np.exp(-sq((tt-0.5)/0.1)))
    thenar=(1-smoothstep(0.85,1.0,np.hypot((x+0.5)/0.34,(y-0.3)/0.2)))*(0.35+0.65*c3)
    shape=np.maximum(np.maximum(np.maximum(palm,fingers),thumb),thenar)
    heel=np.exp(-(sq(x+0.72)/0.03+sq(y-0.18)/0.04))+np.exp(-(sq(x+0.7)/0.03+sq(y+0.2)/0.03))
    pads=np.clip(np.maximum(np.maximum(tips,heel),knuck*0.85),0,1)
    fill=pads+(1-pads)*(fresh**1.5*0.9)
    thr=(1-fresh)*0.55
    patch=vnoise(x*4.5+seed*29,y*4.5)
    br=smoothstep(thr-0.12,thr+0.12,patch)
    grain=0.85+0.15*vnoise(x*14+seed*7,y*14)
    return shape*fill*br*(grain+(1-grain)*fresh)
def tread(al,lat,L,s,fresh,seed):
    inLen=smoothstep(-0.6,-0.2,al)*(1-smoothstep(L+0.2,L+0.6,al))
    sh=1-smoothstep(0.8,1.0,np.abs(lat))
    gr=smoothstep(0.035,0.09,np.abs(np.abs(lat)-0.45))*smoothstep(0.02,0.07,np.abs(lat))
    lugs=smoothstep(-0.25,0.3,np.sin(s*1.9+np.abs(lat)*6.0))
    tr=gr*(lugs+(1-lugs)*0.2)
    # (soaked, the gaps between the lugs fill up - the circumferential grooves stay lighter)
    k=fresh*fresh*0.75
    fill=tr+((gr*0.9+0.1)-tr)*k
    thr=(1-fresh)*0.6
    br=smoothstep(thr-0.12,thr+0.12,vnoise(s*0.35+seed*17,lat*1.3))
    return inLen*sh*fill*br

if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "stamps.png"
    N = 400
    img = np.ones((N, N * 4, 3))
    u = np.linspace(-1.2, 1.2, N)
    X, Y = np.meshgrid(u, u)
    for k, fresh in enumerate([1.0, 0.45, 0.15]):
        d = hand(-Y, X, fresh, 0.4)                 # fingers up, thumb to the right (a right hand seen from its back)
        for c in range(3): img[:, k * N:(k + 1) * N, c] = 1 - d * [0.1, 0.9, 0.9][c]
    u = np.linspace(-8, 8, N); v = np.linspace(-2, 62, N)
    LAT, AL = np.meshgrid(u, v)
    d = tread(AL, LAT / 5.5, 60, AL, np.clip(1 - AL / 60, 0.05, 1), 0.3)   # (fresh fading along the strip)
    for c in range(3): img[:, 3 * N:, c] = 1 - d * [0.1, 0.9, 0.9][c]
    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(out)
    print("wrote", out)
