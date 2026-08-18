BINS := quranproxyd quranctl
PREFIX := $(HOME)/.local/bin
ARCHS := amd64 arm64

.PHONY: all build install test vet fmt clean prebuilt dist

all: build

build:
	go build -o bin/quranproxyd ./cmd/quranproxyd
	go build -o bin/quranctl ./cmd/quranctl

# Install into the user's ~/.local/bin (the engine binaries' fallback location).
install: build
	install -D -m 0755 bin/quranproxyd $(PREFIX)/quranproxyd
	install -D -m 0755 bin/quranctl $(PREFIX)/quranctl

# Static, stripped prebuilt binaries committed under prebuilt/<os>-<arch>.
# Service.qml finds these first, so `omarchy plugin add` works with zero setup.
prebuilt:
	@for arch in $(ARCHS); do \
	  echo "building linux/$$arch"; \
	  GOOS=linux GOARCH=$$arch CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
	    -o prebuilt/linux-$$arch/quranproxyd ./cmd/quranproxyd; \
	  GOOS=linux GOARCH=$$arch CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
	    -o prebuilt/linux-$$arch/quranctl ./cmd/quranctl; \
	done

# Release archives: one tar.gz per arch plus a SHA-256 manifest, for GitHub
# Releases. Builds from the committed prebuilt binaries.
dist: prebuilt
	@rm -rf dist && mkdir -p dist
	@for arch in $(ARCHS); do \
	  tar -C prebuilt -czf dist/mus.quran-linux-$$arch.tar.gz linux-$$arch; \
	done
	@cd dist && sha256sum *.tar.gz > SHA256SUMS
	@ls -lh dist

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -l -w .

clean:
	rm -rf bin dist