#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS_DIR="${REPO_ROOT}/macos"
BUILD_DIR="${MACOS_DIR}/build"
DIST_DIR="${MACOS_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/MarkItDown.app"
VENV_PYINSTALLER="${REPO_ROOT}/.venv/bin/pyinstaller"

if [[ ! -x "${VENV_PYINSTALLER}" ]]; then
    echo "Erro: PyInstaller não encontrado em ${VENV_PYINSTALLER}" >&2
    exit 1
fi

echo "==> [1/4] Empacotando worker Python standalone (PyInstaller arm64)..."
rm -rf "${BUILD_DIR}/pyinstaller" "${BUILD_DIR}/worker-dist"
"${VENV_PYINSTALLER}" \
    --noconfirm \
    --clean \
    --onedir \
    --name markitdown-worker \
    --distpath "${BUILD_DIR}/worker-dist" \
    --workpath "${BUILD_DIR}/pyinstaller/work" \
    --specpath "${BUILD_DIR}/pyinstaller/spec" \
    --paths "${REPO_ROOT}/packages/markitdown/src" \
    --exclude-module magika \
    --exclude-module onnxruntime \
    --exclude-module pytest \
    --exclude-module mypy \
    --exclude-module ruff \
    --exclude-module tkinter \
    --hidden-import mammoth \
    --hidden-import openpyxl \
    --hidden-import pandas \
    --hidden-import pptx \
    --hidden-import pdfminer \
    --hidden-import pdfminer.high_level \
    --hidden-import pdfplumber \
    --hidden-import bs4 \
    --hidden-import lxml \
    --hidden-import lxml.etree \
    --hidden-import markdownify \
    --hidden-import defusedxml \
    --hidden-import charset_normalizer \
    "${MACOS_DIR}/worker/markitdown_macos_worker.py"

echo "==> [2/4] Compilando executável SwiftUI em modo Release (arm64)..."
swift build -c release --package-path "${MACOS_DIR}" --arch arm64
SWIFT_BIN_DIR="$(swift build -c release --package-path "${MACOS_DIR}" --arch arm64 --show-bin-path)"
SWIFT_EXECUTABLE="${SWIFT_BIN_DIR}/MarkItDownMac"

echo "==> [3/4] Montando bundle ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${MACOS_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "${SWIFT_EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/MarkItDownMac"
chmod +x "${APP_BUNDLE}/Contents/MacOS/MarkItDownMac"
cp -R "${BUILD_DIR}/worker-dist/markitdown-worker" "${APP_BUNDLE}/Contents/Resources/markitdown-worker"
chmod +x "${APP_BUNDLE}/Contents/Resources/markitdown-worker/markitdown-worker"

echo "==> [4/4] Assinando bundle localmente (ad-hoc codesign)..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Build concluído: ${APP_BUNDLE}"
