#!/usr/bin/env python3.11
"""Convert Traditional Chinese to Simplified Chinese. Pass text as argument."""
import sys
try:
    from opencc import OpenCC
    cc = OpenCC('t2s')
    print(cc.convert(sys.argv[1]) if len(sys.argv) > 1 else '')
except ImportError:
    # If opencc not installed, pass through
    print(sys.argv[1] if len(sys.argv) > 1 else '')
