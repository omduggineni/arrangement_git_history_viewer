VENV := .venv
PYTHON := $(VENV)/bin/python3
PIP := $(VENV)/bin/pip
APP_NAME := Arrangement Diff Viewer

.PHONY: help venv git run run-web app clean distclean

help:
	@echo "make venv       create .venv and install the project (incl. build deps)"
	@echo "make git        download the portable git that gets bundled (into vendor/git)"
	@echo "make run        run the native app window (no --repo: shows a folder picker)"
	@echo "make run REPO=/path/to/repo   run against a specific repo, still native"
	@echo "make run-web    run as an ordinary local web server (for development)"
	@echo "make app        build '$(APP_NAME).app' into dist/ via PyInstaller"
	@echo "make clean      remove PyInstaller's build/ and dist/ output"
	@echo "make distclean  clean, plus remove .venv and vendor/"

$(PYTHON):
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -e ".[build]"

venv: $(PYTHON)

git: venv
	$(PYTHON) packaging/fetch_git.py

run: venv git
	$(PYTHON) -m app.main $(if $(REPO),--repo "$(REPO)")

run-web: venv git
	$(PYTHON) -m app.main --web $(if $(REPO),--repo "$(REPO)")

app: venv
	$(PYTHON) -m PyInstaller packaging/arrangement_diff_viewer.spec --noconfirm --clean
	@echo
	@echo "Built: dist/$(APP_NAME).app"

clean:
	rm -rf build dist

distclean: clean
	rm -rf $(VENV) vendor
