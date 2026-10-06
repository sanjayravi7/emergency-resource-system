# ERAS GitHub Repository Cleanup

The production tag `v1.0.0-production` is already created and pushed. Presentation/docs changes should be a separate normal commit on `main`; do not move or recreate the production tag.

## Safe cleanup

The repository currently contains generated Flutter build leftovers and an inspection/probe directory that do not belong in the presentation surface.

Run from the repository root:

```bash
git rm -r .probe
git rm -r frontend/emergency_app/build
```

Add these ignore rules if they are not already present:

```gitignore
**/build/
**/eras_log.txt
```

Optionally remove the local log file after confirming you do not need it:

```bash
rm -f frontend/emergency_app/eras_log.txt
```

Then stage only the intended presentation changes:

```bash
git add README.md docs/ .gitignore

git status
git diff --cached --stat
git commit -m "docs: prepare ERAS for production presentation"
git push origin main
```

## Do not delete automatically

The root-level PPTX/DOCX files and historical engineering reports may be required for the academic/project record. Review them before removing or moving them.
