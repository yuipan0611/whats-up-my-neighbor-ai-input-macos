#!/usr/bin/env python3
"""
fake-rfb-server.py - RFB 3.8 loopback server for testing screen sharing handoff.
Implements RFC 6143 subset for local verification without a real VNC server.
"""

import argparse
import datetime
import os
import select
import socket
import struct
import sys
import time


def parse_args():
    parser = argparse.ArgumentParser(description="Fake RFB 3.8 server for loopback check")
    parser.add_argument("--port", type=int, default=5901, help="Port to listen on (default: 5901)")
    parser.add_argument("--log", type=str, required=True, help="Path to log file")
    parser.add_argument("--timeout", type=float, default=60.0, help="Overall timeout in seconds (default: 60)")
    parser.add_argument("--security", choices=["none", "vncauth"], default="none", help="Security type (default: none)")
    return parser.parse_args()


class Logger:
    def __init__(self, path):
        log_dir = os.path.dirname(os.path.abspath(path))
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
        self.file = open(path, "a", encoding="utf-8")

    def log(self, message):
        now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{now_str}] {message}\n"
        self.file.write(line)
        self.file.flush()

    def close(self):
        try:
            self.file.close()
        except Exception:
            pass


def recv_exact(sock, n, deadline):
    buf = bytearray()
    while len(buf) < n:
        remaining_time = deadline - time.time()
        if remaining_time <= 0:
            raise TimeoutError("Timed out waiting for data from client")
        sock.settimeout(max(0.1, min(remaining_time, 5.0)))
        try:
            chunk = sock.recv(n - len(buf))
        except socket.timeout:
            continue
        if not chunk:
            if len(buf) == 0:
                return None
            raise ConnectionResetError(f"Connection closed after receiving {len(buf)} of {n} bytes")
        buf.extend(chunk)
    return bytes(buf)


def render_frame_pixels(w, h, pf):
    bpp = pf["bpp"]
    depth = pf["depth"]
    big_endian = pf["big_endian"]
    red_max = pf["red_max"]
    green_max = pf["green_max"]
    blue_max = pf["blue_max"]
    red_shift = pf["red_shift"]
    green_shift = pf["green_shift"]
    blue_shift = pf["blue_shift"]

    def encode_color(r, g, b):
        sr = int((r / 255.0) * red_max) & red_max
        sg = int((g / 255.0) * green_max) & green_max
        sb = int((b / 255.0) * blue_max) & blue_max
        val = (sr << red_shift) | (sg << green_shift) | (sb << blue_shift)
        if bpp == 8:
            return struct.pack("B", val & 0xFF)
        elif bpp == 16:
            fmt = ">H" if big_endian else "<H"
            return struct.pack(fmt, val & 0xFFFF)
        elif bpp == 32:
            fmt = ">I" if big_endian else "<I"
            return struct.pack(fmt, val & 0xFFFFFFFF)
        else:
            fmt = ">I" if big_endian else "<I"
            return struct.pack(fmt, val & 0xFFFFFFFF)

    green_pixel = encode_color(0, 128, 0)
    gray_pixel = encode_color(211, 211, 211)

    half_h = h // 2
    top_pixels = (green_pixel * w) * half_h
    bottom_pixels = (gray_pixel * w) * (h - half_h)
    return top_pixels + bottom_pixels


def handle_client(conn, addr, args, logger, deadline, stats=None):
    pixel_format = {
        "bpp": 32,
        "depth": 24,
        "big_endian": 0,
        "true_colour": 1,
        "red_max": 255,
        "green_max": 255,
        "blue_max": 255,
        "red_shift": 16,
        "green_shift": 8,
        "blue_shift": 0,
    }

    server_banner = b"RFB 003.008\n"
    conn.sendall(server_banner)
    logger.log("server version sent: RFB 003.008")

    client_version_bytes = recv_exact(conn, 12, deadline)
    if client_version_bytes is None:
        logger.log("probe connection disconnected without sending version (banner probe verified)")
        return "probe_done"

    client_version_str = client_version_bytes.decode("ascii", errors="replace").strip()
    logger.log(f"client version: {client_version_str}")

    if "003.003" in client_version_str:
        proto = "3.3"
    elif "003.007" in client_version_str:
        proto = "3.7"
    else:
        proto = "3.8"
    logger.log(f"protocol: {proto}")

    if proto == "3.3":
        selected_sec = 1 if args.security == "none" else 2
        conn.sendall(struct.pack(">I", selected_sec))
        logger.log(f"security type chosen by server: {selected_sec}")
    else:
        if args.security == "none":
            conn.sendall(bytes([1, 1]))
            logger.log("security types sent: [1] (None)")
        else:
            conn.sendall(bytes([1, 2]))
            logger.log("security types sent: [2] (VNCAuth)")

        selected_sec_bytes = recv_exact(conn, 1, deadline)
        if not selected_sec_bytes:
            raise ConnectionResetError("Client disconnected while selecting security type")
        selected_sec = selected_sec_bytes[0]
        logger.log(f"client selected security type: {selected_sec}")

    if selected_sec == 2:
        challenge = os.urandom(16)
        conn.sendall(challenge)
        logger.log("sent 16-byte random challenge")
        response = recv_exact(conn, 16, deadline)
        if not response:
            raise ConnectionResetError("Client disconnected during challenge-response")
        logger.log("challenge response received")

    if proto == "3.8" or selected_sec == 2:
        conn.sendall(struct.pack(">I", 0))
        logger.log("SecurityResult sent: 0")

    client_init = recv_exact(conn, 1, deadline)
    if not client_init:
        raise ConnectionResetError("Client disconnected on ClientInit")
    shared_flag = client_init[0]
    logger.log(f"ClientInit received: shared={shared_flag}")

    server_name = b"neighbor loopback check"
    raw_pf = struct.pack(
        ">BBBBHHHBBB3s",
        32, 24, 0, 1,
        255, 255, 255,
        16, 8, 0,
        b"\x00\x00\x00"
    )
    server_init = struct.pack(">HH", 640, 400) + raw_pf + struct.pack(">I", len(server_name)) + server_name
    conn.sendall(server_init)
    logger.log(f"ServerInit sent: 640x400 name='{server_name.decode()}'")

    frame_count = 0
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            logger.log("overall timeout reached during message loop")
            break

        msg_type_bytes = recv_exact(conn, 1, deadline)
        if msg_type_bytes is None:
            logger.log("client disconnected")
            return "client_done"

        msg_type = msg_type_bytes[0]

        if msg_type == 0:
            raw = recv_exact(conn, 3 + 16, deadline)
            if not raw:
                logger.log("client disconnected during SetPixelFormat")
                return "client_done"
            pf_data = raw[3:]
            bpp, depth, be, tc, r_max, g_max, b_max, r_sh, g_sh, b_sh, _ = struct.unpack(">BBBBHHHBBB3s", pf_data)
            pixel_format = {
                "bpp": bpp,
                "depth": depth,
                "big_endian": be,
                "true_colour": tc,
                "red_max": r_max,
                "green_max": g_max,
                "blue_max": b_max,
                "red_shift": r_sh,
                "green_shift": g_sh,
                "blue_shift": b_sh,
            }
            logger.log(
                f"SetPixelFormat received: bpp={bpp}, depth={depth}, big_endian={be}, true_colour={tc}, "
                f"red_max={r_max}, green_max={g_max}, blue_max={b_max}, "
                f"red_shift={r_sh}, green_shift={g_sh}, blue_shift={b_sh}"
            )

        elif msg_type == 2:
            hdr = recv_exact(conn, 3, deadline)
            if not hdr:
                logger.log("client disconnected during SetEncodings header")
                return "client_done"
            count = struct.unpack(">xH", hdr)[0]
            enc_data = recv_exact(conn, count * 4, deadline) if count > 0 else b""
            encodings = [struct.unpack(">i", enc_data[i*4:(i+1)*4])[0] for i in range(count)]
            logger.log(f"SetEncodings received: count={count}, encodings={encodings}")

        elif msg_type == 3:
            req_data = recv_exact(conn, 9, deadline)
            if not req_data:
                logger.log("client disconnected during FramebufferUpdateRequest")
                return "client_done"
            incremental, x, y, w, h = struct.unpack(">BHHHH", req_data)
            logger.log(f"FramebufferUpdateRequest received: incremental={incremental}, x={x}, y={y}, w={w}, h={h}")

            if incremental == 1:
                time.sleep(0.5)

            pixels = render_frame_pixels(640, 400, pixel_format)
            fb_header = struct.pack(">BBH", 0, 0, 1)
            rect_header = struct.pack(">HHHHi", 0, 0, 640, 400, 0)
            conn.sendall(fb_header + rect_header + pixels)
            frame_count += 1
            if stats is not None:
                stats["frames_sent"] = frame_count
            logger.log(f"frame {frame_count} sent")

        elif msg_type == 4:
            key_data = recv_exact(conn, 7, deadline)
            if not key_data:
                logger.log("client disconnected during KeyEvent")
                return "client_done"
            down_flag, key = struct.unpack(">B2xI", key_data)
            logger.log(f"KeyEvent received: down={down_flag}, key={hex(key)}")

        elif msg_type == 5:
            ptr_data = recv_exact(conn, 5, deadline)
            if not ptr_data:
                logger.log("client disconnected during PointerEvent")
                return "client_done"
            btn_mask, px, py = struct.unpack(">BHH", ptr_data)
            logger.log(f"PointerEvent received: mask={btn_mask}, x={px}, y={py}")

        elif msg_type == 6:
            cut_hdr = recv_exact(conn, 7, deadline)
            if not cut_hdr:
                logger.log("client disconnected during ClientCutText header")
                return "client_done"
            length = struct.unpack(">3xI", cut_hdr)[0]
            text_data = recv_exact(conn, length, deadline) if length > 0 else b""
            logger.log(f"ClientCutText received: length={length}")

        else:
            logger.log(f"unknown message type {msg_type}")
            conn.close()
            return "client_done"

    return "client_done"


def main():
    args = parse_args()
    logger = Logger(args.log)
    deadline = time.time() + args.timeout

    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    try:
        server_sock.bind(("127.0.0.1", args.port))
        server_sock.listen(1)
        logger.log(f"fake-rfb-server listening on 127.0.0.1:{args.port} (security={args.security}, timeout={args.timeout}s)")
    except Exception as e:
        logger.log(f"bind failed: {e}")
        server_sock.close()
        logger.close()
        sys.exit(2)

    try:
        while time.time() < deadline:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            server_sock.settimeout(max(0.1, min(remaining, 1.0)))
            try:
                conn, addr = server_sock.accept()
            except socket.timeout:
                continue

            logger.log(f"connection accepted from {addr[0]}:{addr[1]}")
            stats = {"frames_sent": 0}
            try:
                res = handle_client(conn, addr, args, logger, deadline, stats)
                conn.close()
                if res == "client_done":
                    logger.log("server exiting normally (client session ended)")
                    server_sock.close()
                    logger.close()
                    sys.exit(0)
                elif res == "probe_done":
                    continue
            except (ConnectionResetError, BrokenPipeError):
                try:
                    conn.close()
                except Exception:
                    pass
                if stats["frames_sent"] > 0:
                    logger.log("client disconnected")
                    server_sock.close()
                    logger.close()
                    sys.exit(0)
                else:
                    logger.log("client disconnected before any frame; still listening")
                    continue
            except Exception as e:
                logger.log(f"error handling client: {e}")
                try:
                    conn.close()
                except Exception:
                    pass
                server_sock.close()
                logger.close()
                sys.exit(2)

        logger.log("server timeout reached without completing session")
        server_sock.close()
        logger.close()
        sys.exit(0)

    except Exception as e:
        logger.log(f"unexpected exception: {e}")
        server_sock.close()
        logger.close()
        sys.exit(2)


if __name__ == "__main__":
    main()
