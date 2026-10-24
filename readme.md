# devs-guide/ktransformers

Standalone tooling for reproducible CPU, Intel PMem Memory Mode, and multi-GPU
LLM inference with pinned llama.cpp and KTransformers/SGLang-KT profiles.

> This community project is not affiliated with or endorsed by the upstream
> KTransformers, llama.cpp, Qwen, Hugging Face, Intel, or NVIDIA projects.

## Current status

Release `0.0.1` establishes the repository and documentation workflow only.
Runtime installation and model execution remain planned for `0.1.0`.

The implementation roadmap is:

1. target-host readiness;
2. URL-only model references and read-only local inventory;
3. pinned llama.cpp v0.7.0 runtime;
4. pinned KTransformers v0.7.2 and SGLang-KT runtime;
5. llama.cpp MoE acceptance;
6. KTransformers MoE acceptance;
7. functional `0.1.0` release.

## Model boundary

This repository never distributes or downloads models. Models are provisioned
externally by the operator and remain outside the source checkout. Project
commands may accept an existing local path and record read-only facts about it.

The planned model references are documented at
[devs-guide.github.io/ktransformers/models/](https://devs-guide.github.io/ktransformers/models/).

## Documentation

- [Project site](https://devs-guide.github.io/ktransformers/)
- [Feature roadmap](https://devs-guide.github.io/ktransformers/features/)
- [Model references](https://devs-guide.github.io/ktransformers/models/)
- [Release notes](docs/releases/0.0.1.md)

## License

Project-authored source and documentation are licensed under Apache-2.0.
Linked models and upstream runtimes retain their respective licenses.

