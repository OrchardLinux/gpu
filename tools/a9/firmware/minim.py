#!/usr/bin/env python3
"""Experimental MINIM-to-META expander, GP subset (provisional; see the limits below).

usage: minim.py REGION_DIR [BASE ...] [--objdump PATH | --docker-image IMAGE --tools-dir DIR]
       minim.py --base BASE (--pc PC | --storage ADDR)
  REGION_DIR holds <base>.bin images from disassemble-ldr.py. For each BASE (hex;
  default: every <base>.bin there) it writes <base>.expanded.bin, <base>.minim.json,
  <base>.minim-stats.json and, with a META objdump, <base>.minim.dis (original PC,
  storage bytes, decode). The objdump is --objdump, else $METAG_OBJDUMP, else
  --docker-image with --tools-dir; without one only the JSON files are written.
  Keep REGION_DIR out of public repositories: it is Apple firmware.
  --pc/--storage convert between an execution PC and the address the bytes are
  stored at (pc = 2*storage - base), e.g. to read the code at a PC the firmware reports.

Based on public Imagination Meta HTP TRM 2.1.235 section 3.
Produces address-preserving standard instructions for GNU metag objdump.
Rejected encodings are explicit. Other provisional decodes may still be wrong.

Storage is little-endian halfwords: expand()/expand_long() take halves, and
decode_storage()/decode_one() take the exact storage bytes. Short 2-byte
branches are classified and encoded by short_branch()/encode_branch(); the
proven TRM field layout is documented in the block below.
"""
import argparse,collections,os,pathlib,re,struct,json,subprocess
OUT=None; OBJDUMP=None

def pc_to_storage(pc,base):
 """Storage address of the instruction at execution PC `pc` in a region at `base`."""
 if pc<base or (pc-base)%2:raise ValueError(f'{pc:#x} is not a MINIM PC in the region at {base:#x}')
 return base+(pc-base)//2

def storage_to_pc(storage,base):
 """Execution PC of the instruction stored at `storage` in a region at `base`."""
 if storage<base:raise ValueError(f'{storage:#x} is below the region at {base:#x}')
 return 2*storage-base
def bits(x,a,n=1):return (x>>a)&((1<<n)-1)
def sx(x,n):return (x^(1<<(n-1)))-(1<<(n-1))

# Storage convention and the 2-byte branch forms.
# A MINIM instruction is stored as little-endian halfwords: a 2-byte instruction
# is one halfword, a 4-byte instruction is two halfwords with the low one first.
# A halfword begins a 4-byte instruction when it is >= 0xC000 (bits 15..14 = 11,
# the "extended" form) or has bits 15..12 = 0xB (the "long" form); every other
# halfword is a complete 2-byte instruction. Therefore storage-order integers
# such as 0xe397 or 0x2491 are NOT halfwords: 0xe397 is the byte pair e3 97,
# whose halfword is 0x97e3. The trap is real -- expand(0x2491) is a valid ALU
# decode of a different instruction, while the branch in those two bytes is
# expand(0x9124), or safely decode_one(image,0x80000158,0x80000000).
#
# Short branches (TRM 2.1.235 3.2.7 B, 3.2.8 Bcc, 3.2.9 CALLR) are the
# halfwords with bits 15..12 = 0x9, selected by bits 11..10:
#   00  Bcc:   1001 00 S5[9:5]  CC[4:1]  R[0]
#   01  B:     1001 01 S10[9:0]              (no R bit: bit 0 is part of S10)
#   10  CALLR: 1001 10 S10[9:0]              (BB.r = D1RtP)
#   11  MSET/MGET family -- never a branch
# The offset is a signed count of 32-bit instructions, relative to the PC of the
# branch itself: target = pc + offset*4 (TRM 2.2.7/2.2.8: "the offset undergoes
# a fixed multiply by four before use"). The 4-byte extended form holds the same
# 19-bit signed offset as {first halfword bits 13..0, second halfword bits 9..5}
# for B/Bcc, with CC[4:1] and R[0] in the second halfword.
CC_NAMES=('A','EQ','NE','CS','CC','MI','PL','VS','VC','HI','LS','GE','LT','GT','LE','NV')
CC_CODES={name:code for code,name in enumerate(CC_NAMES)}
_BRANCH_FORMS={0:'bcc',1:'b',2:'callr'}
B16_UNITS=(-512,511)                    # S10, TRM 3.2.7
BCC16_UNITS=(-16,15)                    # S5,  TRM 3.2.8
B32_UNITS=(-(1<<18),(1<<18)-1)          # S19, TRM 3.2.7/3.2.8

def classify(hw):
 """Classify a little-endian halfword: ext, long, bcc, b, callr, mset or gp."""
 if hw>=0xc000:return 'ext'
 if hw>>12==0xb:return 'long'
 if hw>>12==9:return _BRANCH_FORMS.get((hw>>10)&3,'mset')
 return 'gp'

def short_branch(hw):
 """Decode a 2-byte MINIM branch halfword; None when the halfword is not one.

 Keys: form ('bcc'|'b'|'callr'), cc (4-bit TRM code, None for b/callr), r, and
 offset (signed count of 32-bit instructions). 0x9C00..0x9FFF is the MSET/MGET
 family and never a branch, so a decoder cannot mistake one for a branch.
 """
 form=_BRANCH_FORMS.get((hw>>10)&3) if hw>>12==9 else None
 if form is None:return None
 if form=='bcc':
  return {'form':'bcc','cc':(hw>>1)&0xf,'r':hw&1,'offset':sx((hw>>5)&0x1f,5)}
 return {'form':form,'cc':None,'r':0,'offset':sx(hw&0x3ff,10)}

def encode_branch(pc,target,cc=0,r=0,size=None):
 """Encode a MINIM branch as storage bytes; returns (bytes,form).

 `cc` is the 4-bit TRM condition code (0=A .. 15=NV) and `r` the repeat bit,
 unlike fwtrace.branch(), whose `cc` is the legacy 5-bit {CC,R} field.
 size=None prefers the shortest exact form: a 2-byte B (0x9400|S10) for a plain
 unconditional branch, a 2-byte Bcc (0x9000|S5<<5|CC<<1|R) when it fits S5, and
 the 4-byte extended form otherwise. size=2 forbids the 4-byte form, size=4
 forces it. Raises ValueError for an unaligned, out-of-range or unrepresentable
 request; never truncates silently.
 """
 if not 0<=cc<=15 or r not in (0,1):
  raise ValueError(f'condition code {cc}/repeat {r} out of range')
 delta=target-pc
 if delta%4:
  raise ValueError(f'branch {pc:#x}->{target:#x} is not 4-byte aligned')
 units=delta//4
 if size not in (None,2,4):
  raise ValueError('size must be None, 2 or 4')
 if size!=4:
  if cc==0 and r==0 and B16_UNITS[0]<=units<=B16_UNITS[1]:
   return struct.pack('<H',0x9400|(units&0x3ff)),'b'
  if BCC16_UNITS[0]<=units<=BCC16_UNITS[1]:
   return struct.pack('<H',0x9000|((units&0x1f)<<5)|(cc<<1)|r),'bcc'
  if size==2:
   raise ValueError(f'{pc:#x}->{target:#x} does not fit a 2-byte MINIM branch')
 if not B32_UNITS[0]<=units<=B32_UNITS[1]:
  raise ValueError(f'branch offset {units} exceeds the 19-bit signed range')
 u=units&0x7ffff
 return struct.pack('<HH',0xc000|(u>>5),0x9000|((u&0x1f)<<5)|(cc<<1)|r),'bcc32'

def long_branch(first,second):
 """Decode a 4-byte extended B/Bcc/CALLR from its two halfwords; else None.

 Bcc32 keeps the 19-bit offset as {first[13:0], second[9:5]} with CC[4:1] and
 R[0]; CALLR32 splits it as {first[13:5], second[9:0]} (TRM 3.2.8/3.2.9
 extended encodings, calibrated on 3783 retained 4-byte branches).
 """
 if first<0xc000 or second>>12!=9:return None
 sub=(second>>10)&3
 if sub==0:
  return {'form':'bcc32','cc':(second>>1)&0xf,'r':second&1,
          'offset':sx(((first&0x3fff)<<5)|((second>>5)&0x1f),19)}
 if sub==2:
  return {'form':'callr32','cc':None,'r':0,
          'offset':sx((((first&0x3fff)>>5)<<10)|(second&0x3ff),19)}
 return None

def decode_storage(data,base=None,start=None):
 """Decode MINIM storage bytes; data[0] is storage address `start` (default 0).

 base=None treats storage addresses as PCs (a bare snippet); base=<segment>
 applies the artifact 2:1 mapping pc=2*storage-base. Each record has pc,
 storage, raw, size, kind, halfwords, expanded (None when the form is
 unimplemented) and, for branches, form/cc/r/offset/target. Raises ValueError on
 a truncated instruction or a trailing byte, so a caller cannot walk a
 desynchronised stream.
 """
 data=bytes(data); start=(base or 0) if start is None else start; rows=[]; i=0
 while i+2<=len(data):
  first=i; hw=struct.unpack_from('<H',data,i)[0]; i+=2
  kind=classify(hw); halfwords=[hw]; expanded=None; branch=None
  if kind in ('ext','long'):
   if i+2>len(data):raise ValueError(f'truncated {kind} instruction at {start+first:#x}')
   second=struct.unpack_from('<H',data,i)[0]; i+=2; halfwords.append(second)
   expanded=expand(second,hw&0x3fff) if kind=='ext' else expand_long(hw,second)
   branch=long_branch(hw,second)
  else:
   expanded=expand(hw)
   branch=short_branch(hw)
  storage=start+first
  row={'pc':storage if base is None else 2*storage-base,'storage':storage,
       'raw':data[first:i],'size':i-first,
       'kind':kind,'halfwords':halfwords,'expanded':expanded}
  if branch is not None:
   row.update(branch); row['target']=row['pc']+branch['offset']*4
  rows.append(row)
 if i!=len(data):raise ValueError('trailing byte in MINIM storage')
 return rows

def decode_one(data,storage,base):
 """Decode the instruction at `storage` inside a region that starts at `base`."""
 return decode_storage(memoryview(data)[storage-base:],base=base,start=storage)[0]


def expand(c,e=None):
 op=c>>12; d=bits(c,7,3);s1=bits(c,4,3);s2=bits(c,1,3);du=bits(c,10);im=bits(c,11)
 if op<=6:
  if e is not None and bits(e,12):
   if op>4 or not im:return None
   rd=d|(bits(e,10,2)<<3);imm=bits(c,1,3)|(bits(e,5,5)<<3)
   w=(op<<28)|(bits(e,13)<<27)|(1<<26)|(1<<25)|(du<<24)|(rd<<19)|(s1<<14)|(imm<<6)
   if bits(e,4):return w|(1<<5)|(bits(e,0,4)<<1)
   return w|(bits(e,0,4)<<1)
  w=(op<<28)|(du<<24)|((bits(e,13) if e is not None else 0)<<27)|(im<<25)|(d<<19)
  if im:
   if op==5:
    rs=bits(e,7,5) if e is not None else d
    return w|(rs<<14)|(bits(c,2,5)<<9)|(bits(c,0,2)<<6)
   val=(bits(c,2,5)|bits(e,1,11)<<5) if e is not None else (((sx(bits(c,2,5),5)&65535) if bits(c,0) else bits(c,2,5)))
   return w|(val<<3)|(bits(c,0,2)<<1)|(bits(e,0) if e is not None else 0)
  a=s1|(bits(e,10,2)<<3 if e is not None else 0);b=s2|(bits(e,8,2)<<3 if e is not None else 0)
  if op==5:
   a=bits(c,5,2)|(bits(e,9,3)<<2 if e is not None else 0)
   b=bits(c,2,3)|(bits(e,7,2)<<3 if e is not None else 0)
   return w|(a<<14)|(b<<9)|(bits(c,0,2)<<6)
  return w|(a<<14)|(b<<9)|((bits(c,0)<<2) if op in (0,1) else 0)|(bits(e,0) if e is not None else 0)|((bits(c,0)<<6) if op==6 else 0)
 if op==7:
  w=0x70000000|(bits(c,11)<<27)|(bits(c,10)<<25)|(bits(c,9)<<24)
  if e is not None and bits(e,13):return None
  rs=bits(c,6,3)
  if bits(c,10):
   val=(bits(c,1,5)|bits(e,2,11)<<5) if e is not None else ((sx(bits(c,1,5),5)&65535) if bits(c,0) else bits(c,1,5))
   return w|(rs<<19)|(val<<3)|(bits(c,0)<<1)|(bits(e,0) if e is not None else 0)|((bits(e,1)<<2) if e is not None else 0)
  if e is not None and bits(e,1,7):return None
  return w|((rs|(bits(e,8,2)<<3 if e is not None else 0))<<14)|(bits(c,1,5)<<9)|bits(c,0)
 if op==8:
  au=bits(c,9);im=bits(c,10);sub=bits(c,11);d=bits(c,7,2)
  w=0x80000000|(sub<<27)|(im<<25)|(au<<24)|(d<<19)
  if e is not None and bits(e,13):return None
  if im:
   val=(bits(c,2,5)|bits(e,1,11)<<5) if e is not None else ((sx(bits(c,2,5),5)&65535) if bits(c,0) else bits(c,2,5))
   return w|(val<<3)|(bits(c,0,2)<<1)|(bits(e,0) if e is not None else 0)
  return w|(bits(c,4,2)<<14)|(bits(c,1,2)<<9)|(bits(c,0)<<2)|(bits(e,0) if e is not None else 0)
 if op==9:
  kind=bits(c,10,2)
  if kind==0:
   off=sx((bits(c,5,5)|(e<<5)) if e is not None else bits(c,5,5),19 if e is not None else 5)
   return 0xa0000000|((off&0x7ffff)<<5)|bits(c,0,5)
  if kind==1:
   if e is not None:return None
   return 0xa0000000|((sx(bits(c,0,10),10)&0x7ffff)<<5)
  if kind==2:
   off=sx((bits(c,0,10)|(bits(e,5,9)<<10)) if e is not None else bits(c,0,10),19 if e is not None else 10)
   return 0xab000000|((off&0x7ffff)<<5)|(bits(e,0,5) if e is not None else 0x14)
  sub=bits(c,8,2)
  if sub==0 and bits(c,4,4) in (8,12):
   if e is None:return None
   us=bits(e,4,4);ud=bits(e,0,4)
   if us==15:us=0
   if ud==15:ud=0
   rs=(bits(e,11,3)<<2)|bits(c,2,2);rd=(bits(e,8,3)<<2)|bits(c,0,2)
   if bits(e,4,4)==15:rs+=16
   if bits(e,0,4)==15:rd+=16
   return 0xa3000000|(rs<<19)|(rd<<14)|(us<<10)|(ud<<5)|(bits(c,6)<<9)
  if sub==0 and bits(c,6,2)==0:
   return 0xa3000000|(bits(c,3,3)<<19)|(0<<14)|((bits(c,0,2) or 4)<<10)|(5<<5)
  if sub==1:
   if bits(c,7)==0:
    rs=bits(c,4,2);rd=bits(c,2,2);ud=3+bits(c,6);us=bits(c,0,2) or 4
   else:
    rs=bits(c,4,2);rd=bits(c,2,2);ud=1+bits(c,6);us=bits(c,0,2) or 4
   return 0xa3000000|(rs<<19)|(rd<<14)|(us<<10)|(ud<<5)
  if sub==2:
   if bits(c,7,1)==0 and bits(c,6)==0:
    rs=bits(c,2,2);rd=bits(c,4,2);ud=3+bits(c,1);us=1+bits(c,0)
   else:
    rs=bits(c,3,3);rd=bits(c,0,3);ud=1+bits(c,7);us=1+bits(c,6)
   return 0xa3000000|(rs<<19)|(rd<<14)|(us<<10)|(ud<<5)

  return None
 if op==10:
  get=bits(c,11);multi=bits(c,10);rd=bits(c,7,3);rb=bits(c,5,2)
  if multi:
   if e is not None:return None
   return ((0xc9000000 if get else 0xb9000000)|(rd<<19)|(rb<<14)|(bits(c,2,3)<<7)|(3<<5)|(bits(c,0,2)<<3))
  if e is None:
   return ((0xc6000000 if get else 0xb6000000)|(rd<<19)|(rb<<14)|((sx(bits(c,2,3),3)&63)<<8)|(3<<5)|((bits(c,0,2) or 4)<<1))
  im=bits(e,12);l2=bits(e,13);l1=bits(e,11)
  rd|=bits(e,10)<<3;rb|=bits(e,9)<<2
  w=((0xc0000000 if get else 0xb0000000)|(l2<<26)|(im<<25)|(l1<<24)|(rd<<19)|(rb<<14))
  w|=bits(e,0) # PP
  w|=bits(e,5)<<7
  if im:w|=((bits(c,2,3)|bits(e,6,3)<<3)<<8)|(bits(e,3,2)<<5)
  else:w|=(bits(e,6,3)<<9)|(bits(c,2,2)<<5)
  w|=(bits(c,0,2)|bits(e,1,2)<<2)<<1
  return w

 return None

def expand_long(h,h2):
 """TRM 3.7.5 DCACHE has 5-bit Rs and 3-bit Rb, unlike other long ops."""
 sub=bits(h,8,4);pay=h2&0x3fff
 if h2>>14==1:
  if sub==13:
   if pay&0x87:return None # reserved bit7 and bits2:0
   return 0xad000000|(bits(h,3,5)<<19)|(bits(h,0,3)<<14)|pay
  if sub in (5,7):return 0xa0000000|(sub<<24)|(bits(h,5,3)<<19)|(bits(h,0,5)<<14)|pay
  return 0xa0000000|(sub<<24)|(bits(h,4,4)<<19)|(bits(h,0,4)<<14)|pay
 if h2>>14==0 and bits(h,10,2)==0:
  return 0xac000000|(bits(h,5,5)<<19)|(bits(h,0,5)<<14)|pay
 return None

# Standard META major opcodes (TRM 2.1.235 section 2), by MINIM bits 15..12 of the main halfword
FAMILY=('ADD','SUB','AND','OR','XOR','shift','MUL','CMP/TST','A-unit ADD/SUB','branch/MOV/MSET','GET/SET')

def unknown_reason(raw):
 """Why expand()/expand_long() rejected the instruction in `raw` (its storage bytes)."""
 h=struct.unpack_from('<H',raw)[0]
 if len(raw)==2:
  return f'short {FAMILY[h>>12]} (op9 group {bits(h,10,2)} sub {bits(h,8,2)})' if h>>12==9 else f'short {FAMILY[h>>12]}'
 h2=struct.unpack_from('<H',raw,2)[0]
 if h<0xc000:return f'long sub {bits(h,8,4):#x}, second halfword {h2>>14:#x}..'
 e=h&0x3fff;op=h2>>12;name=FAMILY[op] if op<len(FAMILY) else f'op {op:#x}'
 if op<=6 and bits(e,12):return f'extended {name}, conditional form (ext bit 12) not implemented for this op/operand'
 if op in (7,8) and bits(e,13):return f'extended {name}, ext bit 13 set'
 if op==7:return f'extended {name}, register form with ext bits 7..1 set'
 if op==9:return f'extended {name} (group {bits(h2,10,2)})'
 if op==10:return f'extended {name}, multi-register form'
 return f'extended {name}'

def stats(rows):
 """Counts for a region: instructions, 0x0000 halfwords, decoded, rejected (by reason)."""
 zero=sum(1 for r in rows if r['raw']=='0000')
 unknown=[r for r in rows if r['expanded'] is None]
 reasons=collections.Counter(unknown_reason(bytes.fromhex(r['raw'])) for r in unknown)
 nonzero=len(rows)-zero
 return {'instructions':len(rows),'zero_halfwords':zero,'nonzero':nonzero,'unknown':len(unknown),
         'decoded_nonzero_percent':round(100*(nonzero-len(unknown))/nonzero,2) if nonzero else None,
         'unknown_by_reason':dict(reasons.most_common())}

def run(base):
 b=(OUT/f'{base:08x}.bin').read_bytes(); out=bytearray(len(b)*2);rows=[];i=0
 while i+2<=len(b):
  start=i;h=struct.unpack_from('<H',b,i)[0];i+=2;e=None;long=False
  if h>=0xc000:
   e=h&0x3fff
   if i+2>len(b):break
   h=struct.unpack_from('<H',b,i)[0];i+=2
  elif h>>12==11:
   long=True
   if i+2>len(b):break
   h2=struct.unpack_from('<H',b,i)[0];i+=2
  pc=base+start*2
  if long:
   w=expand_long(h,h2)
  else:w=expand(h,e)
  if w is not None:struct.pack_into('<I',out,start*2,w)
  rows.append({'pc':hex(pc),'storage':hex(base+start),'raw':b[start:i].hex(),'expanded':hex(w) if w is not None else None})
 (OUT/f'{base:08x}.expanded.bin').write_bytes(out)
 (OUT/f'{base:08x}.minim.json').write_text(json.dumps(rows,indent=1))
 st=dict(base=hex(base),**stats(rows))
 (OUT/f'{base:08x}.minim-stats.json').write_text(json.dumps(st,indent=1)+'\n')
 print(f"{base:08x}: {st['instructions']} instructions, {st['zero_halfwords']} zero halfwords, "
       f"{st['unknown']} UNKNOWN, {st['decoded_nonzero_percent']}% of the nonzero ones expanded")
 if OBJDUMP is None:return st
 # -z: print zero words too; without it objdump folds zero runs into "..." and
 # the 0x0000 halfwords (zero fill) would have no line of their own.
 with (OUT/f'{base:08x}.expanded.dis').open('w') as f:subprocess.run(OBJDUMP(f'{base:08x}.expanded.bin',base),stdout=f,check=True)
 lines={}
 for s in (OUT/f'{base:08x}.expanded.dis').read_text().splitlines():
  m=re.match(r'\s*([0-9a-f]+):\t[0-9a-f ]+\t(.*)$',s)
  if m:lines[int(m.group(1),16)]=m.group(2).strip()
 def text(r):
  if r['expanded'] is None:return 'UNKNOWN'
  t=lines.get(int(r['pc'],16),'?')
  return t+'   ; 0x0000 halfword' if r['raw']=='0000' else t
 (OUT/f'{base:08x}.minim.dis').write_text('\n'.join(f"{r['pc']} [storage {r['storage']} {r['raw']}]: {text(r)}" for r in rows)+'\n')
 return st

def main(argv=None):
 global OUT,OBJDUMP
 ap=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
 ap.add_argument('dir',type=pathlib.Path,nargs='?');ap.add_argument('bases',nargs='*')
 ap.add_argument('--objdump',help='metag-linux-objdump (default: $METAG_OBJDUMP)')
 ap.add_argument('--docker-image');ap.add_argument('--tools-dir',type=pathlib.Path)
 ap.add_argument('--base',type=lambda x:int(x,16),help='region base for --pc/--storage')
 ap.add_argument('--pc',type=lambda x:int(x,16));ap.add_argument('--storage',type=lambda x:int(x,16))
 a=ap.parse_args(argv)
 if a.pc is not None or a.storage is not None:
  if a.base is None:ap.error('--pc/--storage need --base')
  if a.pc is not None:print(f'pc {a.pc:#010x} -> storage {pc_to_storage(a.pc,a.base):#010x}')
  if a.storage is not None:print(f'storage {a.storage:#010x} -> pc {storage_to_pc(a.storage,a.base):#010x}')
  return
 if a.dir is None:ap.error('REGION_DIR is required')
 OUT=a.dir.resolve()
 flags=lambda base:['-D','-z','-b','binary','-m','metag',f'--adjust-vma={base}']
 objdump=a.objdump or os.environ.get('METAG_OBJDUMP')
 if objdump:OBJDUMP=lambda n,base:[objdump]+flags(base)+[str(OUT/n)]
 elif a.docker_image and a.tools_dir:OBJDUMP=lambda n,base:['docker','run','--rm','-v',f'{OUT}:/fw','-v',f'{a.tools_dir.resolve()}:/tools',a.docker_image,'/tools/bin/metag-linux-objdump']+flags(base)+[f'/fw/{n}']
 bases=[int(x,16) for x in a.bases] or sorted(int(p.stem,16) for p in OUT.glob('*.bin') if len(p.stem)==8 and p.stem.isalnum() and '.' not in p.stem)
 for base in bases:run(base)

if __name__=='__main__':main()
