#!/usr/bin/env python3
"""Apply LiveContainer's executable-to-dylib transform to our own ARM64 Simulator fixture.
Derived from LCPatchExecSlice, LiveContainer commit 9d6ea09b; AGPL-3.0.
Only accepts our PokiFixture / PokiWorker helpers, retains LC_MAIN, and requires header padding.
The caller must ad-hoc re-sign the modified fixture with macOS codesign.
"""
import struct,sys
from pathlib import Path
p=Path(sys.argv[1]);assert p.name in ('PokiFixture','PokiWorker')
b=bytearray(p.read_bytes());h=list(struct.unpack_from('<8I',b));assert h[0]==0xfeedfacf and h[1]==0x100000c and h[3]==2
pos=32;textoff=None
for i in range(h[4]):
 cmd,size=struct.unpack_from('<II',b,pos)
 if cmd==0x19:
  seg=bytes(b[pos+8:pos+24]).rstrip(b'\0')
  if seg==b'__PAGEZERO':struct.pack_into('<QQ',b,pos+24,0xffffc000,0x4000)
  if seg==b'__TEXT':
   nsects=struct.unpack_from('<I',b,pos+64)[0]
   for j in range(nsects):
    off=pos+72+j*80
    if bytes(b[off:off+16]).rstrip(b'\0')==b'__text':textoff=struct.unpack_from('<I',b,off+48)[0]
 pos+=size
assert pos==32+h[5]
commands=[]
loads=[(0xd,p.name)]
if p.name=='PokiFixture':loads.append((0xc,'@loader_path/../../Tweaks/TweakLoader.dylib'))
for cmd,name in loads:
 data=name.encode()+b'\0';data=data.ljust((len(data)+7)//8*8,b'\0');commands.append(struct.pack('<6I',cmd,24+len(data),24,0,0,0)+data)
extra=b''.join(commands);assert textoff and pos+len(extra)<=textoff, 'Need -Wl,-headerpad,0x4000'
b[pos:pos+len(extra)]=extra;h[3]=6;h[4]+=len(commands);h[5]+=len(extra);h[6]=(h[6]|0x100000)&~0x200000;struct.pack_into('<8I',b,0,*h);p.write_bytes(b)
print('Patched own fixture, added %d load-command bytes'%len(extra))
