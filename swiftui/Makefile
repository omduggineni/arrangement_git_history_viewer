# make run REPO=/path     build + run (debug)
# make test               unit tests (set SAMPLE_A/SAMPLE_B to two .mscz files for the real diff pipeline)
# make e2e SAMPLE=...     drive the real window and write screenshots
# make sidecar            freeze the Python diff engine (PyInstaller) into build/sidecar/dist
# make app                -> dist/Arrangement Diff Viewer.app (ad-hoc signed, includes the frozen engine)
# make app-with-bundled-musescore     like `make app`, plus the latest MuseScore (downloaded) bundled inside, so nothing needs installing
APP := dist/Arrangement Diff Viewer.app

.PHONY: run test e2e app app-with-bundled-musescore musescore sidecar clean
FREEZE := build/sidecar
PYTHON3 ?= python3
run:
	swift run ArrangementDiffViewer $(if $(REPO),--repo "$(REPO)")

test:
	ADV_SAMPLE_A="$(SAMPLE_A)" ADV_SAMPLE_B="$(SAMPLE_B)" swift test

# e.g. make e2e REPO=/path/to/repo STEPS="file:song.mscz,tab:history,commit:0,settings" OUT=/tmp/shots
e2e:
	swift build
	ADV_E2E_OUT="$(or $(OUT),/tmp/adv-e2e)" ADV_E2E_STEPS="$(STEPS)" \
		$$(swift build --show-bin-path)/ArrangementDiffViewer --repo "$(REPO)"

# Fresh venv with the diff engine's dependencies + PyInstaller, then freeze sidecar/diff_sidecar.py.
$(FREEZE)/dist/diff_sidecar/diff_sidecar: sidecar/diff_sidecar.py packaging/sidecar.spec
	$(PYTHON3) -m venv $(FREEZE)/venv
	$(FREEZE)/venv/bin/pip install -q pyinstaller "musicdiff>=6.0" "music21>=9.1" converter21 verovio
	cd packaging && ../$(FREEZE)/venv/bin/pyinstaller sidecar.spec --noconfirm --distpath ../$(FREEZE)/dist --workpath ../$(FREEZE)/work

sidecar: $(FREEZE)/dist/diff_sidecar/diff_sidecar

app: sidecar
	swift build -c release
	packaging/bundle.sh "$(APP)" $(FREEZE)/dist

# Latest MuseScore release from GitHub, cached in build/musescore (REFRESH=1 to download again).
musescore:
	packaging/fetch_musescore.sh build/musescore

app-with-bundled-musescore: sidecar musescore
	swift build -c release
	MUSESCORE_APP="$(CURDIR)/build/musescore/MuseScore.app" packaging/bundle.sh "$(APP)" $(FREEZE)/dist

clean:
	rm -rf .build dist
