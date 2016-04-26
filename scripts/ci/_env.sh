PROJECT="manifest"

if [ -n "$TRAVIS_TAG" ]; then
    [[ ! "$TRAVIS_TAG" =~ .*-.* ]] && (echo "TRAVIS_TAG must have a hyphen"; exit 1)
    BUILD_TAG="${TRAVIS_TAG%-*}"
else
    BUILD_TAG="git-${TRAVIS_COMMIT:0:8}"
fi
