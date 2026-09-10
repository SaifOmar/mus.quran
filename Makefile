BINS := quranproxyd.py quranctl.py
PREFIX := $(HOME)/.local/bin

.PHONY: all install test clean

all:

# Link the scripts into ~/.local/bin so the Service.qml probe's fallback path
# finds them no matter which folder the plugin is installed from.
install:
	@mkdir -p $(PREFIX)
	@for f in $(BINS); do \
	  ln -sf $(CURDIR)/$$f $(PREFIX)/$$f; \
	done
	@echo "linked $(BINS) into $(PREFIX)"

test:
	.venv/bin/pytest tests/ -v

lint:
	.venv/bin/ruff check .

clean:
	rm -rf __pycache__ */__pycache__ .pytest_cache .ruff_cache