#!/usr/bin/env python3
"""仅收集测试设备的公开硬件/内核参数；不收集唯一标识或账户内容。"""

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--serial", required=True, help="仅用于选择 ADB 目标，不写入报告")
parser.add_argument("--output", required=True, type=pathlib.Path)
parser.add_argument("--adb", default="adb")
args = parser.parse_args()


def shell(*command):
    return subprocess.check_output(
        [args.adb, "-s", args.serial, "shell", *command], text=True, timeout=20
    ).strip()


properties = {
    "manufacturer": "ro.product.manufacturer",
    "model": "ro.product.model",
    "device": "ro.product.device",
    "abi": "ro.product.cpu.abi",
    "abis": "ro.product.cpu.abilist",
    "androidRelease": "ro.build.version.release",
    "apiLevel": "ro.build.version.sdk",
    "securityPatch": "ro.build.version.security_patch",
    "emui": "ro.build.version.emui",
}
result = {
    "capturedAtUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "properties": {name: shell("getprop", prop) for name, prop in properties.items()},
    "screen": {"size": shell("wm", "size"), "density": shell("wm", "density")},
    "webviewUpdateService": shell("dumpsys", "webviewupdate"),
    "privacy": "ADB serial is used for selection only and is omitted from this report.",
}
match = re.search(
    r"Current WebView package \(name, version\): \(([^,]+), ([^)]+)\)",
    result["webviewUpdateService"],
)
if match:
    result["webview"] = {"package": match.group(1), "versionName": match.group(2)}
args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open("w") as file:
    os.chmod(args.output, 0o600)
    json.dump(result, file, ensure_ascii=False, indent=2)
    file.write("\n")
print(args.output)
