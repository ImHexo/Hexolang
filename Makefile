CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
CPPFLAGS ?=
LDLIBS ?= -lm -lsqlite3
TARGET ?= hexo

# Optional adapters are enabled automatically when pkg-config finds the SDK.
WITH_MARIADB ?= $(shell pkg-config --exists libmariadb 2>/dev/null && echo 1 || echo 0)
WITH_SDL2 ?= $(shell pkg-config --exists sdl2 2>/dev/null && echo 1 || echo 0)
WITH_RAYLIB ?= $(shell pkg-config --exists raylib 2>/dev/null && echo 1 || echo 0)

# raylib 5.5+ uses Is*Valid; earlier releases use Is*Ready. Keep the C
# probe in its own file: embedding C expressions with parentheses inside a
# $(shell ...) expression breaks parsing in some GNU make versions on macOS.
RAYLIB_CFLAGS ?= $(shell pkg-config --cflags raylib 2>/dev/null)
RAYLIB_VALID_API ?= $(shell $(CC) $(RAYLIB_CFLAGS) -fsyntax-only native/raylib_api_probe.c >/dev/null 2>&1 && echo 1 || echo 0)

ifeq ($(WITH_MARIADB),1)
CPPFLAGS += -DHX_WITH_MARIADB $(shell pkg-config --cflags libmariadb)
LDLIBS += $(shell pkg-config --libs libmariadb)
endif
ifeq ($(WITH_SDL2),1)
CPPFLAGS += -DHX_WITH_SDL2 $(shell pkg-config --cflags sdl2)
LDLIBS += $(shell pkg-config --libs sdl2)
endif
ifeq ($(WITH_RAYLIB),1)
CPPFLAGS += -DHX_WITH_RAYLIB $(shell pkg-config --cflags raylib)
LDLIBS += $(shell pkg-config --libs raylib)
ifeq ($(RAYLIB_VALID_API),1)
CPPFLAGS += -DHX_RAYLIB_VALID_API
endif
endif

SOURCES = Hexo_0.5.3.S native/hexo_native.c native/hexo_game.c
.PHONY: all test clean config
all: $(TARGET)

$(TARGET): $(SOURCES) native/hexo_native.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SOURCES) -o $@ $(LDLIBS)

config:
	@echo "MariaDB: $(WITH_MARIADB)"
	@echo "SDL2:    $(WITH_SDL2)"
	@echo "raylib:  $(WITH_RAYLIB)"
	@echo "raylib Is*Valid API: $(if $(filter 1,$(RAYLIB_VALID_API)),yes,no)"

test: $(TARGET)
	CC='$(CC)' CPPFLAGS='$(CPPFLAGS)' CFLAGS='$(CFLAGS)' LDLIBS='$(LDLIBS)' ./test-runtime.sh
	HEXO_BIN='$(CURDIR)/$(TARGET)' ./test-hexoweb.sh

clean:
	rm -f $(sort $(TARGET) hexo chatgpt-prod-5p4) hexo-os-test.tmp hexo-os-renamed.tmp hexo-sqlite-test.db hexo-tabular-test.csv animath-demo.svg animath-advanced-demo.svg
