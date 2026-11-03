"""Regression tests for Aimili stdout on minimal Debian images with Latin-1 encoding."""
import ast
import io
from pathlib import Path
import sys
import tempfile
from typing import Any

source = Path("aimili/vpngate_manager.py").read_text(encoding="utf-8")
module = ast.parse(source)
tee_class = next(node for node in module.body if isinstance(node, ast.ClassDef) and node.name == "Tee")
namespace = {"Path": Path, "sys": sys, "Any": Any}
exec(compile(ast.Module(body=[tee_class], type_ignores=[]), "aimili/vpngate_manager.py", "exec"), namespace)
Tee = namespace["Tee"]

sample = "[网关] 正在启动代理网关...\n"

# The actual failure: Python sys.stdout has encoding latin-1 under systemd.
with tempfile.TemporaryDirectory() as tmp:
    old = sys.stdout
    sink = io.BytesIO()
    legacy_stdout = io.TextIOWrapper(sink, encoding="latin-1")
    try:
        sys.stdout = legacy_stdout
        tee = Tee(str(Path(tmp) / "vpngate.log"))
        tee.write(sample)
        tee.flush()
        assert sink.getvalue().decode("utf-8") == sample
        assert (Path(tmp) / "vpngate.log").read_text(encoding="utf-8") == sample
        tee.file.close()
    finally:
        sys.stdout = old

# Some stdout proxies cannot be reconfigured. Escape safely in the journal.
class Latin1WithoutReconfigure:
    encoding = "latin-1"
    def __init__(self):
        self.values = []
    def write(self, value):
        value.encode("latin-1")
        self.values.append(value)
    def flush(self):
        pass
    def isatty(self):
        return False

with tempfile.TemporaryDirectory() as tmp:
    old = sys.stdout
    sink = Latin1WithoutReconfigure()
    try:
        sys.stdout = sink
        tee = Tee(str(Path(tmp) / "vpngate.log"))
        tee.write(sample)
        tee.flush()
        assert "\\u7f51" in "".join(sink.values)
        assert (Path(tmp) / "vpngate.log").read_text(encoding="utf-8") == sample
        tee.file.close()
    finally:
        sys.stdout = old

print("Aimili UTF-8/Latin-1 logger tests passed")
