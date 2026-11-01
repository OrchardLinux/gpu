#!/usr/bin/env python3
"""Decode a captured Rogue VDM control stream (render path, RENDER.md).

Block layouts follow Mesa's src/imagination/csbgen/rogue/vdm.xml. The stream
holds GPU addresses; the capture names regions by CPU address, so the stream's
own GPU base is given (STREAM_LINK targets inside it are then followed).

  vdm-decode.py REGION.bin GPU_BASE [START_OFFSET]
"""
import struct
import sys

TYPES = ('PPP_STATE_UPDATE', 'PDS_STATE_UPDATE', 'VDM_STATE_UPDATE', 'INDEX_LIST',
         'STREAM_LINK', 'STREAM_RETURN', 'STREAM_TERMINATE', 'CONTROL')
TOPOLOGY = ('POINT_LIST', 'LINE_LIST', 'LINE_LIST_ADJ', 'LINE_STRIP', 'LINE_STRIP_ADJ',
            'LINE_LOOP', 'TRI_LIST', 'TRI_LIST_ADJ', 'TRI_LIST_EDGE', 'TRI_STRIP',
            'TRI_STRIP_ADJ', 'TRI_FAN', 'PATCH_LIST')


def bits(word, start, end):
    return word >> start & ((1 << (end - start + 1)) - 1)


def decode(data, gpu_base, offset=0, limit=400):
    words = struct.unpack(f'<{len(data) // 4}I', data)
    i = offset // 4
    for _ in range(limit):
        w = words[i]
        kind = TYPES[w >> 29]
        at = f'+{4 * i:#06x}'
        if kind == 'PPP_STATE_UPDATE':
            address = bits(w, 0, 7) << 32 | words[i + 1] & ~3
            print(f'{at} PPP_STATE  {bits(w, 8, 15)} words at {address:#x}')
            i += 2
        elif kind == 'PDS_STATE_UPDATE':
            s1, s2 = words[i + 1], words[i + 2]
            print(f'{at} PDS_STATE  dm={"DDM" if bits(w, 28, 28) else "VDM"} '
                  f'usc_common={bits(w, 16, 24)}x64 usc_unified={bits(w, 10, 15)}x16 '
                  f'temps={bits(w, 6, 9)}x16 data={bits(w, 0, 5)}x16 '
                  f'data_addr={s1 & ~0xf:#x} sd={bits(s1, 2, 3)}/{bits(s1, 0, 1)} '
                  f'code_addr={s2 & ~0xf:#x}')
            i += 3
        elif kind == 'VDM_STATE_UPDATE':
            fields = [f'cam_size={bits(w, 7, 14)}', f'flatshade={bits(w, 1, 2)}']
            i += 1
            if bits(w, 28, 28):
                fields.append(f'cut_index={words[i]:#x}')
                i += 1
            if bits(w, 27, 27):
                fields.append(f'vs_pds_data={words[i] & ~0xf:#x}')
                i += 1
            if bits(w, 26, 26):
                s3, s4, s5 = words[i:i + 3]
                fields.append(f'vs_pds_code={s3 & ~0xf:#x} vs_output={bits(s4, 0, 7)}x4 '
                              f'max_inst={bits(s5, 25, 29)} usc_common={bits(s5, 16, 24)}x64 '
                              f'usc_unified={bits(s5, 10, 15)}x16 temps={bits(s5, 6, 9)}x16 '
                              f'data={bits(s5, 0, 5)}x16')
                i += 3
            for name, bit in (('ds', 24), ('gs', 23), ('hs', 22)):
                if bits(w, bit, bit):
                    fields.append(f'{name}?')
            print(f'{at} VDM_STATE  ' + ' '.join(fields))
        elif kind == 'INDEX_LIST':
            topology = bits(w, 8, 11)
            fields = [TOPOLOGY[topology] if topology < len(TOPOLOGY) else f'topology {topology}',
                      ('B8', 'B16', 'B32', '?')[bits(w, 17, 18)]]
            i += 1
            if bits(w, 28, 28):
                fields.append(f'index_addr={bits(w, 0, 7) << 32 | words[i]:#x}')
                i += 1
            for name, bit in (('count', 27), ('instances', 26), ('offset', 25), ('start', 24)):
                if bits(w, bit, bit):
                    fields.append(f'{name}={words[i]}')
                    i += 1
            if bits(w, 24, 24):  # start_instance follows start_index
                fields.append(f'start_instance={words[i]}')
                i += 1
            if bits(w, 23, 23):
                fields.append(f'indirect={words[i] << 32 | words[i + 1]:#x}')
                i += 2
            if bits(w, 22, 22):
                fields.append(f'split_count={words[i] & 0xffff}')
                i += 1
            print(f'{at} INDEX_LIST ' + ' '.join(fields))
        elif kind == 'STREAM_LINK':
            target = bits(w, 0, 7) << 32 | words[i + 1] & ~3
            ret = ' with return' if bits(w, 28, 28) else ''
            print(f'{at} STREAM_LINK -> {target:#x}{ret}')
            if gpu_base <= target < gpu_base + len(data) and not ret:
                i = (target - gpu_base) // 4
            else:
                i += 2
        elif kind == 'STREAM_TERMINATE':
            print(f'{at} STREAM_TERMINATE')
            return
        else:
            print(f'{at} {kind} {w:#010x}')
            return


if __name__ == '__main__':
    path, base = sys.argv[1], int(sys.argv[2], 0)
    decode(open(path, 'rb').read(), base, int(sys.argv[3], 0) if len(sys.argv) > 3 else 0)
