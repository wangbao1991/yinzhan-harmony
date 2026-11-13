#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从桌面图标生成「启动窗口专用图」：640x640，径向 alpha 柔和淡出。

为什么需要单独一张（详见 docs/应用图标说明.md）：
桌面图标是带方形渐变背景的完整图，系统启动窗口没有圆角蒙版，会把
它当成一张方形贴图贴在纯色底上，形成突兀的「色块 + 四周留白」。
把整张图按半径渐隐到透明、再让窗口底色取图标背景色，方形边界就消失了，
玻璃主体像浮在纯色背景上，发光也保留。

用法（在工程根目录执行）：
    python3 scripts/icon/make_start_window.py

输入：base/dark 的 app_icon.png（已去水印）
输出：base/dark 的 start_window_icon.png
依赖：opencv-python、numpy、Pillow
"""
import os
import cv2
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
RES = os.path.join(ROOT, 'entry', 'src', 'main', 'resources')
SIZE = 640
INNER = 0.55      # 该半径内完全不透明
OUTER = 0.98      # 该半径外完全透明


def make(src: str, dst: str) -> None:
    bgr = cv2.resize(cv2.imread(src, cv2.IMREAD_COLOR), (SIZE, SIZE), interpolation=cv2.INTER_AREA)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE]
    r = np.hypot(xx - SIZE / 2, yy - SIZE / 2) / (SIZE / 2)
    t = np.clip((r - INNER) / (OUTER - INNER), 0, 1)
    alpha = np.where(r >= OUTER, 0, (np.cos(t * np.pi) + 1) / 2 * 255).astype(np.uint8)
    rgba = np.dstack([cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB), alpha])
    Image.fromarray(rgba, 'RGBA').save(dst, 'PNG', optimize=True)
    print(src.replace(ROOT + '/', '') + ' -> ' + dst.replace(ROOT + '/', ''))


if __name__ == '__main__':
    for qualifier in ('base', 'dark'):
        d = os.path.join(RES, qualifier, 'media')
        make(os.path.join(d, 'app_icon.png'), os.path.join(d, 'start_window_icon.png'))
