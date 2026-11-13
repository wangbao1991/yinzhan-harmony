#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
去掉音栈图标右下角「豆包 AI 生成」水印，输出 1024x1024 app_icon PNG。

用法：
    python3 scripts/icon/remove_watermark.py <源图.jpg> <输出.png>

原理（详见 docs/应用图标说明.md）：
水印所在区域是纯平滑渐变背景。用局部高频差检出文字笔画，再用文字区
之外的真实背景像素拟合二维二次曲面，用曲面预测值替换文字像素。
矩形外与文字外的像素 100% 保留，因此无残影、无 inpaint 噪点、无接缝。

坐标按 1600x1600 基准等比换算，换一批同构图源图也能直接用。
依赖：opencv-python、numpy、Pillow
"""
import sys
import cv2
import numpy as np
from PIL import Image

BASE = 1600          # 水印坐标标定所用的基准边长
X0_BASE, Y0_BASE = 1280, 1480
OUT_SIZE = 1024
DIFF_TH = 12        # 局部高频差阈值，用于判定文字像素
BLUR_SIGMA = 16


def remove(src_path: str, dst_path: str) -> None:
    bgr = cv2.imread(src_path, cv2.IMREAD_COLOR)
    if bgr is None:
        raise RuntimeError('读取失败: ' + src_path)
    h, w = bgr.shape[:2]
    x0 = int(w * X0_BASE / BASE)
    y0 = int(h * Y0_BASE / BASE)
    roi = bgr[y0:h, x0:w]

    # 1) 检出文字：|原图 - 大核高斯背景| 超阈值处即笔画/描边/抗锯齿
    roif = roi.astype(np.int16)
    bg = cv2.GaussianBlur(roi, (0, 0), BLUR_SIGMA).astype(np.int16)
    diff = np.abs(roif - bg).max(axis=2)
    m = (diff > DIFF_TH).astype(np.uint8) * 255
    e5 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    e7 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    fill = cv2.dilate(cv2.dilate(m, e5), e7)

    # 2) 用真实背景像素拟合二维二次曲面 c = f(u,v)
    rh, rw = roi.shape[:2]
    uu, vv = np.meshgrid(np.linspace(0, 1, rw), np.linspace(0, 1, rh))
    U, V = uu.ravel(), vv.ravel()
    basis = np.stack([np.ones_like(U), U, V, U * U, U * V, V * V], axis=1)
    idx = np.where(fill.ravel() == 0)[0]
    sample = idx[::max(1, len(idx) // 8000)]
    coef, *_ = np.linalg.lstsq(basis[sample], roi.reshape(-1, 3)[sample].astype(np.float64), rcond=None)
    pred = np.clip(basis @ coef, 0, 255).reshape(rh, rw, 3).astype(np.uint8)

    # 3) 只替换文字区，其余像素原样保留
    out = roi.copy()
    out[fill > 0] = pred[fill > 0]
    full = bgr.copy()
    full[y0:h, x0:w] = out

    rgb = cv2.cvtColor(full, cv2.COLOR_BGR2RGB)
    Image.fromarray(rgb).resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS) \
        .convert('RGBA').save(dst_path, 'PNG', optimize=True)
    print(f'{src_path} -> {dst_path}  ({w}x{h} -> {OUT_SIZE}x{OUT_SIZE})')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    remove(sys.argv[1], sys.argv[2])
