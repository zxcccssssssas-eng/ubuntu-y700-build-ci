#!/usr/bin/env bash
# Retry wrapper for apt-get when Ubuntu ports mirrors are mid-sync
# (hash/size mismatch). Source this file; do not execute it.

apt_retry() {
  local attempt=1
  local max=${APT_RETRY_ATTEMPTS:-6}
  local delay=${APT_RETRY_DELAY:-20}
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      echo "command failed after ${max} attempts: $*" >&2
      return 1
    fi
    echo "command failed (attempt ${attempt}/${max}); retrying in ${delay}s: $*" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    if [ "$delay" -gt 120 ]; then
      delay=120
    fi
  done
}

apt_configure_retries() {
  mkdir -p /etc/apt/apt.conf.d
  printf 'Acquire::Retries "5";\n' > /etc/apt/apt.conf.d/99ci-retries
}
