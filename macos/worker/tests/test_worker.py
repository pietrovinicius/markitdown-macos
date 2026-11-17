from __future__ import annotations

import json
import subprocess
import sys
import zipfile
from pathlib import Path

import openpyxl
import pptx
import pytest

WORKER_DIR = Path(__file__).resolve().parents[1]
WORKER_PATH = WORKER_DIR / "markitdown_macos_worker.py"
if str(WORKER_DIR) not in sys.path:
    sys.path.insert(0, str(WORKER_DIR))

from markitdown_macos_worker import LocalMarkItDownWorker, WorkerConversionError


def _create_docx(path: Path, paragraphs: list[str], heading: str | None = None) -> None:
    body_parts: list[str] = []
    if heading:
        body_parts.append(
            f"<w:p><w:pPr><w:pStyle w:val='Heading1'/></w:pPr>"
            f"<w:r><w:t>{heading}</w:t></w:r></w:p>"
        )
    for text in paragraphs:
        body_parts.append(f"<w:p><w:r><w:t>{text}</w:t></w:r></w:p>")

    document_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body>{''.join(body_parts)}</w:body>"
        "</w:document>"
    )
    content_types_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        "</Types>"
    )
    rels_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="word/document.xml"/>'
        "</Relationships>"
    )
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types_xml)
        zf.writestr("_rels/.rels", rels_xml)
        zf.writestr("word/document.xml", document_xml)


def _create_minimal_pdf(path: Path, text: str | None, encrypted: bool = False) -> None:
    if text:
        escaped = text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        stream_data = f"BT /F1 12 Tf 72 720 Td ({escaped}) Tj ET".encode("latin-1")
    else:
        stream_data = b""

    objects: list[bytes] = [
        b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        b"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
        (
            b"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n"
        ),
        (
            f"4 0 obj\n<< /Length {len(stream_data)} >>\nstream\n".encode("ascii")
            + stream_data
            + b"\nendstream\nendobj\n"
        ),
        b"5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n",
    ]
    if encrypted:
        objects.append(
            b"6 0 obj\n<< /Filter /Standard /V 1 /R 2 /O ("
            + b"a" * 32
            + b") /U ("
            + b"b" * 32
            + b") /P -4 >>\nendobj\n"
        )

    out = bytearray(b"%PDF-1.4\n")
    offsets: list[int] = []
    for obj in objects:
        offsets.append(len(out))
        out.extend(obj)

    xref_pos = len(out)
    out.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    out.extend(b"0000000000 65535 f \n")
    for off in offsets:
        out.extend(f"{off:010d} 00000 n \n".encode("ascii"))

    encrypt_ref = " /Encrypt 6 0 R" if encrypted else ""
    out.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R{encrypt_ref} >>\n"
        f"startxref\n{xref_pos}\n%%EOF\n".encode("ascii")
    )
    path.write_bytes(bytes(out))


def _run_worker(file_path: Path) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [sys.executable, str(WORKER_PATH), str(file_path)],
        capture_output=True,
        check=False,
    )


def test_convert_docx_preserves_accents_and_structure(tmp_path: Path) -> None:
    docx_path = tmp_path / "ata-reunião.docx"
    _create_docx(
        docx_path,
        paragraphs=["Decisão de orçamento: revisão concluída em São Paulo."],
        heading="Ata da Reunião",
    )

    proc = _run_worker(docx_path)
    assert proc.returncode == 0, proc.stderr.decode("utf-8", errors="replace")
    assert proc.stderr == b""
    markdown = proc.stdout.decode("utf-8")
    assert "# Ata da Reunião" in markdown
    assert "Decisão de orçamento: revisão concluída em São Paulo." in markdown


def test_convert_xlsx_renders_markdown_table(tmp_path: Path) -> None:
    xlsx_path = tmp_path / "orçamento.xlsx"
    wb = openpyxl.Workbook()
    ws = wb.active
    assert ws is not None
    ws.title = "Custos"
    ws.append(["Item", "Descrição", "Valor"])
    ws.append(["Licença", "Operação local", 1500])
    wb.save(xlsx_path)

    proc = _run_worker(xlsx_path)
    assert proc.returncode == 0, proc.stderr.decode("utf-8", errors="replace")
    assert proc.stderr == b""
    markdown = proc.stdout.decode("utf-8")
    assert "## Custos" in markdown
    assert "Descrição" in markdown
    assert "Operação local" in markdown


def test_convert_pptx_renders_slide_headings_and_text(tmp_path: Path) -> None:
    pptx_path = tmp_path / "apresentação.pptx"
    prs = pptx.Presentation()
    slide_layout = prs.slide_layouts[0]
    slide = prs.slides.add_slide(slide_layout)
    assert slide.shapes.title is not None
    slide.shapes.title.text = "Planejamento Trimestral"
    slide.placeholders[1].text = "Execução validada sem dependências externas."
    prs.save(pptx_path)

    proc = _run_worker(pptx_path)
    assert proc.returncode == 0, proc.stderr.decode("utf-8", errors="replace")
    assert proc.stderr == b""
    markdown = proc.stdout.decode("utf-8")
    assert "# Planejamento Trimestral" in markdown
    assert "Execução validada sem dependências externas." in markdown


def test_convert_textual_pdf_extracts_utf8_markdown(tmp_path: Path) -> None:
    pdf_path = tmp_path / "relatorio.pdf"
    _create_minimal_pdf(pdf_path, "Relatorio de conferencia anual 2026")

    proc = _run_worker(pdf_path)
    assert proc.returncode == 0, proc.stderr.decode("utf-8", errors="replace")
    assert proc.stderr == b""
    markdown = proc.stdout.decode("utf-8")
    assert "Relatorio de conferencia anual 2026" in markdown


@pytest.mark.parametrize("ext", [".docx", ".xlsx", ".pptx", ".pdf"])
def test_corrupted_files_fail_without_plaintext_or_zip_fallback(
    tmp_path: Path, ext: str
) -> None:
    bad_file = tmp_path / f"corrompido{ext}"
    bad_file.write_text("Conteudo texto puro que nao pode virar markdown", encoding="utf-8")

    proc = _run_worker(bad_file)
    assert proc.returncode == 4
    assert proc.stdout == b""
    payload = json.loads(proc.stderr.decode("utf-8"))
    assert payload["error_code"] == "corrupted_file"
    assert "corrompido" in payload["user_message"].lower()
    assert str(tmp_path) not in payload["diagnostic"]
    assert "Conteudo texto puro" not in payload["diagnostic"]


def test_zip_without_ooxml_structure_fails_as_corrupted(tmp_path: Path) -> None:
    fake_docx = tmp_path / "falso.docx"
    with zipfile.ZipFile(fake_docx, "w") as zf:
        zf.writestr("notas.txt", "segredo interno")

    proc = _run_worker(fake_docx)
    assert proc.returncode == 4
    assert proc.stdout == b""
    payload = json.loads(proc.stderr.decode("utf-8"))
    assert payload["error_code"] == "corrupted_file"
    assert "segredo interno" not in payload["diagnostic"]


def test_locked_pdf_returns_pdf_locked_error(tmp_path: Path) -> None:
    locked_pdf = tmp_path / "protegido.pdf"
    _create_minimal_pdf(locked_pdf, "Texto secreto", encrypted=True)

    proc = _run_worker(locked_pdf)
    assert proc.returncode == 3
    assert proc.stdout == b""
    payload = json.loads(proc.stderr.decode("utf-8"))
    assert payload["error_code"] == "pdf_locked"
    assert "desbloqueada" in payload["user_message"].lower()
    assert str(tmp_path) not in payload["diagnostic"]


def test_empty_document_returns_empty_output_error(tmp_path: Path) -> None:
    empty_docx = tmp_path / "vazio.docx"
    _create_docx(empty_docx, paragraphs=[""])

    proc = _run_worker(empty_docx)
    assert proc.returncode == 5
    assert proc.stdout == b""
    payload = json.loads(proc.stderr.decode("utf-8"))
    assert payload["error_code"] == "empty_output"
    assert payload["user_message"] == "Nenhum texto reconhecido"


def test_unsupported_extension_rejected(tmp_path: Path) -> None:
    txt_file = tmp_path / "nota.txt"
    txt_file.write_text("texto", encoding="utf-8")

    proc = _run_worker(txt_file)
    assert proc.returncode == 2
    assert proc.stdout == b""
    payload = json.loads(proc.stderr.decode("utf-8"))
    assert payload["error_code"] == "unsupported_format"


def test_worker_class_instantiation_and_plugins_disabled(tmp_path: Path) -> None:
    worker = LocalMarkItDownWorker()
    assert worker.plugins_enabled is False

    docx_path = tmp_path / "direto.docx"
    _create_docx(docx_path, paragraphs=["Texto via classe LocalMarkItDownWorker."])
    output = worker.convert_file(docx_path)
    assert "Texto via classe LocalMarkItDownWorker." in output

    missing_path = tmp_path / "inexistente.docx"
    with pytest.raises(WorkerConversionError) as exc_info:
        worker.convert_file(missing_path)
    assert exc_info.value.error_code == "file_unreadable"

