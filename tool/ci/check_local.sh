#!/usr/bin/env bash
#
# Полная локальная проверка проекта.
#
# --quick пропускает тесты: это режим для pre-push, где важны format,
# analyze и DCM. DCM не запускается в CI из-за лицензии, поэтому локальная
# проверка остаётся обязательной частью процесса.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

mode="${1:-full}"
if [[ "$mode" != "full" && "$mode" != "--quick" ]]; then
  echo "Использование: $0 [--quick]" >&2
  exit 2
fi

dart format --output=none --set-exit-if-changed lib test tool packages
flutter gen-l10n
flutter analyze

if ! command -v dcm >/dev/null 2>&1; then
  echo "dcm не установлен: установите DCM и повторите проверку." >&2
  exit 1
fi

dcm analyze lib test
for pkg in packages/*; do
  if [[ ! -f "$pkg/analysis_options.yaml" ]]; then
    continue
  fi
  paths=(lib)
  if [[ -d "$pkg/test" ]]; then
    paths+=(test)
  fi
  (
    cd "$pkg"
    dcm analyze "${paths[@]}"
  )
done

if [[ "$mode" == "full" ]]; then
  tool/ci/test_packages.sh
  flutter test
fi
