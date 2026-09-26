.PHONY: app release install

# Development build at build/Rotap.app (signed, not notarized).
app:
	@scripts/build-app.sh

# Notarize through the account pipeline (asc notarize rotap) and publish a GitHub release.
# `scripts/publish.sh --dry-run` checks the preconditions without spending a notarization.
release:
	@scripts/publish.sh

# Put the released disk image into /Applications. This is the copy to use and test.
install:
	@scripts/install-release.sh
