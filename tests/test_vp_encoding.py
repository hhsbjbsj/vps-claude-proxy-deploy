"""Regression test: VP must render Chinese menus with Latin-1 inherited from SSH."""
import os
from pathlib import Path
import subprocess
import sys

code = r"""
import importlib.util
import sys

spec = importlib.util.spec_from_file_location('vp_manager', 'vp_manager.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print('管理面板正常显示中文：严格住宅出口')
print('错误信息正常显示中文', file=sys.stderr)
assert sys.stdout.encoding.lower() == 'utf-8'
assert sys.stderr.encoding.lower() == 'utf-8'
"""
env = dict(os.environ)
env["PYTHONIOENCODING"] = "latin-1:strict"
env["LANG"] = "C"
env["LC_ALL"] = "C"
run = subprocess.run(
    [sys.executable, "-c", code],
    env=env, capture_output=True, check=True,
)
assert "管理面板正常显示中文" in run.stdout.decode("utf-8")
assert "错误信息正常显示中文" in run.stderr.decode("utf-8")

installer = Path("install_manager.sh").read_text(encoding="utf-8")
assert "export PYTHONIOENCODING=utf-8:backslashreplace" in installer

print("VP UTF-8 stdout/stderr regression test passed")
