#!/usr/bin/env python3
"""Convert a raw floppy/hard disk .img file to a Luau hex string module (like BootOSHex.luau)."""
import sys
import os

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 img_to_luau.py <path/to/image.img> [output.luau]")
        sys.exit(1)

    img_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.exists(img_path):
        print(f"Error: {img_path} not found")
        sys.exit(1)

    with open(img_path, 'rb') as f:
        data = f.read()

    if not out_path:
        base = os.path.splitext(os.path.basename(img_path))[0]
        out_path = base + ".luau"

    name = os.path.splitext(os.path.basename(img_path))[0]
    size = len(data)

    print(f"Converting {img_path} ({size} bytes) -> {out_path}")

    with open(out_path, 'w') as out:
        out.write(f"-- Auto-generated from {os.path.basename(img_path)}\n")
        out.write(f"-- Size: {size} bytes ({size // 1024} KB)\n")
        out.write(f"-- Do not edit manually. Re-run img_to_luau.py to regenerate.\n\n")
        out.write("return {\n")

        bytes_per_line = 16
        for i in range(0, size, bytes_per_line):
            chunk = data[i:i+bytes_per_line]
            hex_bytes = ", ".join(f"0x{b:02X}" for b in chunk)
            out.write(f"\t{hex_bytes},\n")

        out.write("}\n")

    print(f"Done: {out_path}")
    
    # Report file size
    out_size = os.path.getsize(out_path)
    print(f"Output: {out_size:,} bytes ({out_size // 1024} KB, {out_size // 1024 // 1024} MB)")

if __name__ == "__main__":
    main()
