"""PyInstaller entry point. `python -m app.main` is used for normal/dev runs;
PyInstaller needs an actual script file to analyze, hence this thin wrapper."""

import multiprocessing

if __name__ == "__main__":
    # Required for a frozen app: multiprocessing re-invokes the packaged
    # executable itself for worker processes (e.g. NiceGUI's cpu_bound pool,
    # or multiprocessing's own resource_tracker), passing bootstrap arguments
    # that our own argparse doesn't understand. freeze_support() intercepts
    # that re-invocation and handles it before any of our code runs.
    multiprocessing.freeze_support()

    from app.main import run_app

    run_app()
