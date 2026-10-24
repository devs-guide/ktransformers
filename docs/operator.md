# Published target workflow

GitHub Actions validates the repository and publishes a closure whose manifest
binds every target runner to an exact source commit. The local checkout only
dispatches SSH; setup, builds, inventory, and smoke run on the selected Linux
target.

Set the target and the exact SHA reported by Pages locally. Do not commit either
the target identity or operator-selected paths and limits.

```bash
export KTRANSFORMERS_TARGET='USER@TARGET'
export KTRANSFORMERS_SOURCE_SHA='EXACT_40_CHARACTER_SHA'
actions/target.sh -- setup/host.sh preflight
```

The dispatcher always allocates a TTY so sudo remains interactive. Use
`setup/access.sh` once as root to transfer one already-authorized public key by
fingerprint to an explicitly selected runtime owner. No private key is read.

The normal acceptance order is:

1. access `preflight`, `apply`, and `validate`;
2. host `preflight`, `apply`, and `validate`;
3. model `preflight`/`validate` against an externally provisioned absolute path;
4. llama.cpp `preflight`, `apply`, and `validate` for the CPU profile;
5. llama.cpp smoke `preflight`, `run`, and `validate` for CPU;
6. optionally repeat runtime and smoke for NVIDIA, with explicit power restore.

The model runner accepts only an HTTPS Hugging Face repository reference plus a
local path; it has no acquisition mode. Runtime source acquisition is separate,
explicit, and limited to the pinned official llama.cpp source.
