#!/usr/bin/env bash
# Runs KindleFetch's end-to-end tests in a real KOReader, without a window, for each emulated device.
# These search Library Genesis and download real books, so they need internet access and aren't run in CI.
#
# Usage: e2e/run.sh [-p profile]... [-k koreader_dir] [filter]
#   -p profile       device to emulate (kindle, kindle-paperwhite, kobo-aura-one, android), can be repeated;
#                    all of them by default
#   -k koreader_dir  a KOReader folder to use (e.g. an emulator built with ./kodev build, in
#                    koreader/koreader-emulator-*/koreader), instead of the KOReader Flatpak
#   filter           only run tests whose name contains this
#
# Screenshots and downloaded books end up in e2e/.tmp/<profile>/, along with KOReader's log.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profiles=()
koreader_dir=""

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts "p:k:h" opt; do
    case "${opt}" in
        p) profiles+=("${OPTARG}") ;;
        k) koreader_dir="$(cd "${OPTARG}" && pwd)" ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
filter="${1:-}"

if [[ ${#profiles[@]} -eq 0 ]]; then
    profiles=(kindle kindle-paperwhite kobo-aura-one android)
fi

if [[ -z "${koreader_dir}" ]] && ! flatpak info rocks.koreader.KOReader >/dev/null 2>&1; then
    echo "KOReader isn't installed from Flathub (flatpak install flathub rocks.koreader.KOReader)," >&2
    echo "so pass a KOReader folder with -k, e.g. an emulator built with ./kodev build." >&2
    exit 2
fi

status=0
for profile in "${profiles[@]}"; do
    work="${repo}/e2e/.tmp/${profile}"
    rm -rf "${work}"
    mkdir -p "${work}/koreader/plugins" "${work}/books" "${work}/screenshots"
    ln -s "${repo}/kindlefetch.koplugin" "${work}/koreader/plugins/kindlefetch.koplugin"

    env_vars=(
        "E2E_REPO=${repo}"
        "E2E_PROFILE=${profile}"
        "E2E_WORK=${work}"
        "E2E_FILTER=${filter}"
        "KO_HOME=${work}/koreader"
    )

    echo "== ${profile}"
    if [[ -n "${koreader_dir}" ]]; then
        run=(env "${env_vars[@]}" sh -c 'cd "$1" && exec ./luajit "$2"' sh "${koreader_dir}" "${repo}/e2e/runner.lua")
    else
        flatpak_env=()
        for var in "${env_vars[@]}"; do
            flatpak_env+=("--env=${var}")
        done
        run=(flatpak run --command=sh "${flatpak_env[@]}" rocks.koreader.KOReader
             -c 'cd /app/lib/koreader && exec ./luajit "$1"' sh "${repo}/e2e/runner.lua")
    fi

    # show the results, keeping KOReader's log in a file
    set +e
    "${run[@]}" 2>&1 | tee "${work}/koreader.log" | sed -n 's/^E2E|//p'
    result=${PIPESTATUS[0]}
    set -e
    if [[ ${result} -ne 0 ]]; then
        echo "   KOReader's log: ${work}/koreader.log"
        status=1
    fi
done

exit ${status}
