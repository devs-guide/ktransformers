# devs-guide/ktransformers

Standalone tooling for reproducible CPU inference with optional PMem-aware and
NVIDIA-accelerated profiles for pinned llama.cpp and KTransformers/SGLang-KT.

> This community project is not affiliated with or endorsed by the upstream
> KTransformers, llama.cpp, Qwen, Hugging Face, Intel, or NVIDIA projects.

## Current status

Release `0.0.1` establishes the repository and documentation workflow. The
`0.0.2` candidate adds published human-smoke tooling; `0.1.0` remains the full
dual-runtime and MoE milestone.

The implementation roadmap is:

1. commit-verifiable Pages runners and target access;
2. AVX-512/VNNI host readiness;
3. URL-only model references and read-only local inventory;
4. pinned llama.cpp v0.7.0 CPU smoke and optional NVIDIA acceleration;
5. source-only `0.0.2` release;
6. KTransformers, large-model, and MoE acceptance for `0.1.0`.

AVX-512 and AVX-512 VNNI are the only universal compute requirements. PMem,
memory reserves, and all GPU properties are discovered or explicitly selected
by the operator.

## Model boundary

This repository never acquires, converts, quarantines, promotes, stores, or
distributes models. Models are provisioned externally by the operator and
remain outside the source checkout. Project commands accept an existing local
path and record read-only facts about it.

The model references are documented at
[devs-guide.github.io/ktransformers/models/](https://devs-guide.github.io/ktransformers/models/).

## Documentation

- [Project site](https://devs-guide.github.io/ktransformers/)
- [Feature roadmap](https://devs-guide.github.io/ktransformers/features/)
- [Model references](https://devs-guide.github.io/ktransformers/models/)
- [Published target workflow](docs/operator.md)
- [0.0.1 release notes](docs/releases/0.0.1.md)
- [0.0.2 candidate notes](docs/releases/0.0.2.md)

## License

Project-authored source and documentation are licensed under Apache-2.0.
Linked models and upstream runtimes retain their respective licenses.
