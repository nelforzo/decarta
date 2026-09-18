# Decarta — corpus pipeline + native app.
#
# `make` alone: build the sample corpus, verify it, build the app, run its selftest.

PYTHON ?= python3
PYTHONPATH := extractor
CORPUS ?= build/corpus.db
SAMPLE_ROOT ?= sample-data
SOURCES ?= $(SAMPLE_ROOT)
ADAPTER ?= generic-html
MEDIA_OUT ?= build/media
BIN := app/.build/debug/Decarta
Q ?=

.DEFAULT_GOAL := all
.PHONY: all sample ingest verify query list app selftest run clean distclean

all: verify app selftest

sample:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract sample -o $(SAMPLE_ROOT)

## ingest SOURCES=<mounted disc dir> ADAPTER=<name>
ingest:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract ingest "$(SOURCES)" \
		--adapter $(ADAPTER) -o $(CORPUS) --media-out $(MEDIA_OUT)

verify:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract verify -d $(CORPUS)

query:
	@test -n "$(Q)" || { echo 'usage: make query Q="search terms"'; exit 2; }
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract query "$(Q)" -d $(CORPUS)

list:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract list -d $(CORPUS)

app:
	cd app && swift build

## headless end-to-end check of the app against the corpus
selftest: app
	$(BIN) --selftest $(CORPUS)

run: app
	$(BIN) --corpus $(CORPUS)

clean:
	rm -rf build app/.build

## also drops the committed sample corpus
distclean: clean
	rm -rf $(SAMPLE_ROOT)