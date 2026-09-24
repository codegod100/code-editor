# Low* -> C pipeline for the freeq client's verified core.
#
# Two F* installs are needed and that is not an accident; see README.md.
#   FSTAR_LOWSTAR  v2026.03.24 — last release whose ulib still carries the
#                  classic Low* stack (FStar.HyperStack, LowStar.Buffer)
#   FSTAR_KRML     v2026.09.13 — ships the `krml` extractor, which the older
#                  release does not
FSTAR_LOWSTAR ?= $(HOME)/.local/opt/f0324/fstar
FSTAR_KRML    ?= $(HOME)/.local/opt/fstar

FSTAR  := $(FSTAR_LOWSTAR)/bin/fstar.exe
KRML   := $(FSTAR_KRML)/bin/krml
KRMLIB := $(FSTAR_KRML)/lib/krml
INC    := $(FSTAR_KRML)/include

MODULE ?= Smoke
CFLAGS += -I c -I cout -I $(INC) -I $(INC)/krml -I $(KRMLIB)/dist/minimal -Wall -Wextra -O2

.PHONY: all verify extract c run clean
all: run

## Verify only — proves memory safety and the modifies clause. No code out.
verify:
	$(FSTAR) --cache_dir cache --cache_checked_modules src/$(MODULE).fst

## Verify and emit the KaRaMeL intermediate form.
extract: | out cache
	$(FSTAR) --cache_dir cache --odir out --codegen krml \
	         --extract $(MODULE) src/$(MODULE).fst

## KaRaMeL turns that into C.
c: extract
	$(KRML) -skip-compilation -bundle '$(MODULE)=*' -tmpdir cout out/$(MODULE).krml

## Link the extracted C against a hand-written driver and run it.
run: c
	$(CC) $(CFLAGS) -o $(MODULE)_test c/main.c cout/$(MODULE).c
	./$(MODULE)_test

out cache:
	mkdir -p $@

clean:
	rm -rf out cache cout $(MODULE)_test
