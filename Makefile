PREFIX ?= $(HOME)
BINDIR ?= $(PREFIX)/bin
TARGET := $(BINDIR)/ab.sh
SRC := $(CURDIR)/ab.sh

.PHONY: link unlink relink deps

link:
	@mkdir -p "$(BINDIR)"
	@ln -sf "$(SRC)" "$(TARGET)"
	@echo "Linked $(SRC) -> $(TARGET)"

unlink:
	@rm -f "$(TARGET)"
	@echo "Unlinked $(TARGET)"

relink: unlink link

# Runtime dependencies only; no installation performed
# Exit non-zero if missing

deps:
	@set -e; \
	for c in bash ffprobe ffmpeg; do \
		command -v $$c >/dev/null 2>&1 || { echo "Missing: $$c" >&2; exit 1; }; \
	done; \
	echo "All deps present"
