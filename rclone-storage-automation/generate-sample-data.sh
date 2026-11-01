#!/usr/bin/env bash
# Creates reproducible test data for the rclone experiments.
#
#   sample-data/        nested folders, text files, PDFs and a 100 MB file
#   sample-data-large/  a 1 GB file, kept separate so everyday experiments stay fast
#
# Large files use random bytes so they cannot be compressed and behave like
# real video/backup files. Existing large files are kept, so re-running is cheap.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SAMPLE_DIR="${SCRIPT_DIR}/sample-data"
readonly LARGE_DIR="${SCRIPT_DIR}/sample-data-large"

main() {
  create_text_files
  create_pdf_files
  create_random_file "${SAMPLE_DIR}/videos/lecture-100mb.bin" 100
  create_random_file "${LARGE_DIR}/backup-1gb.bin" 1024
  echo "Sample data ready:"
  du -sh "${SAMPLE_DIR}" "${LARGE_DIR}"
}

create_text_files() {
  mkdir -p "${SAMPLE_DIR}/docs/notes" "${SAMPLE_DIR}/config" "${SAMPLE_DIR}/videos"
  echo "Course overview for the rclone exercise." > "${SAMPLE_DIR}/docs/readme.txt"
  echo "Chapter 1: Introduction to storage."      > "${SAMPLE_DIR}/docs/notes/chapter-1.txt"
  echo "Chapter 2: Object storage and S3."        > "${SAMPLE_DIR}/docs/notes/chapter-2.txt"
  echo "app_env=staging"                          > "${SAMPLE_DIR}/config/app.env"
}

create_pdf_files() {
  mkdir -p "${SAMPLE_DIR}/docs/pdfs"
  write_minimal_pdf "${SAMPLE_DIR}/docs/pdfs/syllabus.pdf" "Syllabus"
  write_minimal_pdf "${SAMPLE_DIR}/docs/pdfs/invoice.pdf" "Invoice"
}

# Writes a minimal single-page PDF so no PDF tooling is required. It has no
# xref table; PDF viewers rebuild it, and `file` detects it as a PDF.
write_minimal_pdf() {
  local path="$1" text="$2"
  local stream="BT /F1 24 Tf 72 720 Td (${text}) Tj ET"
  cat > "${path}" <<EOF
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
4 0 obj << /Length ${#stream} >> stream
${stream}
endstream endobj
5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
trailer << /Root 1 0 R >>
%%EOF
EOF
}

create_random_file() {
  local path="$1" size_mb="$2"
  if [[ -f "${path}" ]]; then
    echo "Keeping existing ${path}"
    return
  fi
  mkdir -p "$(dirname "${path}")"
  echo "Creating ${path} (${size_mb} MB)..."
  head -c "${size_mb}M" /dev/urandom > "${path}"
}

main "$@"
