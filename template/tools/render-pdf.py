#!/usr/bin/env python3
"""Render an HTML documentation file to PDF using WeasyPrint.

Replaces `electron-pdf --marginsType 0 --input X --output Y`.

Usage: render-pdf.py <input.html> <output.pdf>

WeasyPrint is a CSS Paged Media engine (no browser/Chromium). Page size and
margins come from the @page rule in the HTML; page-break markers in the source
(`<div style="page-break-after: always"></div>`) are honored natively. Relative
asset paths (images, etc.) resolve against the input file's directory.
"""

import sys
from pathlib import Path

from weasyprint import HTML


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: render-pdf.py <input.html> <output.pdf>", file=sys.stderr)
        return 1

    input_path = Path(sys.argv[1]).resolve()
    output_path = Path(sys.argv[2]).resolve()

    HTML(filename=str(input_path)).write_pdf(str(output_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
