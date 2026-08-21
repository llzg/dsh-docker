#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OCR worker（独立子进程，供 see-router.py 以 60s 硬超时调用）。
用法: ocr_worker.py <图片路径>  → stdout 输出 JSON {items, avg_conf, total_text}
"""
import json
import sys


def main() -> int:
    img = sys.argv[1]
    from rapidocr_onnxruntime import RapidOCR
    engine = RapidOCR()
    result, _ = engine(img)
    items = []
    for box, text, conf in (result or []):
        xs = [p[0] for p in box]
        ys = [p[1] for p in box]
        items.append({
            "text": text,
            "conf": float(conf),
            "box": [int(min(xs)), int(min(ys)), int(max(xs)), int(max(ys))],
        })
    avg = sum(i["conf"] for i in items) / len(items) if items else 0.0
    total = "".join(i["text"] for i in items)
    print(json.dumps({"items": items, "avg_conf": avg, "total_text": total},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
