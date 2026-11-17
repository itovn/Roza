#!/usr/bin/env python3
"""In danh sách «<đường dẫn thư viện> <ký hiệu>» mà một tệp Mach-O cần (từ `nm -m` + `otool -L` của toolchain Theos),
làm đầu vào cho cbsymcheck chạy trên máy iOS 6.
    python3 tools/symlist.py <tệp Mach-O> | ssh root@<máy> cbsymcheck
"""
import os
import re
import subprocess
import sys

BIN = os.path.expanduser("~/theos/toolchain/linux/iphone/bin")


def short_name(path):
    # Cách ld đặt «tên ngắn» trong `nm -m`: libSystem.B.dylib → libSystem, Foundation.framework/Foundation → Foundation
    base = os.path.basename(path)
    base = re.sub(r"\.dylib$", "", base)
    return re.sub(r"\.[A-Z]$", "", base)


def main():
    target = sys.argv[1]
    libs = {}
    for line in subprocess.run([BIN + "/otool", "-L", target], capture_output=True, text=True).stdout.splitlines()[1:]:
        path = line.strip().split(" (")[0]
        libs[short_name(path)] = path
    for line in subprocess.run([BIN + "/nm", "-m", target], capture_output=True, text=True).stdout.splitlines():
        m = re.search(r"\(undefined\) (?:weak )?external (\S+) \(from (\S+)\)", line)
        if not m:
            continue
        sym, lib = m.groups()
        if sym == "dyld_stub_binder":
            continue
        print(libs.get(lib, lib), sym)


if __name__ == "__main__":
    main()
