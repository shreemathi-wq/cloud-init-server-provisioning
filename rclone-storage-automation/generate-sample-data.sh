#!/usr/bin/env bash
# ==============================================================================
# Testpress DevOps Exercise: Sample Data Generator
# Testpress Engineering
# Generates realistic test data representing video streaming assets, course PDFs,
# metadata, and large binary blobs for storage transfer experiments.
#
#   sample-data/        Nested streams, course docs, and a 100MB lecture recording
#   sample-data-large/  A 1GB database dump, isolated for large transfer tests
# ==============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SAMPLE_DIR="${SCRIPT_DIR}/sample-data"
readonly LARGE_DIR="${SCRIPT_DIR}/sample-data-large"

main() {
  echo "Generating Testpress realistic sample dataset..."
  create_stream_metadata
  create_course_pdfs
  create_binary_asset "${SAMPLE_DIR}/recordings/live-lecture-1080p.mp4" 100
  create_binary_asset "${LARGE_DIR}/backups/testpress-db-snapshot.dump" 1024
  echo ""
  echo "Sample dataset ready:"
  du -sh "${SAMPLE_DIR}" "${LARGE_DIR}"
}

create_stream_metadata() {
  mkdir -p "${SAMPLE_DIR}/streams" "${SAMPLE_DIR}/config"
  cat > "${SAMPLE_DIR}/streams/live_stream_metadata.json" <<'EOF'
{
  "service": "TPStreams",
  "stream_id": "live_str_9841af82",
  "resolution": "1080p",
  "enable_drm": false,
  "transcode_recorded_video": true,
  "status": "completed"
}
EOF

  cat > "${SAMPLE_DIR}/streams/live_class.m3u8" <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10.0,
segment_0.ts
#EXTINF:10.0,
segment_1.ts
#EXT-X-ENDLIST
EOF

  echo "APP_ENV=production" > "${SAMPLE_DIR}/config/app.env"
  echo "STORAGE_BACKEND=s3" >> "${SAMPLE_DIR}/config/app.env"
}

create_course_pdfs() {
  mkdir -p "${SAMPLE_DIR}/courses"
  generate_minimal_pdf "${SAMPLE_DIR}/courses/devops-engineering-syllabus.pdf" "Testpress DevOps Syllabus"
  generate_minimal_pdf "${SAMPLE_DIR}/courses/student-invoice.pdf" "Testpress Subscription Invoice"
}

generate_minimal_pdf() {
  local target_path="$1"
  local document_title="$2"
  local stream_content="BT /F1 24 Tf 72 720 Td (${document_title}) Tj ET"

  cat > "${target_path}" <<EOF
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
4 0 obj << /Length ${#stream_content} >> stream
${stream_content}
endstream endobj
5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
trailer << /Root 1 0 R >>
%%EOF
EOF
}

create_binary_asset() {
  local asset_path="$1"
  local size_in_mb="$2"
  if [[ -f "${asset_path}" ]]; then
    echo "Asset already exists: ${asset_path} (keeping existing)"
    return
  fi
  mkdir -p "$(dirname "${asset_path}")"
  echo "Generating uncompressible payload: ${asset_path} (${size_in_mb} MB)..."
  head -c "${size_in_mb}M" /dev/urandom > "${asset_path}"
}

main "$@"