#!/usr/bin/env bash
# Downloads the PP-OCRv5 checkpoints for the ExecuTorch export: the safetensors versions for
# transformers, and the ONNX ones the app runs today, to compare against. Revisions are pinned.
# usage: scripts/executorch/download-models.sh <dir>
set -euo pipefail
DIR="${1:?target dir}"
HF=https://huggingface.co/PaddlePaddle
DET=PP-OCRv5_mobile_det_safetensors@c5041d225cf951ff06900ab81a3c7d543c45e2ad
REC=eslav_PP-OCRv5_mobile_rec_safetensors@feb3757f69257ed5320044604217032a7b90b789
mkdir -p "$DIR/det" "$DIR/rec" "$DIR/onnx"
for f in config.json preprocessor_config.json model.safetensors; do
  curl -fsSL -o "$DIR/det/$f" "$HF/${DET%@*}/resolve/${DET#*@}/$f"
  curl -fsSL -o "$DIR/rec/$f" "$HF/${REC%@*}/resolve/${REC#*@}/$f"
done
# The same ONNX files as the eslav pack of models/manifest.json.
curl -fsSL -o "$DIR/onnx/det.onnx" "$HF/PP-OCRv5_mobile_det_onnx/resolve/e6f4fa85f00e168c862bc462aebca69eef9b3d3d/inference.onnx"
curl -fsSL -o "$DIR/onnx/rec.onnx" "$HF/eslav_PP-OCRv5_mobile_rec_onnx/resolve/9a32171fc5718746875e1a261818884517975013/inference.onnx"
echo "downloaded to $DIR"
