# pi-sbx

Run the [Pi coding agent](https://pi.dev) in a Docker sandbox, loosely based on
[the official containerization docs](https://pi.dev/docs/latest/containerization#run-pi-in-plain-docker).

## Install

```sh
make install
```

This symlinks `pi-sbx` into `~/.local/bin` (honors `PREFIX`). The
`pi-sandbox` image is built on demand the first time you run `pi-sbx` in a
new directory.

To build or rebuild it yourself (e.g. to pick up Dockerfile changes or a newer pi):

```sh
make build
```

Note existing sandboxes keep running their old image; `pi-sbx rm` the
sandbox and rerun to pick up a rebuilt image.

## Use

From the folder you want Pi to work in:

```sh
pi-sbx
```

This creates a persistent Docker container for the current directory (named
by a hash of its path). Run it again from the same folder and it restarts
(or execs into) the same container, so anything you installed or configured
inside it sticks around. If the container is already running (another
terminal), a new pi session is started inside it. That includes pi itself:
`pi update` works inside the sandbox, though it only updates that one
sandbox. Mounts and the image are fixed at container creation; to pick up
Dockerfile or host config changes, remove the sandbox and let it be recreated.

Your host `~/.pi/agent` is bind-mounted in, so the sandbox
shares your settings, extensions, `/login` credentials, and sessions. If a
Docker socket is present, it is mounted too, so `docker` commands run against
your host daemon.

### Extra volumes

Pass `-v`/`--volume` (repeatable) to bind-mount extra volumes into the
sandbox:

```sh
pi-sbx -v /data:/data -v ~/.cargo:/home/sbx/.cargo:ro
```

The value is passed verbatim to `docker run -v`. Mounts are fixed at
container creation, and the requested mounts are recorded on the container:
if you pass `-v` flags that don't match what the sandbox was created with,
`pi-sbx` refuses to run and tells you to `pi-sbx rm` first (or drop the
flags). A bare rerun without flags always works. User `-v` flags are added
after the built-in mounts, so a user mount can override one of them —
Docker applies the last matching mount. Note the delimiter: paths
containing `;` can't be recorded correctly.

The container can't reach the host clipboard, so the image sets
`PI_CLIPBOARD_OSC52=1`: copies in pi also emit an OSC 52 escape sequence the
host terminal applies. Requires an OSC-52-capable terminal (iTerm2, kitty,
WezTerm, Alacritty, ghostty, foot — not Terminal.app or GNOME Terminal).

Commands:

- `pi-sbx` — run (or rejoin) the sandbox for the current directory
- `pi-sbx ls` — list all sandboxes (name, state, path)
- `pi-sbx shell` — open an interactive shell inside this directory's sandbox
- `pi-sbx rm [-y|--force]` — delete this directory's sandbox (prompts
  unless `-y`; `~/.pi/agent` on the host is untouched, the image is kept)

## Homedir template

Optionally, seed the sandbox's home directory by placing files in
`~/.config/pi-sbx/home-template/` on the host — ssh keys, agent skills,
dotfiles, and so on. Everything there is copied into the container's
`$HOME` when it's first created. Each file is copied only if it doesn't
already exist (existing directories like `~/.ssh` are merged), and file
modes are preserved, so ssh key permissions carry over. For example:

```
~/.config/pi-sbx/home-template/
  .gitconfig
  .ssh/
    config
    id_ed25519
  .agents/skills/...
```

Copies happen only at first start, so container-local edits stick around
across restarts.

## Image

The image ships Node 24 (Pi included), Python 3 with pip, uv, and Poetry,
build-essential, Go, Rust, git, gh, glab, docker CLI, ripgrep, fd, and common
CLI utilities.

Agent skills and other home-directory bits come from the homedir template
described above, not from the image.

## Uninstall

```sh
make uninstall      # removes the ~/.local/bin/pi-sbx symlink
pi-sbx ls           # remove any remaining sandboxes with: pi-sbx rm
docker rmi pi-sandbox
```
