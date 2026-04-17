#!/usr/bin/env python3
"""
inkbook.py — Convert PDF and EPUB files to InkBook format.

InkBook format:
  <BookTitle>.inkbook/
    info.json5          — book metadata + conversion settings
    page0001.jpg        — rendered pages, optimized for target resolution
    page0002.jpg
    ...

Usage:
  python inkbook.py convert <input.(pdf|epub)> [options]
  python inkbook.py info    <book.inkbook/>
  python inkbook.py resolutions

Options:
  -o, --output DIR        Output directory (default: <title>.inkbook)
  -r, --resolution NAME   Preset resolution name (default: 240x320)
  -W, --width  PX         Custom width
  -H, --height PX         Custom height
  -q, --quality  0-95     JPEG quality (default: 85)
  --grayscale             Convert pages to grayscale (better for e-ink)
  --dither                Apply Floyd-Steinberg dithering (grayscale only)
  --title TEXT            Override book title
  --author TEXT           Override book author
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Optional

# ── third-party ──────────────────────────────────────────────────────────────
try:
    import fitz  # PyMuPDF
except ImportError:
    sys.exit("Missing dependency: pip install pymupdf")

try:
    from PIL import Image, ImageFilter, ImageOps
except ImportError:
    sys.exit("Missing dependency: pip install Pillow")

try:
    import ebooklib
    from ebooklib import epub
except ImportError:
    sys.exit("Missing dependency: pip install ebooklib")

try:
    import json5
except ImportError:
    sys.exit("Missing dependency: pip install json5")

# ── preset resolutions ────────────────────────────────────────────────────────
RESOLUTIONS: dict[str, tuple[int, int]] = {
    # Classic e-ink presets
    "240x320":    (240, 320),   # Hanlin V3, old Jinke devices
    "320x240":    (320, 240),   # Same, landscape
    "480x320":    (480, 320),   # Hanlin V5 landscape
    "600x800":    (600, 800),   # Kindle (gen 1-2), PocketBook 301
    "758x1024":   (758, 1024),  # Kindle Paperwhite (gen 1-3)
    "1072x1448":  (1072, 1448), # Kindle Paperwhite 4 / Oasis 2-3
    "1264x1680":  (1264, 1680), # Kindle Scribe
    "825x1200":   (825, 1200),  # Kobo Clara / Libra
    "1080x1440":  (1080, 1440), # Kobo Sage / Elipsa
    # Generic
    "custom":     (0, 0),       # Placeholder; resolved from --width/--height
}

INKBOOK_VERSION = "1.0"
INKBOOK_EXT    = ".inkbook"


# ── helpers ───────────────────────────────────────────────────────────────────

def slugify(text: str) -> str:
    """Turn a title into a safe directory name."""
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    text = re.sub(r"[\s]+", "_", text.strip())
    return text[:80] or "book"


def fit_image(img: Image.Image, width: int, height: int) -> Image.Image:
    """
    Scale img to fit inside (width, height) while preserving aspect ratio,
    then centre it on a white canvas of exactly that size.
    """
    img.thumbnail((width, height), Image.LANCZOS)
    canvas = Image.new("RGB", (width, height), (255, 255, 255))
    x_off  = (width  - img.width)  // 2
    y_off  = (height - img.height) // 2
    canvas.paste(img if img.mode == "RGB" else img.convert("RGB"), (x_off, y_off))
    return canvas


def apply_eink_optimisation(img: Image.Image,
                             grayscale: bool,
                             dither: bool) -> Image.Image:
    if grayscale or dither:
        img = ImageOps.grayscale(img)
        if dither:
            # Floyd-Steinberg via Pillow's built-in palette conversion
            img = img.convert("P", dither=Image.FLOYDSTEINBERG,
                              palette=Image.ADAPTIVE, colors=16)
            img = img.convert("L")          # back to grayscale for JPEG
    return img if img.mode in ("RGB", "L") else img.convert("RGB")


def page_filename(n: int) -> str:
    return f"page{n:04d}.jpg"


# ── PDF conversion ─────────────────────────────────────────────────────────────

def convert_pdf(src: Path,
                out_dir: Path,
                width: int,
                height: int,
                quality: int,
                grayscale: bool,
                dither: bool,
                title_override: Optional[str],
                author_override: Optional[str]) -> dict:

    doc = fitz.open(str(src))
    meta = doc.metadata

    title  = title_override  or meta.get("title")  or src.stem
    author = author_override or meta.get("author") or "Unknown"
    subject   = meta.get("subject",  "")
    keywords  = meta.get("keywords", "")
    creator   = meta.get("creator",  "")
    page_count = doc.page_count

    # Render scale: we want pages at at least 2× the target to downsample nicely
    scale = max(2.0, width / 100)
    mat   = fitz.Matrix(scale, scale)

    print(f"  Source     : {src.name}")
    print(f"  Pages      : {page_count}")
    print(f"  Target     : {width}×{height}  quality={quality}")

    for i, page in enumerate(doc):
        pix  = page.get_pixmap(matrix=mat, alpha=False)
        img  = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
        img  = fit_image(img, width, height)
        img  = apply_eink_optimisation(img, grayscale, dither)
        dest = out_dir / page_filename(i + 1)
        img.save(str(dest), "JPEG", quality=quality, optimize=True,
                 progressive=False)
        print(f"  [{i+1:>4}/{page_count}] {dest.name}", end="\r", flush=True)

    print()  # newline after \r

    return {
        "title":     title,
        "author":    author,
        "subject":   subject,
        "keywords":  keywords,
        "creator":   creator,
        "source":    "pdf",
        "page_count": page_count,
    }


# ── EPUB conversion ────────────────────────────────────────────────────────────

def _epub_spine_images(book: epub.EpubBook) -> list[bytes]:
    """
    Extract renderable content from an EPUB.
    Strategy:
      1. Collect all image items (covers, illustrations).
      2. For text spine items, render via fitz (MuPDF can open EPUB
         natively when given as bytes — we re-open the original file).
    We take the simpler, more reliable path: render the whole EPUB
    as a PDF first via fitz, then pull pages from that.
    """
    # ebooklib is used only for metadata; fitz handles rendering.
    return []


def convert_epub(src: Path,
                 out_dir: Path,
                 width: int,
                 height: int,
                 quality: int,
                 grayscale: bool,
                 dither: bool,
                 title_override: Optional[str],
                 author_override: Optional[str]) -> dict:

    # --- metadata via ebooklib ---
    book = epub.read_epub(str(src), options={"ignore_ncx": True})

    def _dc(key: str) -> str:
        items = book.get_metadata("DC", key)
        if items:
            val = items[0]
            return (val[0] if isinstance(val, tuple) else val) or ""
        return ""

    title  = title_override  or _dc("title")  or src.stem
    author = author_override or _dc("creator") or "Unknown"
    subject  = _dc("subject")
    language = _dc("language")
    publisher= _dc("publisher")
    date     = _dc("date")

    # --- rendering via fitz (MuPDF supports EPUB natively) ---
    doc = fitz.open(str(src))
    page_count = doc.page_count

    scale = max(2.0, width / 100)
    mat   = fitz.Matrix(scale, scale)

    print(f"  Source     : {src.name}")
    print(f"  Pages      : {page_count}")
    print(f"  Target     : {width}×{height}  quality={quality}")

    for i, page in enumerate(doc):
        pix = page.get_pixmap(matrix=mat, alpha=False)
        img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
        img = fit_image(img, width, height)
        img = apply_eink_optimisation(img, grayscale, dither)
        dest = out_dir / page_filename(i + 1)
        img.save(str(dest), "JPEG", quality=quality, optimize=True,
                 progressive=False)
        print(f"  [{i+1:>4}/{page_count}] {dest.name}", end="\r", flush=True)

    print()

    return {
        "title":      title,
        "author":     author,
        "subject":    subject,
        "language":   language,
        "publisher":  publisher,
        "date":       date,
        "source":     "epub",
        "page_count": page_count,
    }


# ── info.json5 ────────────────────────────────────────────────────────────────

def write_info(out_dir: Path,
               book_meta: dict,
               width: int,
               height: int,
               quality: int,
               grayscale: bool,
               dither: bool,
               resolution_name: str) -> None:

    info = {
        "inkbook_version": INKBOOK_VERSION,
        "title":       book_meta.get("title",     ""),
        "author":      book_meta.get("author",    ""),
        "subject":     book_meta.get("subject",   ""),
        "keywords":    book_meta.get("keywords",  ""),
        "language":    book_meta.get("language",  ""),
        "publisher":   book_meta.get("publisher", ""),
        "date":        book_meta.get("date",       ""),
        "creator":     book_meta.get("creator",   ""),
        "source_format": book_meta.get("source",  ""),
        "page_count":  book_meta.get("page_count", 0),
        "conversion": {
            "resolution_name": resolution_name,
            "width":   width,
            "height":  height,
            "quality": quality,
            "grayscale": grayscale,
            "dither":    dither,
        },
        "pages": [page_filename(n + 1) for n in range(book_meta.get("page_count", 0))],
    }

    # Write as JSON5 with comments
    lines = [
        "// InkBook metadata — generated by inkbook.py",
        "// Edit freely; this file is read back by `inkbook.py info`",
        "{",
    ]
    for k, v in info.items():
        if k == "conversion":
            lines.append(f"  {k}: {{")
            for ck, cv in v.items():
                lines.append(f"    {ck}: {json.dumps(cv)},")
            lines.append("  },")
        elif k == "pages":
            lines.append(f"  // page list ({len(v)} items)")
            lines.append(f"  {k}: {json.dumps(v)},")
        else:
            lines.append(f"  {k}: {json.dumps(v)},")
    lines.append("}")

    (out_dir / "info.json5").write_text("\n".join(lines), encoding="utf-8")


# ── CLI commands ──────────────────────────────────────────────────────────────

def cmd_resolutions(_args) -> None:
    print("Built-in resolution presets:")
    print(f"  {'Name':<16}  {'Width':>6}  {'Height':>7}")
    print("  " + "-" * 34)
    for name, (w, h) in RESOLUTIONS.items():
        if name == "custom":
            continue
        print(f"  {name:<16}  {w:>6}  {h:>7}")
    print()
    print("Use --resolution custom --width W --height H for any other size.")


def cmd_info(args) -> None:
    path = Path(args.book)
    info_file = path / "info.json5" if path.is_dir() else path
    if not info_file.exists():
        sys.exit(f"Cannot find info.json5 at: {info_file}")

    info = json5.loads(info_file.read_text(encoding="utf-8"))
    conv = info.get("conversion", {})

    print(f"  Title      : {info.get('title',  '—')}")
    print(f"  Author     : {info.get('author', '—')}")
    if info.get("subject"):
        print(f"  Subject    : {info['subject']}")
    if info.get("publisher"):
        print(f"  Publisher  : {info['publisher']}")
    if info.get("date"):
        print(f"  Date       : {info['date']}")
    if info.get("language"):
        print(f"  Language   : {info['language']}")
    print(f"  Source fmt : {info.get('source_format', '—')}")
    print(f"  Pages      : {info.get('page_count', '—')}")
    print(f"  Resolution : {conv.get('width')}×{conv.get('height')}  "
          f"({conv.get('resolution_name', 'custom')})")
    print(f"  JPEG quality: {conv.get('quality')}")
    print(f"  Grayscale  : {conv.get('grayscale')}")
    print(f"  Dither     : {conv.get('dither')}")
    print(f"  InkBook ver: {info.get('inkbook_version', '—')}")


def cmd_convert(args) -> None:
    src = Path(args.input)
    if not src.exists():
        sys.exit(f"Input file not found: {src}")

    suffix = src.suffix.lower()
    if suffix not in (".pdf", ".epub"):
        sys.exit(f"Unsupported format '{suffix}'. Only .pdf and .epub are supported.")

    # Resolve resolution
    res_name = args.resolution.lower()
    if res_name == "custom":
        if not args.width or not args.height:
            sys.exit("--resolution custom requires --width and --height.")
        width, height = int(args.width), int(args.height)
    elif res_name in RESOLUTIONS:
        width, height = RESOLUTIONS[res_name]
    else:
        sys.exit(f"Unknown resolution '{res_name}'. Run `inkbook.py resolutions` to list presets.")

    quality  = max(1, min(95, int(args.quality)))
    grayscale = args.grayscale
    dither    = args.dither

    # Output directory
    if args.output:
        out_dir = Path(args.output)
    else:
        out_dir = src.parent / (slugify(src.stem) + INKBOOK_EXT)

    if out_dir.exists() and not args.force:
        sys.exit(f"Output already exists: {out_dir}\nUse --force to overwrite.")

    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n── InkBook converter ─────────────────────────────")
    print(f"  Converting : {src.name}  →  {out_dir.name}")

    if suffix == ".pdf":
        meta = convert_pdf(
            src, out_dir, width, height, quality,
            grayscale, dither,
            args.title, args.author,
        )
    else:
        meta = convert_epub(
            src, out_dir, width, height, quality,
            grayscale, dither,
            args.title, args.author,
        )

    write_info(out_dir, meta, width, height, quality,
               grayscale, dither, res_name)

    total = sum(
        (out_dir / page_filename(n + 1)).stat().st_size
        for n in range(meta["page_count"])
    )
    print(f"\n  ✓ Done — {meta['page_count']} pages, "
          f"{total / 1024:.1f} KB total images")
    print(f"  Output     : {out_dir}/\n")


# ── entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="inkbook",
        description="Convert PDF/EPUB → InkBook format (folder + info.json5 + JPEG pages)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # ── convert ──
    p_conv = sub.add_parser("convert", help="Convert a PDF or EPUB to InkBook")
    p_conv.add_argument("input",   help="Input file (.pdf or .epub)")
    p_conv.add_argument("-o", "--output",     help="Output .inkbook directory")
    p_conv.add_argument("-r", "--resolution", default="240x320",
                        help="Preset name (default: 240x320). Run 'resolutions' to list.")
    p_conv.add_argument("-W", "--width",  type=int, help="Custom width in pixels")
    p_conv.add_argument("-H", "--height", type=int, help="Custom height in pixels")
    p_conv.add_argument("-q", "--quality", type=int, default=85,
                        help="JPEG quality 1-95 (default: 85)")
    p_conv.add_argument("--grayscale",  action="store_true",
                        help="Convert to grayscale (recommended for e-ink)")
    p_conv.add_argument("--dither",     action="store_true",
                        help="Apply Floyd-Steinberg dithering (implies --grayscale)")
    p_conv.add_argument("--title",  help="Override book title")
    p_conv.add_argument("--author", help="Override book author")
    p_conv.add_argument("--force",  action="store_true",
                        help="Overwrite existing output directory")
    p_conv.set_defaults(func=cmd_convert)

    # ── info ──
    p_info = sub.add_parser("info", help="Display metadata from an InkBook")
    p_info.add_argument("book", help=".inkbook directory or its info.json5")
    p_info.set_defaults(func=cmd_info)

    # ── resolutions ──
    p_res = sub.add_parser("resolutions", help="List built-in resolution presets")
    p_res.set_defaults(func=cmd_resolutions)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
