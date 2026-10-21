#!/bin/sh
# Formatting, unit tests and strict type check. Run it before every commit.
#
# Tools (on PATH, or point STYLUA / LUAU / LUAU_LSP at them): stylua, luau, luau-lsp.
# The type check needs Tern's definitions: `tern plugin types .` writes tern.d.luau. Without Tern
# installed (for example in CI) it is skipped.
set -eu

cd "$(dirname "$0")/.."

STYLUA=${STYLUA:-stylua}
LUAU=${LUAU:-luau}
LUAU_LSP=${LUAU_LSP:-luau-lsp}

echo "==> format"
"$STYLUA" --check window.luau lib test

echo "==> tests"
for suite in test/*.luau; do
	"$LUAU" "$suite"
done

echo "==> types"
if [ ! -f tern.d.luau ] && command -v tern >/dev/null 2>&1; then
	tern plugin types .
fi
if [ -f tern.d.luau ]; then
	"$LUAU_LSP" analyze --platform=standard --definitions=@tern=tern.d.luau window.luau lib test
else
	echo "skipped: tern.d.luau not found (install Tern and run \`tern plugin types .\`)"
fi
