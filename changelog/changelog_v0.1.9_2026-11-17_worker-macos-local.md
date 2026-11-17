## [0.1.9] - 2026-11-17

### Adicionado

- **macos/worker/markitdown_macos_worker.py**: worker Python local para DOCX, XLSX, PPTX e PDF textual usando `convert_local()` com plugins desabilitados, validação estrutural e diagnóstico JSON sanitizado.
- **macos/worker/tests/test_worker.py**: testes automatizados cobrindo acentuação UTF-8, tabelas/slides, arquivos corrompidos, PDF protegido por senha, documento sem texto e formato não suportado.
