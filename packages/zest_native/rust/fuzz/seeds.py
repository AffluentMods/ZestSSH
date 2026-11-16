"""Seed corpora for the fuzz targets: the unit tests' synthetic server streams, written as each
target reads its input (see the target's header). `fuzz/run.sh seeds` runs it; it writes
corpus/<target>/seed-<name> and leaves the rest of a corpus alone.

Python's zlib makes the zlib streams (Zlib, Tight, ZRLE, the extended clipboard) as the server's
would be; the Tight JPEG is the engine's own test picture (src/vnc/engine/codec/testdata).
"""

import base64
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
JPEG = os.path.join(HERE, "..", "src", "vnc", "engine", "codec", "testdata", "tight_test.jpg")

# Encodings on the wire.
RAW, COPYRECT, RRE, HEXTILE, ZLIB, TIGHT, TRLE, ZRLE = 0, 1, 2, 5, 6, 7, 15, 16
CURSOR, DESKTOP_SIZE, LAST_RECT, EXT_DESKTOP_SIZE, QEMU_KEYS = -239, -223, -224, -308, -258

# The client's pixel format (PixelFormat::rgba): 32 bits, depth 24, little-endian, red at 0,
# green at 8, blue at 16.
RGBA_FORMAT = bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 0, 8, 16, 0, 0, 0])


def u16(v):
    return struct.pack(">H", v)


def u32(v):
    return struct.pack(">I", v & 0xFFFFFFFF)


def i32(v):
    return struct.pack(">i", v)


def handshake(width, height, version=b"RFB 003.008\n", security=b"\x01\x01" + u32(0)):
    return version + security + u16(width) + u16(height) + RGBA_FORMAT + u32(4) + b"demo"


def server_init(width, height):
    return u16(width) + u16(height) + RGBA_FORMAT + u32(4) + b"demo"


def update(*rects):
    b = b"\x00\x00" + u16(len(rects))
    for (x, y, w, h, enc, payload) in rects:
        b += u16(x) + u16(y) + u16(w) + u16(h) + i32(enc) + payload
    return b


def pixel(r, g, b):
    return bytes([r, g, b, 0])


def cpixel(r, g, b):
    return bytes([r, g, b])


def compact(n):
    out = bytearray([n & 0x7F])
    if n > 0x7F:
        out[0] |= 0x80
        out.append((n >> 7) & 0x7F)
        if n > 0x3FFF:
            out[1] |= 0x80
            out.append((n >> 14) & 0xFF)
    return bytes(out)


def raw(w, h):
    return b"".join(pixel(x * 9 % 256, y * 7 % 256, (x + y) % 256) for y in range(h) for x in range(w))


def rre(w, h):
    subs = [(pixel(255, 0, 0), 0, 0, min(2, w), min(2, h)), (pixel(0, 255, 0), w - 1, h - 1, 1, 1)]
    b = u32(len(subs)) + pixel(1, 2, 3)
    for (p, x, y, sw, sh) in subs:
        b += p + u16(x) + u16(y) + u16(sw) + u16(sh)
    return b


def hextile(w, h):
    b = b""
    tiles = 0
    for ty in range(0, h, 16):
        for tx in range(0, w, 16):
            tw, th = min(16, w - tx), min(16, h - ty)
            kind = tiles % 4
            if kind == 0:
                b += b"\x01" + raw(tw, th)
            elif kind == 1:
                b += b"\x02" + pixel(10, 20, 30)
            elif kind == 2:
                b += bytes([2 | 4 | 8]) + pixel(1, 1, 1) + pixel(200, 0, 0) + b"\x01" + bytes([0x00, 0x11])
            else:
                b += bytes([8 | 16]) + b"\x02" + pixel(0, 0, 255) + bytes([0x11, 0x00]) + pixel(0, 255, 0) + bytes([0x00, 0x00])
            tiles += 1
    return b


def zlib_rect(w, h):
    data = zlib.compress(raw(w, h))
    return u32(len(data)) + data


def tight_rects(w, h):
    """Each Tight mode as one payload for a w x h rectangle."""
    out = {}
    out["fill"] = b"\x80" + cpixel(1, 2, 3)
    basic = b"".join(cpixel(x % 256, y % 256, 7) for y in range(h) for x in range(w))
    out["basic"] = b"\x00" + (basic if len(basic) < 12 else compact(len(zlib.compress(basic))) + zlib.compress(basic))
    # Palette of two: one bit a pixel, rows padded to a byte.
    bits = b"".join(bytes([0b10101010 & (0xFF << (8 - min(8, w - i)) & 0xFF) for i in range(0, w, 8)]) for _ in range(h))
    pal = b"\x40\x01\x01" + cpixel(1, 2, 3) + cpixel(4, 5, 6)
    out["palette2"] = pal + (bits if len(bits) < 12 else compact(len(zlib.compress(bits))) + zlib.compress(bits))
    # Palette of four: a byte a pixel.
    idx = bytes((x + y) % 4 for y in range(h) for x in range(w))
    pal4 = b"\x50\x01\x03" + cpixel(1, 2, 3) + cpixel(4, 5, 6) + cpixel(7, 8, 9) + cpixel(10, 11, 12)
    out["palette4"] = pal4 + (idx if len(idx) < 12 else compact(len(zlib.compress(idx))) + zlib.compress(idx))
    grad = b"".join(cpixel(1, 1, 1) for _ in range(w * h))
    out["gradient"] = b"\x60\x02" + (grad if len(grad) < 12 else compact(len(zlib.compress(grad))) + zlib.compress(grad))
    with open(JPEG, "rb") as f:
        jpeg = f.read()
    out["jpeg"] = b"\x90" + compact(len(jpeg)) + jpeg
    out["reset"] = b"\xf0" + cpixel(9, 9, 9)
    return out


def rle_tiles(w, h, side, zlibbed):
    """TRLE (side 16, no zlib) or ZRLE (side 64, zlib with a U32 length)."""
    b = b""
    kinds = 0
    for ty in range(0, h, side):
        for tx in range(0, w, side):
            tw, th = min(side, w - tx), min(side, h - ty)
            n = tw * th
            k = kinds % 5
            if k == 0:
                b += b"\x00" + b"".join(cpixel(i % 256, 3, 4) for i in range(n))
            elif k == 1:
                b += b"\x01" + cpixel(5, 6, 7)
            elif k == 2:
                # Packed palette of two: a bit a pixel, rows padded.
                row = bytes([0b01010101] * ((tw + 7) // 8))
                b += b"\x02" + cpixel(1, 1, 1) + cpixel(2, 2, 2) + row * th
            elif k == 3:
                # Plain RLE: one run of the whole tile.
                left = n - 1
                b += b"\x80" + cpixel(8, 8, 8) + b"\xff" * (left // 255) + bytes([left % 255])
            else:
                # Palette RLE: index with the top bit and a run, then single pixels.
                b += bytes([128 + 2]) + cpixel(1, 2, 3) + cpixel(3, 2, 1)
                left = n - 1
                b += b"\x80" + b"\xff" * (left // 255) + bytes([left % 255]) if n > 1 else b"\x00"
            kinds += 1
    if zlibbed:
        data = zlib.compress(b)
        return u32(len(data)) + data
    return b


def cursor(w, h):
    return raw(w, h) + bytes([0xFF] * (((w + 7) // 8) * h))


def ext_desktop(screens):
    b = bytes([len(screens), 0, 0, 0])
    for (sid, x, y, w, h) in screens:
        b += u32(sid) + u16(x) + u16(y) + u16(w) + u16(h) + u32(0)
    return b


def clipboard(body):
    return b"\x03\x00\x00\x00" + i32(-len(body)) + body


TEXT, CAPS, REQUEST, PEEK, NOTIFY, PROVIDE = 1, 1 << 24, 1 << 25, 1 << 26, 1 << 27, 1 << 28


def clipboard_bodies():
    text = "hello é\r\nworld".encode() + b"\x00"
    return {
        "caps": u32(CAPS | TEXT | REQUEST | PEEK | NOTIFY | PROVIDE) + u32(20 * 1024 * 1024),
        "notify": u32(NOTIFY | TEXT),
        "request": u32(REQUEST | TEXT),
        "peek": u32(PEEK),
        "provide": u32(PROVIDE | TEXT) + zlib.compress(u32(len(text)) + text),
        "provide_unfinished": u32(PROVIDE | TEXT) + zlib.compressobj().compress(u32(len(text)) + text)
        + zlib.compressobj().flush(zlib.Z_SYNC_FLUSH),
    }


def messages():
    """Server messages after the handshake, for a 64 x 48 screen."""
    m = {}
    m["raw"] = update((5, 4, 4, 3, RAW, raw(4, 3)))
    m["copyrect"] = update((0, 0, 8, 8, COPYRECT, u16(10) + u16(10)))
    m["rre"] = update((2, 2, 10, 10, RRE, rre(10, 10)))
    m["hextile"] = update((0, 0, 40, 20, HEXTILE, hextile(40, 20)))
    m["zlib"] = update((0, 0, 8, 8, ZLIB, zlib_rect(8, 8))) + update((8, 8, 4, 4, ZLIB, zlib_rect(4, 4)))
    for name, payload in tight_rects(16, 4).items():
        m["tight_" + name] = update((0, 0, 16, 4, TIGHT, payload))
    m["trle"] = update((0, 0, 40, 33, TRLE, rle_tiles(40, 33, 16, False)))
    m["zrle"] = update((0, 0, 64, 48, ZRLE, rle_tiles(64, 48, 64, True)))
    m["cursor"] = update((3, 4, 9, 7, CURSOR, cursor(9, 7)), (0, 0, 0, 0, CURSOR, b""))
    m["desktop_size"] = update((0, 0, 80, 60, DESKTOP_SIZE, b"")) + update((0, 0, 80, 60, RAW, raw(80, 60)))
    m["ext_desktop_size"] = update((0, 0, 100, 50, EXT_DESKTOP_SIZE, ext_desktop([(1, 0, 0, 50, 50), (2, 50, 0, 50, 50)])))
    m["ext_desktop_reply"] = update((1, 0, 64, 48, EXT_DESKTOP_SIZE, ext_desktop([(7, 0, 0, 64, 48)])))
    m["last_rect"] = b"\x00\x00\xff\xff" + u16(0) * 4 + i32(RAW) + b"" + u16(0) * 4 + i32(LAST_RECT)
    m["last_rect"] = b"\x00\x00\xff\xff" + u16(1) + u16(1) + u16(1) + u16(1) + i32(RAW) + pixel(1, 2, 3) + u16(0) * 4 + i32(LAST_RECT)
    m["qemu"] = update((0, 0, 0, 0, QEMU_KEYS, b""))
    m["bell"] = b"\x02"
    m["cut_text"] = b"\x03\x00\x00\x00" + u32(5) + b"hel\xe9o"
    for name, body in clipboard_bodies().items():
        m["clipboard_" + name] = clipboard(body)
    m["cu_and_fence"] = b"\x96" + b"\xf8\x00\x00\x00" + u32(0x80000003) + b"\x04abcd" + b"\x96"
    m["colour_map"] = b"\x01\x00" + u16(0) + u16(1) + u16(1) * 3
    m["all"] = b"".join(v for k, v in sorted(m.items()) if k not in ("colour_map",))
    return m


def write(corpus, target, name, data):
    d = os.path.join(corpus, target)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "seed-" + name), "wb") as f:
        f.write(data)


def main():
    corpus = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "corpus")
    msgs = messages()

    # vnc_messages: width and height (U16 each, taken modulo 1024, plus one), options, input, then
    # the messages for a 64 x 48 screen.
    for name, m in msgs.items():
        write(corpus, "vnc_messages", name, u16(63) + u16(47) + b"\x00\x00" + m)
    write(corpus, "vnc_messages", "all_input", u16(63) + u16(47) + b"\x40\x3f" + msgs["all"])

    # vnc_handshake: options, input, then the server from its banner.
    first = msgs["raw"] + msgs["bell"]
    write(corpus, "vnc_handshake", "none_3_8", b"\x00\x00" + handshake(64, 48) + first)
    write(corpus, "vnc_handshake", "none_3_3", b"\x00\x00" + b"RFB 003.003\n" + u32(1) + server_init(64, 48) + first)
    write(corpus, "vnc_handshake", "none_3_7", b"\x00\x00" + b"RFB 003.007\n" + b"\x02\x01\x02" + server_init(64, 48) + first)
    write(corpus, "vnc_handshake", "vncauth", b"\x01\x00" + b"RFB 003.008\n" + b"\x01\x02" + bytes(range(16)) + u32(0) + server_init(64, 48) + first)
    write(corpus, "vnc_handshake", "vncauth_3_3", b"\x01\x00" + b"RFB 003.003\n" + u32(2) + bytes(range(16)) + u32(0) + server_init(64, 48) + first)
    write(corpus, "vnc_handshake", "auth_failed", b"\x01\x00" + b"RFB 003.008\n" + b"\x01\x02" + bytes(16) + u32(1) + u32(6) + b"denied")
    write(corpus, "vnc_handshake", "refused", b"\x00\x00" + b"RFB 003.008\n" + b"\x00" + u32(4) + b"busy")
    p = (2**127 - 1).to_bytes(16, "big")
    ard = u16(2) + u16(16) + p + (12345).to_bytes(16, "big") + u32(0)
    write(corpus, "vnc_handshake", "ard", b"\x03\x00" + b"RFB 003.008\n" + b"\x02\x1e\x02" + ard + server_init(64, 48) + first)
    vencrypt = b"\x00\x02" + b"\x00" + b"\x03" + u32(262) + u32(261) + u32(260)
    write(corpus, "vnc_handshake", "vencrypt", b"\x0b\x00" + b"RFB 003.008\n" + b"\x01\x13" + vencrypt + b"\x01" + b"\x15\x03\x03\x00\x02\x02\x28")
    write(corpus, "vnc_handshake", "many_types", b"\x03\x00" + b"RFB 003.008\n" + b"\x05\x01\x02\x10\x13\x1e" + u32(0) + server_init(64, 48) + first)

    # vnc_ard: the server's DH parameters on.
    write(corpus, "vnc_ard", "ard", ard + server_init(64, 48) + first)
    p512 = (2**521 - 1).to_bytes(66, "big")
    write(corpus, "vnc_ard", "ard_66", u16(5) + u16(66) + p512 + (99991).to_bytes(66, "big") + u32(0) + server_init(64, 48))

    # vnc_vencrypt: options, then the server from VeNCrypt's version.
    write(corpus, "vnc_vencrypt", "subtypes", b"\x00" + vencrypt + b"\x01" + b"\x16\x03\x03\x00\x04\x02\x00\x00\x00")
    write(corpus, "vnc_vencrypt", "plain", b"\x03" + b"\x00\x02\x00\x01" + u32(262) + b"\x01")
    write(corpus, "vnc_vencrypt", "refused", b"\x00" + b"\x00\x02\x00\x01" + u32(2) + b"\x00")

    # vnc_clipboard: input flags, the body's length, the body (and what follows).
    for name, body in clipboard_bodies().items():
        write(corpus, "vnc_clipboard", name, b"\x04" + u16(len(body)) + body + msgs["bell"])

    # rect_<encoding>: x, y, w - 1, h - 1 (each a byte), options, then the payload.
    def rect(target, name, x, y, w, h, payload, flags=0):
        write(corpus, target, name, bytes([x, y, w - 1, h - 1, flags]) + payload)

    rect("rect_raw", "raw", 1, 2, 5, 3, raw(5, 3))
    rect("rect_copyrect", "copyrect", 10, 10, 20, 20, u16(0) + u16(0))
    rect("rect_rre", "rre", 0, 0, 10, 10, rre(10, 10))
    rect("rect_hextile", "hextile", 3, 1, 40, 20, hextile(40, 20))
    rect("rect_hextile", "hextile_small", 0, 0, 5, 5, hextile(5, 5))
    rect("rect_zlib", "zlib", 0, 0, 8, 8, zlib_rect(8, 8))
    rect("rect_zlib", "zlib_twice", 0, 0, 8, 8, zlib_rect(8, 8) + update((0, 0, 8, 8, ZLIB, zlib_rect(8, 8))))
    for name, payload in tight_rects(16, 4).items():
        rect("rect_tight", name, 0, 0, 16, 4, payload)
    for name, payload in tight_rects(3, 2).items():
        rect("rect_tight", name + "_3x2", 1, 1, 3, 2, payload)
    rect("rect_trle", "trle", 0, 0, 40, 33, rle_tiles(40, 33, 16, False))
    rect("rect_zrle", "zrle", 0, 0, 100, 70, rle_tiles(100, 70, 64, True))
    rect("rect_zrle", "zrle_small", 0, 0, 5, 3, rle_tiles(5, 3, 64, True))
    rect("rect_cursor", "cursor", 3, 4, 9, 7, cursor(9, 7))
    rect("rect_cursor", "cursor_1", 0, 0, 1, 1, cursor(1, 1))
    rect("rect_desktop_size", "layout", 0, 0, 100, 50, ext_desktop([(1, 0, 0, 50, 50), (2, 50, 0, 50, 50)]))
    rect("rect_desktop_size", "reply", 1, 0, 64, 48, ext_desktop([(7, 0, 0, 64, 48)]))

    # screen_feed: request choice, input, then the channel's bytes.
    write(corpus, "screen_feed", "vnc_none", b"\x00\x00" + handshake(64, 48) + msgs["all"])
    write(corpus, "screen_feed", "vnc_prefixed", b"\x80\x3f" + msgs["all"])
    write(corpus, "screen_feed", "vnc_auth", b"\x01\x07" + b"RFB 003.008\n" + b"\x01\x02" + bytes(range(16)) + u32(0) + server_init(64, 48) + msgs["raw"])
    write(corpus, "screen_feed", "vnc_encodings", b"\x86\x00" + msgs["trle"] + msgs["zrle"] + msgs["tight_jpeg"])
    # RDP: an X.224 Connection Confirm choosing TLS, then a TLS alert.
    x224 = b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x1f\x08\x00\x01\x00\x00\x00"
    write(corpus, "screen_feed", "rdp_x224", b"\x03\x00" + x224 + b"\x15\x03\x03\x00\x02\x02\x28")
    write(corpus, "screen_feed", "rdp_bitmap", b"\x0b\x00" + x224)

    # screen_open: requests.
    for name, req in {
        "vnc": '{"kind":"vnc","tile_size":64}',
        "vnc_full": '{"kind":"vnc","username":"a","password":"p","tls_pin":"' + "ab" * 32
        + '","require_tls":true,"shared":false,"encodings":["Tight","JpegQuality9","zrle"],"tile_size":0,"continuous_updates":false}',
        "rdp": '{"kind":"rdp","width":1024,"height":768,"rdp_graphics":"remotefx","rdp_h264":"avc420","server_name":"x","domain":"d"}',
        "bad_pin": '{"kind":"vnc","tls_pin":"zz"}',
        "bad_encoding": '{"kind":"vnc","encodings":["nope"]}',
        "other": '{"kind":"spice"}',
    }.items():
        write(corpus, "screen_open", name, req.encode())

    # certificate: the engine's VeNCrypt test certificate (PEM decoded to DER), pins, names.
    import base64
    pem = open(os.path.join(HERE, "..", "src", "vnc", "engine", "client", "vencrypt_test_identity.pem")).read()
    blocks = pem.split("-----BEGIN ")
    for i, block in enumerate(blocks[1:]):
        kind, _, rest = block.partition("-----")
        if kind.startswith("CERTIFICATE"):
            body = rest.split("-----END")[0]
            write(corpus, "certificate", f"cert{i}", base64.b64decode("".join(body.split())))
    write(corpus, "certificate", "pin", ("ab:" * 31 + "ab").encode())
    write(corpus, "certificate", "encoding", b"JpegQuality7")

    # jpeg: width - 1, height - 1, then the engine's test picture (16 x 8).
    with open(JPEG, "rb") as f:
        write(corpus, "jpeg", "tight_test", bytes([15, 7]) + f.read())

    # rdp_fastpath: a fast-path PDU with a bitmap update and a surface command.
    bitmap = u16le(1) + u16le(1) + (u16le(0) * 4 + u16le(4) + u16le(4) + u16le(32) + u16le(1) + u16le(4) + b"\x00" * 4)
    surface = u16le(1) + u16le(0) * 4 + bytes([32, 0, 0, 3]) + u16le(4) + u16le(4) + struct.pack("<I", 4) + b"\x00" * 4
    body = bytes([0x01]) + u16le(len(bitmap)) + bitmap + bytes([0x04]) + u16le(len(surface)) + surface + bytes([0x03]) + u16le(0)
    write(corpus, "rdp_fastpath", "updates", bytes([0x00, 0x80 | ((len(body) + 3) >> 8), (len(body) + 3) & 0xFF]) + body)
    write(corpus, "rdp_fastpath", "encrypted", b"\x80\x05\x00\x00\x00")

    # rdp_gfx: channel messages (2-byte length, big-endian), each RDP_SEGMENTED_DATA with one
    # uncompressed segment (0xE0, then 0x04: RDP8 bulk type, not compressed) of RDPGFX PDUs.
    def gfx(cmd, body):
        return u16le(cmd) + u16le(0) + struct.pack("<I", 8 + len(body)) + body

    def seg(pdus):
        m = b"\xe0\x04" + pdus
        return u16(len(m)) + m

    caps_confirm = gfx(0x13, struct.pack("<II", 0x000A0600, 4) + struct.pack("<I", 0))
    # Reset Graphics is 340 bytes with its header: the size, one monitor (its edges inclusive, then
    # its flags: primary), padding. (Until an earlier fix the monitor here was 16 bytes and
    # the PDU 348, so everything after it in this seed was refused.)
    reset = gfx(0x0E, struct.pack("<III", 64, 48, 1) + struct.pack("<IIIII", 0, 0, 63, 47, 1) + b"\x00" * (332 - 32))
    create = gfx(0x09, u16le(1) + u16le(64) + u16le(48) + b"\x20")
    map_out = gfx(0x0F, u16le(1) + u16le(0) + struct.pack("<II", 0, 0))
    start = gfx(0x0B, struct.pack("<II", 0, 1))
    fill = gfx(0x04, u16le(1) + struct.pack("<BBBB", 1, 2, 3, 0) + u16le(1) + u16le(0) + u16le(0) + u16le(8) + u16le(8))
    wire1 = gfx(0x01, u16le(1) + u16le(0) + b"\x20" + u16le(0) + u16le(0) + u16le(2) + u16le(2)
                + struct.pack("<I", 16) + b"\x01" * 16)
    s2s = gfx(0x05, u16le(1) + u16le(1) + u16le(0) + u16le(0) + u16le(4) + u16le(4) + u16le(1) + u16le(10) + u16le(10))
    end = gfx(0x0C, struct.pack("<I", 1))
    write(corpus, "rdp_gfx", "frame", seg(caps_confirm) + seg(reset + create + map_out) + seg(start + fill + wire1 + s2s + end))
    multi = b"\xe1" + u16le(2) + struct.pack("<I", len(start + end)) + struct.pack("<I", 1 + len(start)) + b"\x04" + start \
        + struct.pack("<I", 1 + len(end)) + b"\x04" + end
    write(corpus, "rdp_gfx", "multipart", seg(caps_confirm + reset + create + map_out) + u16(len(multi)) + multi)

    # rdp_clipboard: a byte (shared from the start), then steps: what (0, 1 the server's message;
    # 2 the app's text; 3 sharing or a second), a 2-byte length (big-endian), the bytes.
    def clip(kind, flags, body=b""):
        return struct.pack("<HHI", kind, flags, len(body)) + body

    def step(what, body=b""):
        return bytes([what]) + u16(len(body)) + body

    def utf16z(text):
        return text.encode("utf-16-le") + bytes(2)

    caps = clip(7, 0, struct.pack("<HHHHII", 1, 0, 1, 12, 2, 2))
    ready = clip(1, 0)
    long_list = clip(2, 0, struct.pack("<I", 13) + bytes(2) + struct.pack("<I", 0xC0A1) + utf16z("HTML Format"))
    short_list = clip(2, 0, struct.pack("<I", 13) + bytes(32) + struct.pack("<I", 2) + bytes(32))
    answer = clip(5, 1, utf16z("from the remote" + chr(13) + chr(10) + "second line"))
    wants = clip(4, 0, struct.pack("<I", 13))
    write(corpus, "rdp_clipboard", "both_ways",
          bytes([1]) + step(0, caps) + step(0, ready) + step(0, long_list) + step(0, answer)
          + step(2, ("from this device" + chr(10) + "line").encode()) + step(0, wants) + step(0, clip(3, 1)))
    write(corpus, "rdp_clipboard", "short_names_off_then_on",
          bytes([0]) + step(0, ready) + step(0, short_list) + step(2, b"not shared") + step(0, wants)
          + step(3, bytes([1])) + step(0, answer) + step(3) + step(0, clip(8, 0, struct.pack("<II", 9, 0)))
          + step(3, bytes([0])) + step(0, clip(10, 0, struct.pack("<I", 1))))

    # mosh_datagram: steps of a mode byte, a 16-bit length (big-endian) and the bytes.
    def mstep(mode, body):
        return bytes([mode]) + struct.pack(">H", len(body)) + body

    def varint(v):
        out = b""
        while v >= 0x80:
            out += bytes([(v & 0x7F) | 0x80])
            v >>= 7
        return out + bytes([v])

    def pb(field, body):
        return varint(field << 3 | 2) + varint(len(body)) + body

    def host_bytes(text):
        return pb(1, pb(2, pb(4, text)))

    screen = host_bytes(b"\x1b[r\x1b[0m\x1b[H\x1b[2J$ ") + pb(1, pb(3, varint(5 << 3) + varint(80) + varint(6 << 3) + varint(24)))
    echo = pb(1, pb(7, varint(8 << 3) + varint(3)))
    instruction = (varint(1 << 3) + varint(2) + varint(2 << 3) + varint(0) + varint(3 << 3) + varint(1)
                   + varint(4 << 3) + varint(1) + varint(5 << 3) + varint(0) + pb(6, screen))
    write(corpus, "mosh_datagram", "screen_then_echo", mstep(2, screen) + mstep(0x42, echo) + mstep(2, host_bytes(b"ls")))
    write(corpus, "mosh_datagram", "instruction", mstep(1, instruction) + mstep(0x21, instruction))
    write(corpus, "mosh_datagram", "fragments",
          mstep(0, struct.pack(">QH", 7, 1) + b"tail") + mstep(0, struct.pack(">QH", 7, 0x8002) + b"x")
          + mstep(0, struct.pack(">QH", 8, 0x8000)))
    write(corpus, "mosh_datagram", "shutdown", mstep(2, screen) + mstep(0x0a, b""))

    gateway_seeds(corpus)


def gateway_seeds(corpus):
    """rdp_gateway: a gateway's whole side of a connection (after TLS), for the odd first byte; its
    head and frames for the parsers (even). The NTLM challenge is made here, with made-up names."""

    def le16(v):
        return struct.pack("<H", v)

    def le32(v):
        return struct.pack("<I", v)

    def utf16(t):
        return t.encode("utf-16-le")

    def av(i, v):
        return le16(i) + le16(len(v)) + v

    name = utf16("EXAMPLE")
    info = (av(2, name) + av(1, utf16("RDG1")) + av(4, utf16("example.test")) + av(3, utf16("rdg1.example.test"))
            + av(7, bytes(8)) + av(0, b""))
    start = 56
    challenge = (b"NTLMSSP\x00" + le32(2) + le16(len(name)) + le16(len(name)) + le32(start) + le32(0xE2898235)
                 + bytes(range(1, 9)) + bytes(8) + le16(len(info)) + le16(len(info)) + le32(start + len(name))
                 + bytes([10, 0, 0x61, 0x4A, 0, 0, 0, 15]) + name + info)
    offer = (b"HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: Negotiate\r\nWWW-Authenticate: NTLM\r\n"
             b"Content-Length: 0\r\n\r\n")
    challenged = (b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: NTLM " + base64.b64encode(challenge)
                  + b"\r\nContent-Length: 0\r\n\r\n")
    upgraded = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"

    def packet(ty, body):
        return le16(ty) + le16(0) + le32(8 + len(body)) + body

    def frame(payload):
        n = len(payload)
        head = bytes([0x82, n]) if n < 126 else bytes([0x82, 126]) + struct.pack(">H", n)
        return head + payload

    tunnel = (frame(packet(0x02, le32(0) + bytes([1, 0]) + le16(0) + le16(0)))
              + frame(packet(0x0D, b""))
              + frame(packet(0x05, le16(0) + le32(0) + le16(0x03) + le16(0) + le32(7) + le32(0x14)))
              + frame(packet(0x07, le32(0) + le16(0x02) + le16(0) + le32(30)))
              + frame(packet(0x09, le32(0) + le16(0x01) + le16(0) + le32(1)))
              + frame(packet(0x0A, le16(4) + b"\x03\x00\x00\x13"))
              + frame(packet(0x0B, le16(6) + utf16("hi") + le16(0)))
              + frame(packet(0x10, le32(0))))
    write(corpus, "rdp_gateway", "whole", b"\x01" + offer + challenged + upgraded + tunnel)
    write(corpus, "rdp_gateway", "whole_old_transport", b"\x01" + offer + challenged + b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    write(corpus, "rdp_gateway", "whole_refused", b"\x01" + offer + challenged + offer)
    write(corpus, "rdp_gateway", "whole_channel_refused",
          b"\x01" + offer + challenged + upgraded + tunnel[:tunnel.index(b"\x09\x00\x00\x00")]
          + frame(packet(0x09, le32(0x800759DA) + le16(0) + le16(0))))
    write(corpus, "rdp_gateway", "parsers", b"\x00" + challenged + tunnel)


def u16le(v):
    return struct.pack("<H", v)


if __name__ == "__main__":
    main()
