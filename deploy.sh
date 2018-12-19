set -euxo pipefail

main() {
    local vers=0.52
    local url=https://github.com/gohugoio/hugo/releases/download/v$vers/hugo_${vers}_Linux-64bit.tar.gz

    curl -L $url | tar -xz hugo
    ./hugo

    mkdir ghp-import
    curl -Ls https://github.com/davisp/ghp-import/archive/master.tar.gz |
        tar --strip-components 1 -C ghp-import -xz;

    ./ghp-import/ghp_import.py public;

    set +x
    git push -fq https://$GH_TOKEN@github.com/$TRAVIS_REPO_SLUG.git gh-pages && echo OK
}

main
