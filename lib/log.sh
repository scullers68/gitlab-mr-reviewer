#!/usr/bin/env bash
# Structured logging. Sourced by other scripts.

log::info()  { printf '[%s] INFO  %s\n'  "$(date -u +%FT%TZ)" "$*" >&2; }
log::warn()  { printf '[%s] WARN  %s\n'  "$(date -u +%FT%TZ)" "$*" >&2; }
log::error() { printf '[%s] ERROR %s\n'  "$(date -u +%FT%TZ)" "$*" >&2; }
log::debug() { [[ "${REVIEW_DEBUG:-0}" == "1" ]] && printf '[%s] DEBUG %s\n' "$(date -u +%FT%TZ)" "$*" >&2; return 0; }
