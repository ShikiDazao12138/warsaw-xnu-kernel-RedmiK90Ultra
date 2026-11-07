#!/usr/bin/env python3
"""
在 Windows 上装配 XNU 的 boot 镜像，不依赖 WSL。

mkxnuimg.py 要求 Mu-Silicium 源码树在场（它会在那里重编 BootShim），所以只能在 WSL 里跑。
BootShim 已经编好之后就没必要了：本脚本复用 mkxnuimg.py 自己的容器校验和 blob 规则
(build_blob)，再加上同样的 gzip + mkbootimg 步骤，产出与它有相同结构的镜像。

  kernel 段 = gzip(BootShim + UEFI FD + [XNUP 载荷]) + 设备树

用法：
  assemble-xnu-img.py --shim BootShim.bin --fd SILICIUM_UEFI.fd \
                      --payload payload.bin --dtb warsaw.dtb \
                      --mkbootimg mkbootimg.py --out Mu-warsaw-xnu.img
"""
import argparse
import gzip
import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def load_mkxnuimg():
    """导入仓库里的 mkxnuimg.py，只借用它的容器校验与 blob 拼装规则。"""
    path = os.environ.get('MKXNUIMG') or os.path.join(
        HERE, '..', '..', 'hackios', 'hackios-xnu-kernel', 'mkxnuimg.py')
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        sys.exit(f'找不到 mkxnuimg.py: {path}（用 MKXNUIMG 环境变量指定）')
    spec = importlib.util.spec_from_file_location('mkxnuimg', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shim', required=True, help='BootShim.bin（PAYLOAD_CAP 严格版为 368 字节）')
    ap.add_argument('--fd', required=True, help='SILICIUM_UEFI.fd')
    ap.add_argument('--payload', required=True, help='XNUP 容器；省略则装一个不带载荷的镜像')
    ap.add_argument('--dtb', required=True)
    ap.add_argument('--ramdisk', required=True, help='mkbootimg 需要的占位 ramdisk')
    ap.add_argument('--mkbootimg', required=True, help='Mu-Silicium 的 mkbootimg.py')
    ap.add_argument('--out', required=True)
    ap.add_argument('--cap', type=lambda s: int(s, 0), default=0x03700000,
                    help='PAYLOAD_CAP，必须与 BootShim 编译时的值一致（默认 0x03700000）')
    ap.add_argument('--keep-kernel', action='store_true', help='保留中间的 kernel 段文件')
    args = ap.parse_args()

    mk = load_mkxnuimg()

    shim = open(args.shim, 'rb').read()
    fd = open(args.fd, 'rb').read()
    dtb = open(args.dtb, 'rb').read()
    container = open(args.payload, 'rb').read() if args.payload else None

    if container is not None:
        n, length = mk.validate_container(container, args.cap)
        print(f'载荷: {len(container)} B  (body N={n:#x}, shim 复制 {length:#x})')
        if length > args.cap:
            sys.exit(f'载荷复制长度 {length:#x} 超过 PAYLOAD_CAP {args.cap:#x}')

    blob = mk.build_blob(shim, fd, container, args.cap)
    print(f'shim {len(shim)} B + FD {len(fd)} B + 载荷 {len(blob) - len(shim) - len(fd)} B '
          f'= {len(blob)} B（未压缩）')

    if container is not None:
        cmp_len = len(gzip.compress(blob, 6))
        print(f'gzip 后约 {cmp_len} B + DTB {len(dtb)} B')

    fd_tmp = tempfile.NamedTemporaryFile(suffix='.kernel~', delete=False)
    fd_tmp.close()
    try:
        with open(fd_tmp.name, 'wb') as f:
            f.write(gzip.compress(blob, 6) + dtb)
        cmd = [sys.executable, args.mkbootimg,
               '--kernel', fd_tmp.name,
               '--ramdisk', args.ramdisk,
               '--header_version', '1',
               '-o', args.out]
        subprocess.check_call(cmd)
    finally:
        if args.keep_kernel:
            print(f'kernel 段: {fd_tmp.name}')
        else:
            os.unlink(fd_tmp.name)

    print(f'{args.out}: {os.path.getsize(args.out)} B')


if __name__ == '__main__':
    main()
