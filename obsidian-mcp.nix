{
  rustPlatform,
  fetchFromHuggingFace,
  runCommand,
  onnxruntime,
  makeWrapper,
  sources,
}:
let
  # Pre-fetched HuggingFace Hub cache for the pre-packaged local embedding
  # model, `snowflake/snowflake-arctic-embed-s` — a built-in fastembed preset
  # (`EmbeddingModel::SnowflakeArcticEmbedS`), loaded via the plain
  # hf-hub-backed `TextEmbedding::try_new` path (no
  # `try_new_from_user_defined`/external-data detour needed: this is a
  # standard BERT-family bi-encoder with a single `onnx/model.onnx`, no
  # companion `.onnx_data` file).
  #
  # Casing gotcha: fastembed's own model table gives this variant's
  # `model_code` as lowercase `"snowflake/snowflake-arctic-embed-s"`, while
  # hf-hub's cache folder name is a direct string transform of that exact
  # `model_code` ("models--" + repo_id with "/" -> "--"). `fetchFromHuggingFace`
  # below uses the canonical capitalized HF repo id, but the on-disk cache
  # directory is deliberately lowercase `models--snowflake--snowflake-arctic-embed-s`
  # to match what `hf_hub::Repo::folder_name()` computes from fastembed's
  # model_code at runtime.
  snowflakeArcticEmbedSModelCache =
    let
      # Resolved from https://huggingface.co/api/models/snowflake/snowflake-arctic-embed-s/revision/main
      rev = "e596f507467533e48a2e17c007f0e1dacc837b33";
      repoDir = "models--snowflake--snowflake-arctic-embed-s";
      # One git+lfs clone of the whole revision instead of hand-picking and
      # hashing individual files. HF's Xet backend isn't supported by
      # nixpkgs' fetcher yet (backend = "lfs" is required), and sparse
      # checkout isn't compatible with HF's git-lfs promisor remote either,
      # so this pulls every onnx export variant in the repo (~530MiB)
      # instead of just the one `onnx/model.onnx` we use.
      repo = fetchFromHuggingFace {
        repoId = "Snowflake/snowflake-arctic-embed-s";
        inherit rev;
        backend = "lfs";
        hash = "sha256-3taUrx/EDHj9PEemysXgTvKpGblTRb2cVLRZiJfJeu0=";
      };
    in
    runCommand "snowflake-arctic-embed-s-hf-cache" { } ''
      snap="$out/${repoDir}/snapshots/${rev}"
      mkdir -p "$(dirname "$snap")"
      ln -s ${repo} "$snap"
      mkdir -p "$out/${repoDir}/refs"
      # No trailing newline: hf-hub uses this file's raw contents
      # verbatim as the snapshot directory name.
      printf '%s' "${rev}" > "$out/${repoDir}/refs/main"
    '';
in
rustPlatform.buildRustPackage {
  pname = "obsidian-mcp";
  version = "3.1.0";

  src = sources.obsidian-mcp;

  cargoLock = {
    lockFile = sources.obsidian-mcp + "/Cargo.lock";
  };

  nativeBuildInputs = [
    # Wraps the built binary to default it onto the pre-fetched
    # Snowflake Arctic Embed S model below.
    makeWrapper
  ];

  buildInputs = [
    onnxruntime
  ];

  buildFeatures = [ "embeddings" ];
  buildNoDefaultFeatures = false;

  # Only build the MCP server binary; obsidian-semanticd (the optional
  # shared-index daemon) is not needed for a single stdio client.
  buildAndTestSubdir = null;
  cargoBuildFlags = [
    "--bin"
    "obsidian-mcp"
  ];

  # Tests reach into the network (model downloads) / are not needed for
  # producing the binary.
  doCheck = false;

  env = {
    ORT_LIB_LOCATION = "${onnxruntime}/lib";
    ORT_PREFER_DYNAMIC_LINK = "1";
  };

  # Default (not force-override) the local embedding model's cache dir at
  # the pre-fetched, network-free HuggingFace cache assembled above, and
  # select that model by default.
  #
  # OBSIDIAN_EMBEDDINGS_MODEL is set to the exact fastembed enum name
  # `SnowflakeArcticEmbedS`, not the repo string
  # `snowflake/snowflake-arctic-embed-s`: `SnowflakeArcticEmbedS` and
  # `SnowflakeArcticEmbedSQ` share the identical `model_code`, so the
  # repo-string form is ambiguous ("ambiguous local embedding model" at
  # runtime) — the bare enum name matches unambiguously.
  postFixup = ''
    wrapProgram $out/bin/obsidian-mcp \
      --set-default FASTEMBED_CACHE_DIR "${snowflakeArcticEmbedSModelCache}" \
      --set-default OBSIDIAN_EMBEDDINGS_MODEL "SnowflakeArcticEmbedS" \
      --set-default HF_HUB_OFFLINE "1"
  '';

  meta = {
    description = "MCP server for Obsidian vaults — direct filesystem access for AI agents, built with local embeddings";
    mainProgram = "obsidian-mcp";
  };
}
