#!/bin/sh
# 拉取 openCypher TCK（Gherkin 场景集）到 _build/tck/openCypher（不进仓库）。
# 用法：apps/bitcask_cypher/test/tck/fetch.sh [tag]   缺省 tag 见下；之后 escript apps/bitcask_cypher/test/tck/tck.escript
set -e
TAG=${1:-2024.3}
DIR=_build/tck/openCypher
if [ -d "$DIR/.git" ]; then
    cur=$(git -C "$DIR" describe --tags --exact-match 2>/dev/null || true)
    if [ "$cur" = "$TAG" ]; then
        echo "openCypher TCK $TAG already in $DIR"
        exit 0
    fi
    rm -rf "$DIR"
fi
mkdir -p _build/tck
git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" https://github.com/opencypher/openCypher.git "$DIR"
echo "openCypher TCK $TAG -> $DIR"
