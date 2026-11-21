#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CC="${CC:-clang}"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$CC" ${CPPFLAGS:-} ${CFLAGS:-} "$ROOT/Hexo_0.5.3.S" "$ROOT/native/hexo_native.c" "$ROOT/native/hexo_game.c" -o "$BUILD_DIR/hexo" ${LDLIBS:--lm -lsqlite3}

# Keep the interned-known-name index within its reserved static table.
known_count="$(grep -c '^KN ' "$ROOT/Hexo_0.5.3.S")"
if (( known_count > 512 )); then
    echo "known_ptrs capacity exceeded: ${known_count} names, 512 slots" >&2
    exit 1
fi

run_ok() {
    local source="$1"
    local output="$2"
    if [[ "$source" = /* ]]; then
        (cd "$ROOT" && "$BUILD_DIR/hexo" "$source") > "$output"
    else
        (cd "$ROOT" && "$BUILD_DIR/hexo" "$ROOT/$source") > "$output"
    fi
}

run_ok examples/import_stdlib.hexo "$BUILD_DIR/import.txt"
grep -q '^9\.0$' "$BUILD_DIR/import.txt"

grep -q '^3\.141592653589793$' "$BUILD_DIR/import.txt"

run_ok examples/math_extended.hexo "$BUILD_DIR/math.txt"
grep -q 'extended math OK' "$BUILD_DIR/math.txt"

run_ok examples/random_extended.hexo "$BUILD_DIR/random.txt"
grep -q 'extended random and math OK' "$BUILD_DIR/random.txt"

run_ok examples/os_test.hexo "$BUILD_DIR/os.txt"
grep -q 'os module OK' "$BUILD_DIR/os.txt"

run_ok examples/pointers_visibility.hexo "$BUILD_DIR/pointers.txt"
grep -q 'value through pointer: 42' "$BUILD_DIR/pointers.txt"
grep -q 'secret through public method: 7' "$BUILD_DIR/pointers.txt"

run_ok tests/private_exception_restore.hexo "$BUILD_DIR/exception.txt"
grep -q '^caught$' "$BUILD_DIR/exception.txt"
grep -q '^2$' "$BUILD_DIR/exception.txt"

run_ok tests/member_table_growth.hexo "$BUILD_DIR/table.txt"
grep -q 'member table growth OK' "$BUILD_DIR/table.txt"

expect_private_failure() {
    local source="$1"
    local output="$2"
    if [[ "$source" = /* ]]; then
        if (cd "$ROOT" && "$BUILD_DIR/hexo" "$source") > "$output" 2>&1; then
            echo "Expected private access to fail: $source" >&2
            exit 1
        fi
    else
        if (cd "$ROOT" && "$BUILD_DIR/hexo" "$ROOT/$source") > "$output" 2>&1; then
            echo "Expected private access to fail: $source" >&2
            exit 1
        fi
    fi
    grep -q "is private" "$output"
}

expect_private_failure tests/private_inheritance.hexo "$BUILD_DIR/inheritance.txt"
expect_private_failure tests/private_static.hexo "$BUILD_DIR/static.txt"

run_ok examples/json.hexo "$BUILD_DIR/json.txt"
grep -q '^JSON OK$' "$BUILD_DIR/json.txt"

grep -q '"unicode":"🚀"' "$BUILD_DIR/json.txt"

run_ok examples/tabular.hexo "$BUILD_DIR/tabular.txt"
grep -q '^tabular OK$' "$BUILD_DIR/tabular.txt"

run_ok examples/sqlite.hexo "$BUILD_DIR/sqlite.txt"
grep -q '^sqlite OK$' "$BUILD_DIR/sqlite.txt"

run_ok examples/sqlite_helpers.hexo "$BUILD_DIR/sqlite-helpers.txt"
grep -q '^sqlite helpers OK$' "$BUILD_DIR/sqlite-helpers.txt"
grep -q '^sqlite prepared helpers OK$' "$BUILD_DIR/sqlite-helpers.txt"

run_ok examples/animath.hexo "$BUILD_DIR/animath.txt"
grep -q '^animath OK$' "$BUILD_DIR/animath.txt"
test -s "$ROOT/animath-demo.svg"

run_ok examples/json_extended.hexo "$BUILD_DIR/json-extended.txt"
grep -q '^json extended OK$' "$BUILD_DIR/json-extended.txt"

run_ok examples/tabular_analytics.hexo "$BUILD_DIR/tabular-analytics.txt"
grep -q '^tabular analytics OK$' "$BUILD_DIR/tabular-analytics.txt"

run_ok examples/tabular_join.hexo "$BUILD_DIR/tabular-join.txt"
grep -q '^tabular joins and mutation OK$' "$BUILD_DIR/tabular-join.txt"

run_ok examples/tabular_advanced.hexo "$BUILD_DIR/tabular-advanced.txt"
grep -q '^advanced tabular OK$' "$BUILD_DIR/tabular-advanced.txt"

run_ok examples/animath_timeline.hexo "$BUILD_DIR/animath-timeline.txt"
grep -q '^animath timeline OK$' "$BUILD_DIR/animath-timeline.txt"

run_ok examples/animath_scene.hexo "$BUILD_DIR/animath-scene.txt"
grep -q '^animath Scene API OK$' "$BUILD_DIR/animath-scene.txt"

run_ok examples/animath_advanced.hexo "$BUILD_DIR/animath-advanced.txt"
grep -q '^advanced animath OK$' "$BUILD_DIR/animath-advanced.txt"
test -s "$ROOT/animath-advanced-demo.svg"

run_ok examples/game3d_math.hexo "$BUILD_DIR/game3d-math.txt"
grep -q '^3D math helpers OK' "$BUILD_DIR/game3d-math.txt"

run_ok examples/game2d_math.hexo "$BUILD_DIR/game2d-math.txt"
grep -q '^2D math and collision helpers OK$' "$BUILD_DIR/game2d-math.txt"

run_ok examples/game_events.hexo "$BUILD_DIR/game-events.txt"
grep -q '^SDL event helpers OK$' "$BUILD_DIR/game-events.txt"

run_ok examples/os_extended.hexo "$BUILD_DIR/os-extended.txt"
grep -q '^extended OS OK$' "$BUILD_DIR/os-extended.txt"

run_ok examples/game_backend.hexo "$BUILD_DIR/game.txt"
grep -q '^SDL backend:' "$BUILD_DIR/game.txt"

run_ok examples/simple_game_backend.hexo "$BUILD_DIR/simple-game.txt"
grep -q '^2D backend:' "$BUILD_DIR/simple-game.txt"

run_ok examples/game_api_surface.hexo "$BUILD_DIR/game-api.txt"
grep -q '^game API surface OK$' "$BUILD_DIR/game-api.txt"

# The database client module must remain importable even when no live server is installed.
cat > "$BUILD_DIR/mysql-import.hexo" <<'HEXO'
import "stdlib/mysql.hexo" as mysql;
assert(typeof(mysql.open) == "function");
assert(typeof(mysql.prepare) == "function");
assert(typeof(mysql.openTLS) == "function");
print("mysql module import OK");
HEXO
run_ok "$BUILD_DIR/mysql-import.hexo" "$BUILD_DIR/mysql.txt"
grep -q '^mysql module import OK$' "$BUILD_DIR/mysql.txt"

cat > "$BUILD_DIR/mariadb-import.hexo" <<'HEXO'
import "stdlib/mariadb.hexo" as mariadb;
assert(typeof(mariadb.open) == "function");
assert(typeof(mariadb.openTLS) == "function");
assert(typeof(mariadb.prepare) == "function");
print("mariadb module import OK");
HEXO
run_ok "$BUILD_DIR/mariadb-import.hexo" "$BUILD_DIR/mariadb.txt"
grep -q '^mariadb module import OK$' "$BUILD_DIR/mariadb.txt"

run_ok examples/mariadb_import.hexo "$BUILD_DIR/db-modules.txt"
grep -q '^MySQL/MariaDB client modules OK$' "$BUILD_DIR/db-modules.txt"

echo "Hexo 0.5.3 runtime tests: PASS"
