# Builds the mvsMF manuals.  Needs typst and the bookmaster submodule
# (git submodule update --init docs/books/bookmaster).

TYPST ?= typst
BM    := bookmaster
# The PDF carries the edition: ml08-0001-1.pdf is the First Edition of ML08-0001.
BOOKS := ml08-0001-1.pdf ml08-0002-1.pdf

.PHONY: all clean site

all: $(BOOKS)

ml08-0001-%.pdf: ml08-0001.typ $(wildcard guide/*.typ) $(wildcard ex/*/*.txt) $(BM)/bookmaster.typ
	$(TYPST) compile --root . --creation-timestamp 0 --font-path $(BM)/fonts --ignore-system-fonts $< $@

ml08-0002-%.pdf: ml08-0002.typ $(wildcard ref/*.typ) $(wildcard ex/*/*.txt) $(BM)/bookmaster.typ
	$(TYPST) compile --root . --creation-timestamp 0 --font-path $(BM)/fonts --ignore-system-fonts $< $@

# The web form, as Read the Docs builds it, into site/.
site:
	sh web/build.sh site

clean:
	rm -rf *.pdf site
