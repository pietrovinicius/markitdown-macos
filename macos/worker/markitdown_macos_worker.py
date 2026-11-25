#!/usr/bin/env python3
"""Local MarkItDown worker for the macOS app.

Converts validated local Office (.docx, .xlsx, .pptx) and textual PDF (.pdf)
files using MarkItDown(enable_plugins=False).convert_local() with plugins
disabled and no fallback to generic plain-text or zip dumpers.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import types
import warnings
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

# StrictLocalMarkItDown validates extensions directly and never invokes Magika/ONNX.
sys.modules.setdefault("magika", types.ModuleType("magika"))

from markitdown import MarkItDown, StreamInfo
from markitdown._base_converter import DocumentConverter
from markitdown._exceptions import FileConversionException, UnsupportedFormatException
from markitdown._markitdown import ConverterRegistration
from markitdown.converters import (
    DocxConverter,
    PdfConverter,
    PptxConverter,
    XlsxConverter,
)
from pdfminer.pdfdocument import (
    PDFDocument,
    PDFEncryptionError,
    PDFPasswordIncorrect,
    PDFSyntaxError,
)
from pdfminer.pdfpage import PDFPage
from pdfminer.pdfparser import PDFParser
from pdfminer.pdftypes import PDFException

EXIT_OK = 0
EXIT_UNSUPPORTED = 2
EXIT_PDF_LOCKED = 3
EXIT_CORRUPTED = 4
EXIT_EMPTY_OUTPUT = 5
EXIT_UNREADABLE = 6

EXPECTED_OOXML_PART: dict[str, str] = {
    ".docx": "word/document.xml",
    ".xlsx": "xl/workbook.xml",
    ".pptx": "ppt/presentation.xml",
}

SUPPORTED_WORKER_EXTENSIONS: frozenset[str] = frozenset(
    {".docx", ".xlsx", ".pptx", ".pdf"}
)

_HTML_COMMENT_RE = re.compile(r"<!--.*?-->", flags=re.DOTALL)


@dataclass(frozen=True)
class WorkerConversionError(Exception):
    exit_code: int
    error_code: str
    user_message: str
    diagnostic: str


class StrictLocalMarkItDown(MarkItDown):
    """MarkItDown instance restricted to MVP local converters with plugins disabled."""

    def __init__(self) -> None:
        # Initialize MarkItDown state without loading remote sessions, plugins, or Magika ONNX.
        self._builtins_enabled = False
        self._plugins_enabled = False
        self._llm_client: Any = None
        self._llm_model: str | None = None
        self._llm_prompt: str | None = None
        self._exiftool_path: str | None = None
        self._style_map: str | None = None
        self._converters: list[ConverterRegistration] = []

        for converter in self._mvp_converters():
            self.register_converter(converter)

    @staticmethod
    def _mvp_converters() -> tuple[DocumentConverter, ...]:
        return (
            DocxConverter(),
            XlsxConverter(),
            PptxConverter(),
            PdfConverter(),
        )

    def _get_stream_info_guesses(
        self, file_stream: BinaryIO, base_guess: StreamInfo
    ) -> list[StreamInfo]:
        # Trust only the validated extension of the local file so corrupted files
        # are never re-routed to another converter by content heuristics.
        return [base_guess]


class LocalMarkItDownWorker:
    """Validates and converts a single local document to UTF-8 Markdown."""

    def __init__(self) -> None:
        self.engine = StrictLocalMarkItDown()

    @property
    def plugins_enabled(self) -> bool:
        return bool(self.engine._plugins_enabled)

    def convert_file(self, file_path: str | Path) -> str:
        path = Path(file_path)

        if not path.exists() or not path.is_file() or not os.access(path, os.R_OK):
            raise WorkerConversionError(
                exit_code=EXIT_UNREADABLE,
                error_code="file_unreadable",
                user_message=(
                    "Não foi possível ler o arquivo selecionado. "
                    "Verifique as permissões e tente novamente."
                ),
                diagnostic="file_not_readable",
            )

        ext = path.suffix.lower()
        if ext not in SUPPORTED_WORKER_EXTENSIONS:
            raise WorkerConversionError(
                exit_code=EXIT_UNSUPPORTED,
                error_code="unsupported_format",
                user_message=(
                    "Formato não suportado pelo conversor. "
                    "Use arquivos DOCX, XLSX, PPTX, PDF, PNG ou JPEG."
                ),
                diagnostic=f"unsupported_extension:{ext or 'none'}",
            )

        if ext == ".pdf":
            self._validate_pdf(path)
        else:
            self._validate_ooxml(path, ext)

        try:
            logging.disable(logging.CRITICAL)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                result = self.engine.convert_local(path)
        except FileConversionException as exc:
            self._raise_from_conversion_exception(exc)
        except UnsupportedFormatException as exc:
            raise WorkerConversionError(
                exit_code=EXIT_UNSUPPORTED,
                error_code="unsupported_format",
                user_message=(
                    "Formato não suportado pelo conversor. "
                    "Use arquivos DOCX, XLSX, PPTX, PDF, PNG ou JPEG."
                ),
                diagnostic=type(exc).__name__,
            ) from exc
        except Exception as exc:
            raise WorkerConversionError(
                exit_code=EXIT_CORRUPTED,
                error_code="corrupted_file",
                user_message=(
                    "Arquivo corrompido ou ilegível. "
                    "Verifique se o documento abre normalmente no aplicativo de origem."
                ),
                diagnostic=type(exc).__name__,
            ) from exc

        markdown = (result.markdown or "").strip()
        visible_text = _HTML_COMMENT_RE.sub("", markdown).strip()
        if not visible_text:
            raise WorkerConversionError(
                exit_code=EXIT_EMPTY_OUTPUT,
                error_code="empty_output",
                user_message="Nenhum texto reconhecido",
                diagnostic="empty_markdown_output",
            )

        return markdown

    def _validate_ooxml(self, path: Path, ext: str) -> None:
        required_part = EXPECTED_OOXML_PART[ext]
        try:
            with zipfile.ZipFile(path, "r") as zf:
                names = set(zf.namelist())
        except (zipfile.BadZipFile, OSError) as exc:
            raise WorkerConversionError(
                exit_code=EXIT_CORRUPTED,
                error_code="corrupted_file",
                user_message=(
                    "Arquivo corrompido ou ilegível. "
                    "Verifique se o documento abre normalmente no aplicativo de origem."
                ),
                diagnostic=type(exc).__name__,
            ) from exc

        if required_part not in names:
            raise WorkerConversionError(
                exit_code=EXIT_CORRUPTED,
                error_code="corrupted_file",
                user_message=(
                    "Arquivo corrompido ou com estrutura Office inválida. "
                    "Verifique o documento de origem."
                ),
                diagnostic="missing_ooxml_part",
            )

    def _validate_pdf(self, path: Path) -> None:
        try:
            with path.open("rb") as fh:
                header = fh.read(1024)
                if b"%PDF-" not in header:
                    raise WorkerConversionError(
                        exit_code=EXIT_CORRUPTED,
                        error_code="corrupted_file",
                        user_message=(
                            "Arquivo PDF corrompido ou inválido. "
                            "Verifique o documento de origem."
                        ),
                        diagnostic="missing_pdf_header",
                    )
                fh.seek(0)
                parser = PDFParser(fh)
                doc = PDFDocument(parser)
                has_page = any(True for _ in PDFPage.create_pages(doc))
                if not has_page:
                    raise WorkerConversionError(
                        exit_code=EXIT_CORRUPTED,
                        error_code="corrupted_file",
                        user_message=(
                            "Arquivo PDF corrompido ou sem páginas válidas. "
                            "Verifique o documento de origem."
                        ),
                        diagnostic="pdf_no_pages",
                    )
        except WorkerConversionError:
            raise
        except (PDFPasswordIncorrect, PDFEncryptionError) as exc:
            raise WorkerConversionError(
                exit_code=EXIT_PDF_LOCKED,
                error_code="pdf_locked",
                user_message="PDF protegido por senha. Adicione uma cópia desbloqueada.",
                diagnostic=type(exc).__name__,
            ) from exc
        except (PDFSyntaxError, PDFException, OSError, ValueError, TypeError) as exc:
            raise WorkerConversionError(
                exit_code=EXIT_CORRUPTED,
                error_code="corrupted_file",
                user_message=(
                    "Arquivo PDF corrompido ou inválido. "
                    "Verifique o documento de origem."
                ),
                diagnostic=type(exc).__name__,
            ) from exc

    def _raise_from_conversion_exception(self, exc: FileConversionException) -> None:
        attempts = exc.attempts or []
        for attempt in attempts:
            if attempt.exc_info and attempt.exc_info[0] is not None:
                exc_type = attempt.exc_info[0]
                if issubclass(exc_type, (PDFPasswordIncorrect, PDFEncryptionError)):
                    raise WorkerConversionError(
                        exit_code=EXIT_PDF_LOCKED,
                        error_code="pdf_locked",
                        user_message=(
                            "PDF protegido por senha. Adicione uma cópia desbloqueada."
                        ),
                        diagnostic=exc_type.__name__,
                    ) from exc

        first_diag = (
            attempts[0].exc_info[0].__name__
            if attempts and attempts[0].exc_info and attempts[0].exc_info[0]
            else "FileConversionException"
        )
        raise WorkerConversionError(
            exit_code=EXIT_CORRUPTED,
            error_code="corrupted_file",
            user_message=(
                "Arquivo corrompido ou ilegível. "
                "Verifique se o documento abre normalmente no aplicativo de origem."
            ),
            diagnostic=first_diag,
        ) from exc


def main(argv: list[str] | None = None) -> int:
    warnings.simplefilter("ignore")
    parser = argparse.ArgumentParser(
        prog="markitdown-macos-worker",
        description="Local MarkItDown worker for macOS.",
    )
    parser.add_argument("file_path", help="Path to the local file to convert.")
    args = parser.parse_args(argv)

    worker = LocalMarkItDownWorker()
    try:
        markdown = worker.convert_file(args.file_path)
    except WorkerConversionError as err:
        payload = {
            "error_code": err.error_code,
            "user_message": err.user_message,
            "diagnostic": err.diagnostic,
        }
        sys.stderr.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stderr.flush()
        return err.exit_code

    sys.stdout.buffer.write(markdown.encode("utf-8"))
    sys.stdout.buffer.flush()
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
