# Decarta — corpus pipeline + native app.
#
# `make` alone: build the sample corpus, verify it, build the app, run its selftest.
#
# The real disc (one extra step, see README):
#   make mount && make ingest-disc DISC=/Volumes/L03JXLRD1 && make verify
#   make run

PYTHON ?= python3
PYTHONPATH := extractor
CORPUS ?= build/corpus.db
SAMPLE_ROOT ?= sample-data
SOURCES ?= $(SAMPLE_ROOT)
ADAPTER ?= generic-html
TOKENIZER ?= auto
MEDIA_OUT ?= build/media
## ingest-disc copies pictures unless MEDIA=0
MEDIA ?= 1
SCRATCH ?= build/its-scratch
ISO ?= encarta2003.iso
DISC ?= /tmp/encarta_mnt
BIN := app/.build/debug/Decarta
Q ?=

.DEFAULT_GOAL := all
.PHONY: all sample ingest ingest-disc mount unmount verify query show list app selftest run dist clean distclean

all: sample ingest verify app selftest

sample:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract sample -o $(SAMPLE_ROOT)

## ingest SOURCES=<mounted disc dir> ADAPTER=<name>  (fixture by default)
ingest:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract ingest "$(SOURCES)" \
		--adapter $(ADAPTER) --tokenizer $(TOKENIZER) --media-out $(MEDIA_OUT)

## ingest the real Encarta DVD; pictures are copied by default (MEDIA=0 to skip)
ingest-disc:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract ingest "$(DISC)" \
		--adapter encarta-its --scratch $(SCRATCH) \
		$(if $(filter 1,$(MEDIA)),--media-out $(MEDIA_OUT),)

mount:
	hdiutil attach -readonly -nobrowse -mountpoint "$(DISC)" "$(ISO)"

unmount:
	hdiutil detach "$(DISC)"

verify:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract verify -d $(CORPUS)

query:
	@test -n "$(Q)" || { echo 'usage: make query Q="search terms"'; exit 2; }
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract query "$(Q)" -d $(CORPUS) -n $(if $(N),$(N),10)

show:
	@test -n "$(Q)" || { echo 'usage: make show Q=<slug|title>'; exit 2; }
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract show "$(Q)" -d $(CORPUS)

list:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m decarta_extract list -d $(CORPUS)

app:
	cd app && swift build

## build a self-contained Decarta.app (ingests the disc; SKIP_INGEST=1 to repackage)
dist:
	./scripts/build-app.sh

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
