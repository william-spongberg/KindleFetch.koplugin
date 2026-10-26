#!/usr/bin/env bash
# Runs KindleFetch's end-to-end tests in a real KOReader, without a window, for each emulated device.
# These search Library Genesis, Internet Archive and Z-Library and download real books, so they need internet access
# and aren't run in CI. Z-Library's are skipped unless KINDLEFETCH_ZLIB_EMAIL and KINDLEFETCH_ZLIB_PASSWORD are set,
# and the libraries' unless Calibre is installed, whose content server they search.
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
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
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

# Calibre's content server, on a library holding Pride and Prejudice, for the tests of the libraries added
# (e2e/library_e2e.lua), where Calibre is installed. it needs logging in to, as Calibre asks without HTTPS (the
# Digest way). only one can run at a time, so it's left out while Calibre itself is open
calibre_vars=()
if command -v calibre-server >/dev/null 2>&1 && command -v calibredb >/dev/null 2>&1; then
    calibre="${repo}/e2e/.tmp/calibre"
    calibre_port=8399
    rm -rf "${calibre}/library" "${calibre}/users.sqlite"
    mkdir -p "${calibre}/library"
    # (kept from one run to the next)
    if [[ ! -s "${calibre}/pride.epub" ]]; then
        curl -fsSL -o "${calibre}/pride.epub" "https://www.gutenberg.org/ebooks/1342.epub.noimages" || true
    fi
    if calibredb add --library-path "${calibre}/library" "${calibre}/pride.epub" >"${calibre}/add.log" 2>&1 \
        && calibre-server --userdb "${calibre}/users.sqlite" --manage-users -- add kindlefetch "e2e password" \
            >"${calibre}/users.log" 2>&1; then
        calibre-server --port "${calibre_port}" --listen-on 127.0.0.1 --disable-use-bonjour --enable-auth \
            --userdb "${calibre}/users.sqlite" "${calibre}/library" >"${calibre}/server.log" 2>&1 &
        calibre_pid=$!
        trap 'kill "${calibre_pid}" 2>/dev/null' EXIT
        for _ in $(seq 1 30); do
            if curl -s -o /dev/null "http://127.0.0.1:${calibre_port}/opds"; then
                calibre_vars=(
                    "E2E_CALIBRE_URL=http://127.0.0.1:${calibre_port}"
                    "E2E_CALIBRE_USER=kindlefetch"
                    "E2E_CALIBRE_PASSWORD=e2e password"
                )
                break
            fi
            if ! kill -0 "${calibre_pid}" 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi
    if [[ ${#calibre_vars[@]} -eq 0 ]]; then
        echo "Calibre's content server couldn't be started (see ${calibre}), so its tests are skipped" >&2
    fi
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
        "${calibre_vars[@]}"
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
