"""``python -m localcanvas_gateway.workflows <registry root>`` -- offline validation."""

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
