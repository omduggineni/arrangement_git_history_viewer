# Top-level build entry point; each version of the app lives in its own directory
# and keeps its own Makefile.
#   cross_platform/  Python + pywebview app (macOS, Windows, Linux)
#   swiftui/         native SwiftUI app (macOS only)
CROSS := cross_platform
SWIFTUI := swiftui

.PHONY: help all cross-platform swiftui run-cross-platform run-swiftui test-swiftui clean distclean

help:
	@echo "make cross-platform       build the cross_platform app for this OS (macOS .app; see cross_platform/Makefile)"
	@echo "make swiftui              build the SwiftUI .app (macOS only) into swiftui/dist/"
	@echo "make all                  build both (macOS only)"
	@echo "make run-cross-platform [REPO=/path]   run the cross_platform app"
	@echo "make run-swiftui [REPO=/path]          run the SwiftUI app"
	@echo "make test-swiftui         run the SwiftUI unit tests"
	@echo "make clean                remove build output from both"
	@echo "make distclean            clean, plus .venv/ and vendor/ in cross_platform"
	@echo
	@echo "Windows/Linux builds of cross_platform run in CI (.github/workflows/build.yml)."

all: cross-platform swiftui

cross-platform:
	$(MAKE) -C $(CROSS) app

swiftui:
	$(MAKE) -C $(SWIFTUI) app

run-cross-platform:
	$(MAKE) -C $(CROSS) run $(if $(REPO),REPO="$(REPO)")

run-swiftui:
	$(MAKE) -C $(SWIFTUI) run $(if $(REPO),REPO="$(REPO)")

test-swiftui:
	$(MAKE) -C $(SWIFTUI) test

clean:
	$(MAKE) -C $(CROSS) clean
	$(MAKE) -C $(SWIFTUI) clean

distclean:
	$(MAKE) -C $(CROSS) distclean
	$(MAKE) -C $(SWIFTUI) clean
