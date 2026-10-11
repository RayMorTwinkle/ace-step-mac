#!/usr/bin/env python3
"""Rewrite a GGUF converting every BF16 tensor to F32 (lossless bit-expansion).

Needed for Metal devices without bfloat16 support (Apple Paravirtual GPU,
pre-M2 chips): ggml's Metal backend refuses ops touching BF16 tensors and the
scheduler aborts when such a weight is pre-allocated in an MTL buffer.
"""
import struct
import sys
import numpy as np

GGML_TYPE_F32 = 0
GGML_TYPE_BF16 = 30
BLOCK_SIZE = {0: 1, 30: 1}
TYPE_SIZE = {0: 4, 30: 2}

VAL_SIZE = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


def read_str(buf, off):
    (n,) = struct.unpack_from("<Q", buf, off)
    off += 8
    s = buf[off : off + n]
    return s, off + n


def parse_header(buf):
    assert buf[:4] == b"GGUF"
    version, tcount, kvcount = struct.unpack_from("<IQQ", buf, 4)
    off = 24
    kv = {}
    kv_bytes_end = None
    for _ in range(kvcount):
        key, off = read_str(buf, off)
        (vtype,) = struct.unpack_from("<I", buf, off)
        off += 4
        if vtype == 8:
            val, off = read_str(buf, off)
        elif vtype == 9:
            (etype,) = struct.unpack_from("<I", buf, off)
            off += 4
            (cnt,) = struct.unpack_from("<Q", buf, off)
            off += 8
            if etype == 8:
                vals = []
                for _ in range(cnt):
                    v, off = read_str(buf, off)
                    vals.append(v)
                val = vals
            else:
                nbytes = cnt * VAL_SIZE[etype]
                val = buf[off : off + nbytes]
                off += nbytes
        else:
            nbytes = VAL_SIZE[vtype]
            val = buf[off : off + nbytes]
            off += nbytes
        kv[key] = (vtype, val)
    kv_bytes_end = off
    infos = []
    for _ in range(tcount):
        name, off = read_str(buf, off)
        (nd,) = struct.unpack_from("<I", buf, off)
        off += 4
        dims = struct.unpack_from("<%dQ" % nd, buf, off)
        off += 8 * nd
        (ttype,) = struct.unpack_from("<I", buf, off)
        off += 4
        (toff,) = struct.unpack_from("<Q", buf, off)
        off += 8
        infos.append({"name": name, "dims": dims, "type": ttype, "offset": toff})
    align = 32
    if b"general.alignment" in kv:
        align = struct.unpack("<I", kv[b"general.alignment"][1])[0]
    data_start = (off + align - 1) // align * align
    return version, tcount, kvcount, kv_bytes_end, off, data_start, align, infos


def convert(src, dst):
    buf = open(src, "rb").read()
    version, tcount, kvcount, kv_end, infos_end, data_start, align, infos = parse_header(buf)

    # order tensor data by offset
    order = sorted(infos, key=lambda t: t["offset"])
    n_conv = sum(1 for t in infos if t["type"] == GGML_TYPE_BF16)
    print(f"{src}: {tcount} tensors, {n_conv} BF16 -> F32, align={align}, data_start={data_start}")

    # build new tensor payloads
    new_blobs = []
    cur = 0
    for t in order:
        n_el = 1
        for d in t["dims"]:
            n_el *= d
        if t["type"] == GGML_TYPE_BF16:
            raw = buf[data_start + t["offset"] : data_start + t["offset"] + n_el * 2]
            a16 = np.frombuffer(raw, dtype=np.uint16)
            f32 = (a16.astype(np.uint32) << 16).view(np.float32)
            t["new_type"] = GGML_TYPE_F32
            blob = f32.tobytes()
        else:
            size = n_el * TYPE_SIZE.get(t["type"], 0)
            if size == 0:
                # quant type: find end via next tensor or file end
                idx = order.index(t)
                if idx + 1 < len(order):
                    end = data_start + order[idx + 1]["offset"]
                else:
                    end = len(buf)
                size = end - (data_start + t["offset"])
            t["new_type"] = t["type"]
            blob = buf[data_start + t["offset"] : data_start + t["offset"] + size]
        # pad blob to alignment
        pad = (align - (len(blob) % align)) % align
        new_blobs.append(blob + b"\x00" * pad)
        t["new_offset"] = cur
        cur += len(blob) + pad

    with open(dst, "wb") as f:
        # header: magic, version, counts (unchanged)
        f.write(buf[:24])
        # kv section verbatim
        f.write(buf[24:kv_end])
        # tensor infos
        for t in infos:
            f.write(struct.pack("<Q", len(t["name"])) + t["name"])
            f.write(struct.pack("<I", len(t["dims"])))
            f.write(struct.pack("<%dQ" % len(t["dims"]), *t["dims"]))
            f.write(struct.pack("<I", t["new_type"]))
            f.write(struct.pack("<Q", t["new_offset"]))
        # padding to data_start
        pos = f.tell()
        f.write(b"\x00" * (data_start - pos))
        for blob in new_blobs:
            f.write(blob)
    print(f"wrote {dst}")


if __name__ == "__main__":
    if sys.argv[1] == "--check":
        with open(sys.argv[2], "rb") as fh:
            buf = fh.read(16 * 1024 * 1024)
        *_, infos = parse_header(buf)
        sys.exit(0 if any(t["type"] == GGML_TYPE_BF16 for t in infos) else 1)
    convert(sys.argv[1], sys.argv[2])
