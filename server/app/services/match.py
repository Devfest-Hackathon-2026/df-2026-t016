"""外観照合（設計書9章、tasks/T08）。終了画面の JPEG と提出された PNG を比べる。

ORB の特徴点で位置を合わせ（回転・拡大・移動）、写した PNG が有効に重なる画素だけで SSIM を平均する。
数値は初期値で、T11 で実機の値を見て決める（Settings の match_*）。
"""

from __future__ import annotations

import io

import cv2
import numpy as np
from PIL import Image
from skimage.metrics import structural_similarity

SSIM_WIN = 7  # SSIM の窓。半径は3画素
LONG_SIDE = 1024


def _unverified(reason: str) -> dict:
    return {"result": "unverified", "score": None, "reason": reason}


def png_to_gray(png: bytes, long_side: int = LONG_SIDE) -> np.ndarray:
    """PNG を長辺 long_side に縮め、透明な部分を白にしてグレースケールにする。"""
    im = Image.open(io.BytesIO(png))
    im.load()
    if im.mode in ("RGBA", "LA", "P"):
        rgba = im.convert("RGBA")
        bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        im = Image.alpha_composite(bg, rgba)
    im = im.convert("L")
    scale = long_side / max(im.size)
    if scale < 1:
        im = im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.LANCZOS)
    return np.asarray(im, dtype=np.uint8)


def match_images(
    end_jpeg: bytes | None,
    png: bytes | None,
    *,
    threshold: float = 0.80,
    min_screen: float = 0.20,
    min_png: float = 0.50,
) -> dict:
    # 1. どちらかが無い
    if end_jpeg is None:
        return _unverified("終了画面がない")
    if png is None:
        return _unverified("PNG がない")

    # 2. 読み込む
    end = cv2.imdecode(np.frombuffer(end_jpeg, np.uint8), cv2.IMREAD_GRAYSCALE)
    if end is None:
        return _unverified("終了画面を読めない")
    try:
        src = png_to_gray(png)
    except Exception:
        return _unverified("PNG を読めない")

    # 3. 特徴点の対応
    orb = cv2.ORB_create(nfeatures=2000)
    kp_p, des_p = orb.detectAndCompute(src, None)
    kp_e, des_e = orb.detectAndCompute(end, None)
    if des_p is None or des_e is None:
        return _unverified("特徴点が足りない")
    matches = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True).match(des_p, des_e)
    if len(matches) < 30:
        return _unverified("特徴点が足りない")
    png_pts = np.float32([kp_p[m.queryIdx].pt for m in matches]).reshape(-1, 1, 2)
    end_pts = np.float32([kp_e[m.trainIdx].pt for m in matches]).reshape(-1, 1, 2)

    # 4. 位置合わせ
    A, inliers = cv2.estimateAffinePartial2D(png_pts, end_pts, method=cv2.RANSAC, ransacReprojThreshold=5.0)
    if A is None or inliers is None or int(inliers.sum()) < 20:
        return _unverified("位置が合わない")
    s = float(np.sqrt(abs(np.linalg.det(A[:, :2]))))
    if not (0.2 <= s <= 5.0):
        return _unverified("位置が合わない")

    # 5. 有効な重なりのマスク
    h, w = end.shape
    warped = cv2.warpAffine(src, A, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    ones = np.full(src.shape, 255, np.uint8)
    m_in = cv2.warpAffine(ones, A, (w, h), flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    r = SSIM_WIN // 2
    m = cv2.erode(m_in, np.ones((2 * r + 1, 2 * r + 1), np.uint8))

    # 6. 面積の条件
    area_in = float(np.count_nonzero(m_in))
    ph, pw = src.shape
    if area_in / (w * h) < min_screen or area_in / (s * s * pw * ph) < min_png or not np.any(m):
        return _unverified("比較できる範囲が小さい")

    # 7. SSIM（マスクの中だけで平均する）
    _, smap = structural_similarity(end, warped, win_size=SSIM_WIN, data_range=255, gaussian_weights=False, full=True)
    score = round(float(smap[m > 0].mean()), 3)

    # 8.
    if score >= threshold:
        return {"result": "match", "score": score, "reason": None}
    return {"result": "mismatch", "score": score, "reason": "提出画像が終了画面と外観で一致しません"}
