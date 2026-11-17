#!/usr/bin/env bash
#
# Проверяет все пакеты workspace: анализ и тесты там, где они есть.
# Скрипт общий для CI и локальной проверки, чтобы списки пакетов не
# расходились между workflow и документацией.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

for pkg in packages/*; do
  if [[ ! -f "$pkg/pubspec.yaml" ]]; then
    continue
  fi
  echo "::group::$pkg"
  (
    cd "$pkg"
    dart analyze
    if find test -name '*_test.dart' -print -quit 2>/dev/null | grep -q .; then
      if grep -q 'sdk: flutter' pubspec.yaml; then
        flutter test
      else
        dart test
      fi
    else
      echo "$pkg: тестов нет, пропускаю"
    fi
  )
  echo "::endgroup::"
done
