#!/usr/bin/env python3
# crt_postfx_cycle.py — cycle model of sys/crt_postfx.v to find the whole-screen
# vignette bug. Tests two line-counter sources (de-falling vs hs-rising) against
# two de structures (per-line vs frame-level) to see which is robust.

ACT_W = 584; HBLANK = 120; ACT_H = 240; VBLANK = 22
LINE = ACT_W + HBLANK

def gen(frames, de_mode):
    for f in range(frames):
        for ln in range(ACT_H):                 # active lines
            for x in range(LINE):
                de = 1 if x < ACT_W else (1 if de_mode=="frame" else 0)
                hs = 1 if (ACT_W+20) <= x < (ACT_W+40) else 0
                yield de, hs, 0, 1
        for ln in range(VBLANK):                # vblank
            for x in range(LINE):
                hs = 1 if (ACT_W+20) <= x < (ACT_W+40) else 0
                yield 0, hs, 1, 1

class FX:
    def __init__(self, line_src):
        self.line_src=line_src
        self.ox=self.oy=self.w_cur=0; self.W=576; self.H=240
        self.de_d=self.hs_d=self.vs_d=0
        self.recip_w=114; self.recip_h=273
        self.sacc=0;self.scnt=0;self.sd=0;self.sb=0;self.st=0;self.lhW=0;self.lhH=0
    def step(self, de, hs, vs, ce):
        hW=self.W>>1; hH=self.H>>1
        # divider
        if not self.sb:
            if hW!=self.lhW and hW!=0: self.sd=hW;self.sacc=32768;self.scnt=0;self.sb=1;self.st=0;self.lhW=hW
            elif hH!=self.lhH and hH!=0: self.sd=hH;self.sacc=32768;self.scnt=0;self.sb=1;self.st=1;self.lhH=hH
        else:
            if self.sacc>=self.sd: self.sacc-=self.sd; self.scnt+=1
            else:
                if self.st==0:self.recip_w=self.scnt
                else:self.recip_h=self.scnt
                self.sb=0
        # active-pixel counter (de & ce)
        de_fall = (not de) and self.de_d
        hs_rise = hs and not self.hs_d
        new_line = hs_rise if self.line_src=="hs" else de_fall
        if de & ce:
            self.ox += 1
        if new_line:
            if self.ox>self.w_cur: self.w_cur=self.ox
            self.ox=0; self.oy+=1
        if vs and not self.vs_d:
            if self.w_cur>32: self.W=self.w_cur
            if self.oy>32: self.H=self.oy
            self.w_cur=0; self.oy=0; self.ox=0
        self.de_d=de; self.hs_d=hs; self.vs_d=vs
    def bright(self, ox, oy, vig=4):
        hW=self.W>>1; hH=self.H>>1
        adx=ox-hW if ox>=hW else hW-ox; ady=oy-hH if oy>=hH else hH-oy
        nx=min(adx*self.recip_w,32768); ny=min(ady*self.recip_h,32768)
        r2=min(((nx*nx)>>15)+((ny*ny)>>15),32768)
        return (32768-min((vig*4096*r2)>>15,32768))*100//32768

for de_mode in ("perline","frame"):
    for src in ("de","hs"):
        fx=FX(src)
        for s in gen(3, de_mode): fx.step(*s)
        c=fx.bright(ACT_W//2,ACT_H//2); cor=fx.bright(0,0)
        ok = "OK" if (c>=95 and cor<=60) else "** BROKEN **"
        print(f"de={de_mode:7s} line_src={src:3s} -> W={fx.W:4d} H={fx.H:4d} "
              f"recip_w={fx.recip_w:3d} recip_h={fx.recip_h:3d} | center={c}% corner={cor}%  {ok}")
