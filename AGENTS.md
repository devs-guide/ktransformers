# Repository guidance

- Private feature plans live in the separate `./prompt` workspace and are not committed here.
- Implement one roadmap feature at a time and keep status claims evidence-based.
- Never add model files, download behavior, Hugging Face credentials, or generated `static/` output.
- Edit `www/` as the Pages source; `static/` is generated for publication.
- Do not run repository validation or target tooling on macOS; GitHub Actions
  validates source and published tooling executes only on an operator-selected target.
- AVX-512 and AVX-512 VNNI are the only universal compute requirements. Treat
  PMem, memory reserves, and every NVIDIA property as discovered or operator-selected.
- Merge, Pages publication, tags, releases, and branch deletion are separate operations.
