# Build gptel from source in this clone.
#
#   make          byte-compile changed sources (incremental)
#   make clean    remove all byte-compiled files (*.elc)
#   make force    clean + full recompile
#   make EMACS=/path/to/emacs ...   use a specific Emacs

EMACS ?= /home/alex/git/clones/emacs/src/emacs

SRC := $(wildcard gptel*.el)
ELC := $(SRC:.el=.elc)

BYTECOMPILE := $(EMACS) -Q --batch -L . \
	--eval "(setq byte-compile-error-on-warn nil)" \
	-f batch-byte-compile

.PHONY: all force clean

all: $(ELC)

%.elc: %.el
	$(BYTECOMPILE) $<

force: clean all

clean:
	rm -f $(ELC)
