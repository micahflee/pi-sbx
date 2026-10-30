#!/usr/bin/env bash
# Launch the Pi sandbox in the current directory. Creates a persistent
# container per directory (or execs into / restarts the existing one).
# Subcommands: ls (list sandboxes), shell (open a shell in this directory's sandbox),
# rm (delete this directory's sandbox).
#
# Extra volumes are fixed at container creation, like all mounts. They are
# recorded in the pi-sbx.mounts label; if you pass -v flags that don't match
# an existing container's label, pi-sbx refuses to run and tells you to
# 'pi-sbx rm' first. User -v flags are appended after the built-in mounts,
# so they override them (Docker: last mount wins).

set -euo pipefail

usage() {
  cat <<'EOF'
usage: pi-sbx [-v <host:container[:opts]>]... [ls | shell | rm [-y|--force]]

Run the Pi coding agent in a persistent Docker sandbox for the current
directory. Rerun from the same folder to restart (or exec into) the same
container.

Options:
  -v, --volume <host:container[:opts]>  Bind-mount an extra volume at
        creation time (repeatable, passed verbatim to docker run -v).
        Last mount wins: a user -v can override a built-in mount.
  -h, --help  Show this help.

Subcommands:
  ls     List sandboxes.
  shell  Open a shell in this directory's sandbox.
  rm     Delete this directory's sandbox (-y/--force to skip confirm).

Examples:
  pi-sbx
  pi-sbx -v /data:/data -v ~/.cargo:/home/sbx/.cargo
  pi-sbx shell

EOF
}

volumes=()
subcommand=run

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--volume)
      if [ $# -lt 2 ] || [[ "$2" == -* ]]; then
        echo "pi-sbx: $1 requires a <host:container[:opts]> argument" >&2
        exit 2
      fi
      volumes+=("$2")
      shift 2
      ;;
    -* )
      echo "pi-sbx: unknown option: $1" >&2
      echo "usage: pi-sbx [-v <host:container[:opts]>]... [ls | shell | rm [-y|--force]]" >&2
      exit 2
      ;;
    *)
      subcommand="$1"
      shift
      break
      ;;
  esac
done

if [ "${#volumes[@]}" -gt 0 ] && [ "$subcommand" != "run" ]; then
  echo "pi-sbx: -v/--volume only applies to creating a sandbox, not '$subcommand'" >&2
  exit 2
fi

# Resolve this script through the ~/.local/bin/pi-sbx symlink to find the
# Dockerfile committed next to it.
script="$0"
while [ -L "$script" ]; do
  target=$(readlink "$script")
  case "$target" in
    /*) script="$target" ;;
    *) script="$(dirname "$script")/$target" ;;
  esac
done
repo_dir=$(cd "$(dirname "$script")" && pwd -P)

agent_dir="$HOME/.pi/agent"
check_agent_dir() {
  if [ ! -d "$agent_dir" ]; then
    echo "pi-sbx: $agent_dir does not exist." >&2
    echo "Start pi on the host first so it creates your agent directory" >&2
    echo "(settings, extensions, logins), or mkdir -p it yourself." >&2
    echo "Docker would otherwise create it as root." >&2
    exit 1
  fi
}

cwd=$(pwd -P)
if command -v sha256sum >/dev/null 2>&1; then
  name="pi-sbx-$(printf '%s' "$cwd" | sha256sum | cut -c1-12)"
else
  # macOS ships `shasum` instead of GNU coreutils `sha256sum`
  name="pi-sbx-$(printf '%s' "$cwd" | shasum -a 256 | cut -c1-12)"
fi

mounts_label=""
if [ "${#volumes[@]}" -gt 0 ]; then
  mounts_label=$(printf '%s;' "${volumes[@]}")
fi

case "$subcommand" in
  ls)
    docker ps -a --filter label=pi-sbx \
      --format '{{.Names}}\t{{.State}}\t{{.Label "pi-sbx.path"}}' |
      while IFS=$'\t' read -r n s p; do
        printf '%s  %s  %s\n' "$n" "$s" "$p"
      done
    exit 0
    ;;

  rm)
    force=0
    for arg in "$@"; do
      case "$arg" in
        -y|--force) force=1 ;;
        *) echo "usage: pi-sbx rm [-y|--force]" >&2; exit 2 ;;
      esac
    done
    if ! docker container inspect "$name" >/dev/null 2>&1; then
      echo "pi-sbx: no sandbox for $cwd" >&2
      exit 1
    fi
    if [ "$force" -ne 1 ]; then
      running=$(docker container inspect -f '{{.State.Running}}' "$name")
      if [ "$running" = "true" ]; then
        echo "pi-sbx: container $name is currently running and will be killed."
      fi
      read -r -p "Are you sure? [y/N] " reply
      case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 1 ;;
      esac
    fi
    docker rm -f "$name"
    echo "Removed $name (the pi-sandbox image is kept)."
    exit 0
    ;;

  shell)
    if ! docker container inspect "$name" >/dev/null 2>&1; then
      echo "pi-sbx: no sandbox for $cwd (run 'pi-sbx' first)" >&2
      exit 1
    fi
    running=$(docker container inspect -f '{{.State.Running}}' "$name")
    if [ "$running" != "true" ]; then
      docker start "$name" >/dev/null
    fi
    exec docker exec -it "$name" bash
    ;;

  run)
    check_agent_dir
    if docker container inspect "$name" >/dev/null 2>&1; then
      if [ "${#volumes[@]}" -gt 0 ]; then
        existing_mounts=$(docker container inspect -f '{{index .Config.Labels "pi-sbx.mounts"}}' "$name")
        if [ "$existing_mounts" != "$mounts_label" ]; then
          echo "pi-sbx: sandbox $name was created with different mounts:" >&2
          echo "  existing: ${existing_mounts%;}" >&2
          echo "  requested: ${mounts_label%;}" >&2
          echo "Mounts are fixed at container creation. Run 'pi-sbx rm' and" >&2
          echo "rerun with the mounts you want, or drop the -v flags." >&2
          exit 1
        fi
      fi
      running=$(docker container inspect -f '{{.State.Running}}' "$name")
      if [ "$running" = "true" ]; then
        exec docker exec -it "$name" pi
      fi
      exec docker start -ai "$name"
    fi

    docker build -t pi-sandbox "$repo_dir"

    run_args=(
      --name "$name"
      --label pi-sbx
      --label "pi-sbx.path=$cwd"
      --user "$(id -u):$(id -g)"
      -v "$cwd:$cwd"
      -w "$cwd"
      -v "$agent_dir:/home/sbx/.pi/agent"
      --label "pi-sbx.mounts=$mounts_label"
    )
    home_template="$HOME/.config/pi-sbx/home-template"
    if [ -d "$home_template" ]; then
      # Everything in ~/.config/pi-sbx/home-template (ssh keys, agent
      # skills, dotfiles, ...) is staged read-only at ~/.home-template;
      # the entrypoint copies it into $HOME at startup.
      run_args+=(-v "$home_template:/home/sbx/.home-template:ro")
    fi

    if [ -e /var/run/docker.sock ]; then
      # BSD stat (macOS) uses -f, GNU stat (Linux) uses -c
      if [ "$(uname)" = "Darwin" ]; then
        sock_gid=$(stat -f %g /var/run/docker.sock)
      else
        sock_gid=$(stat -c %g /var/run/docker.sock)
      fi
      run_args+=(
        -v /var/run/docker.sock:/var/run/docker.sock
        --group-add "$sock_gid"
      )
    fi

    # User mounts go last: Docker applies the last matching mount.
    for vol in "${volumes[@]}"; do
      run_args+=(-v "$vol")
    done

    exec docker run -it "${run_args[@]}" pi-sandbox
    ;;

  *)
    echo "usage: pi-sbx [-v <host:container[:opts]>]... [ls | shell | rm [-y|--force]]" >&2
    exit 2
    ;;
esac
