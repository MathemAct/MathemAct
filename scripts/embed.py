#!/usr/bin/env python3
"""
Compute sentence embeddings for published reports and write data/embeddings.json.

Model:   sentence-transformers/all-MiniLM-L6-v2
Licence: Apache 2.0  (https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
Output:  384-dimensional unit-length embeddings, quantised to uint8 and base64-encoded.

The quantisation map is linear over [-1, 1]:
  stored_byte = round((float_value + 1) / 2 * 255)   # 0–255
  float_value  = stored_byte / 255 * 2 - 1            # reconstruction

After L2 normalisation the values are in [-1, 1], so the map covers the full range
and introduces at most ±0.004 error per dimension — negligible for cosine similarity.

The browser-side duplicate check uses @xenova/transformers with the same model
(Xenova/all-MiniLM-L6-v2, the quantised ONNX conversion); embeddings compare correctly
across the two implementations because they share the tokeniser and weight matrix.

Usage
-----
  pip install sentence-transformers numpy
  python scripts/embed.py [--allow-shrink]

Flags
-----
  --allow-shrink   Allow the output file to shrink (e.g. after reports are removed).
                   Without it the script aborts if the count drops below half the
                   previous count — a safeguard against an empty input file.

CI
--
  .github/workflows/embed.yml runs this weekly. The model is cached in
  ~/.cache/huggingface/hub between runs. The output is committed to data/ only when the
  report set has changed; the manifest timestamp is not compared.
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import numpy as np
    from sentence_transformers import SentenceTransformer
except ImportError:
    sys.exit(
        "Missing dependencies. Install them:\n"
        "  pip install sentence-transformers numpy"
    )

REPO = Path(__file__).parent.parent
DATA = REPO / "data"
REPORTS_FILE = DATA / "reports.json"
EMBEDDINGS_FILE = DATA / "embeddings.json"

MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
MODEL_LICENCE = "Apache-2.0"


def quantise(embedding: np.ndarray) -> str:
    """Quantise a float32 unit vector to uint8 and encode as base64."""
    quantised = np.round((embedding + 1) / 2 * 255).clip(0, 255).astype(np.uint8)
    return base64.b64encode(quantised.tobytes()).decode("ascii")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--allow-shrink", action="store_true", help="Allow output to shrink without aborting")
    args = parser.parse_args()

    if not REPORTS_FILE.exists():
        sys.exit(
            f"  {REPORTS_FILE} not found.\n"
            "  Run scripts/export.mjs (or let .github/workflows/export.yml commit it) first."
        )

    reports: list[dict] = json.loads(REPORTS_FILE.read_text(encoding="utf-8"))

    # The export contains published rows only, so there is nothing here to filter for
    # visibility — this script reads a file and never opens a connection. Guard anyway:
    # only embed reports that carry content.
    published = [
        p for p in reports
        if p.get("aim") and not p.get("deletedAt")
    ]

    if not published:
        print("No published reports with content — nothing to embed.")
        return

    print(f"Loading {MODEL_NAME} …")
    model = SentenceTransformer(MODEL_NAME)

    texts = [f"{p['title']} {p['aim']}" for p in published]
    print(f"Embedding {len(texts)} reports (CPU) …")
    embeddings: np.ndarray = model.encode(
        texts,
        normalize_embeddings=True,
        show_progress_bar=True,
        device="cpu",
    )

    records = []
    for p, vec in zip(published, embeddings):
        records.append(
            {
                "id": p["id"],
                "title": p["title"],
                "taskType": p.get("taskType", ""),
                "area": p.get("area", ""),
                "tags": [t["code"] for t in p.get("tags", [])],
                "v": quantise(vec),
            }
        )

    # Shrink guard: refuse if count drops below half the previous count.
    if EMBEDDINGS_FILE.exists() and not args.allow_shrink:
        prev = json.loads(EMBEDDINGS_FILE.read_text(encoding="utf-8"))
        prev_count = prev.get("count", 0)
        if prev_count > 0 and len(records) < prev_count / 2:
            sys.exit(
                f"  Aborting: {len(records)} records < half of previous {prev_count}.\n"
                "  Pass --allow-shrink if the reduction is intentional."
            )

    output = {
        "model": MODEL_NAME,
        "modelLicence": MODEL_LICENCE,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "count": len(records),
        "reports": records,
    }

    EMBEDDINGS_FILE.write_text(json.dumps(output, ensure_ascii=False), encoding="utf-8")
    size_kb = EMBEDDINGS_FILE.stat().st_size / 1024
    print(f"Written {EMBEDDINGS_FILE.relative_to(REPO)} ({size_kb:.1f} KB, {len(records)} reports)")


if __name__ == "__main__":
    main()
