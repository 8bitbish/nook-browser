# Sourced by the personal-build scripts.

NOOK_PERSONAL_FORK=8bitbish/nook-browser
# Self-signed, login Keychain, trusted for code signing only (shared with the orca-personal build).
# Keychain items and privacy grants are tied to the signer, so keep it the same across builds;
# a change means re-allowing them once.
NOOK_PERSONAL_SIGNING_IDENTITY='Orca Personal Build'

# Newest stable (no -beta) upstream release tag.
nook_latest_upstream_tag() {
  git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}

nook_notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}
