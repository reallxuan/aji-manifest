# aji-manifest

Engine, network and runtime manifest for [Aji](https://github.com/reallxuan/Aji), a KataGo GUI. This repository also builds the self-contained KataGo Metal binary that the manifest points to on macOS.

## What is published

- Manifest: <https://reallxuan.github.io/aji-manifest/v1/manifest.json>
- Signature (minisign, detached): <https://reallxuan.github.io/aji-manifest/v1/manifest.json.minisig>
- KataGo Metal builds: the GitHub releases of this repository, named `katago-<tag>-metal`.

Aji checks the signature against the public key in `keys/aji-manifest.pub` (compiled into the app) before it trusts a downloaded manifest.

## Licences and what is not hosted

- The Metal builds are unmodified KataGo, built from source by `scripts/build-katago-metal.sh` and distributed under KataGo's licence. Each zip carries `LICENSE` and `THIRD-PARTY-LICENSES.txt`.
- NVIDIA files (CUDA, cuBLAS, cuDNN, NVRTC) are never hosted here. The manifest only links to NVIDIA's own download servers and records NVIDIA's checksums.
- The neural networks come from katagotraining.org. Their licence: <https://katagotraining.org/network_license/>.

## Running the workflows

Both workflows start from the Actions tab (`workflow_dispatch`), or from the command line:

```bash
# Build KataGo with Metal and publish the release katago-<tag>-metal
gh workflow run katago-metal.yml -R reallxuan/aji-manifest -f tag=v1.18.2

# Build the manifest tool from Aji, generate and sign the manifest, publish it to GitHub Pages
gh workflow run manifest.yml -R reallxuan/aji-manifest -f aji_ref=main
```

The Metal workflow refuses to run when the release for that tag already exists. The manifest workflow needs the repository secret `MINISIGN_SECRET_KEY` and GitHub Pages set to deploy from GitHub Actions.

## Key rotation

1. Add the new public key to Aji's list of trusted keys, alongside the old one.
2. Release that Aji version and let users update.
3. Replace the secret `MINISIGN_SECRET_KEY` and `keys/aji-manifest.pub` with the new pair.
