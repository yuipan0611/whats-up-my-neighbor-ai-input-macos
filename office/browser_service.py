#!/usr/bin/env python3
"""Isolated-mode entrypoint: python -I /trusted/release/browser_service.py ..."""
import importlib.util
from pathlib import Path
import sys

root = Path(__file__).resolve().parent / 'browser_workspace'
spec = importlib.util.spec_from_file_location(
    'browser_workspace', root / '__init__.py', submodule_search_locations=[str(root)])
module = importlib.util.module_from_spec(spec)
sys.modules['browser_workspace'] = module
spec.loader.exec_module(module)
from browser_workspace.service import main

if __name__ == '__main__':
    raise SystemExit(main())
