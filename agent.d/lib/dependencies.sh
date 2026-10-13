# Called after destination/conflict checks and before replacing the payload.
# Existing tools are reused; Homebrew itself is never bootstrapped.
ai_install_direnv() {
  local direnv_version manager="" candidate
  local elevate=()
  if ! command -v direnv >/dev/null 2>&1; then
    head_ "Installing direnv"
    if [ "$platform" = Darwin ]; then
      if [ -z "${AI_HOMEBREW:-}" ]; then
        die "direnv was not found in Homebrew or on your system PATH.
       Install Homebrew (https://brew.sh), then run: brew install direnv
       Or install direnv manually (https://direnv.net/docs/installation.html),
       add it to PATH, and re-run this installer. Homebrew is not installed automatically."
      fi
      "$AI_HOMEBREW" install direnv || die "Homebrew could not install direnv. Resolve the error above and re-run the installer."
      ai_prefer_homebrew
    else
      for candidate in apt-get dnf yum pacman zypper apk; do
        if command -v "$candidate" >/dev/null 2>&1; then
          manager="$candidate"
          break
        fi
      done
      [ -n "$manager" ] || die "direnv is missing and no supported system package manager was found.
       Install direnv (https://direnv.net/docs/installation.html), add it to PATH,
       then re-run this installer. Supported Linux managers: apt-get, dnf, yum, pacman, zypper, apk."
      if [ "$EUID" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "Installing direnv with $manager requires root or sudo.
       Install direnv with your administrator's package manager, then re-run this installer as your normal user."
        elevate=(sudo)
        [ "$interactive" -eq 1 ] || elevate+=(-n)
      fi
      say "  Using $manager to install direnv."
      case "$manager" in
        apt-get)
          "${elevate[@]+"${elevate[@]}"}" apt-get update \
            || die "Could not refresh apt metadata for direnv. Check permissions/network access and re-run the installer."
          "${elevate[@]+"${elevate[@]}"}" apt-get install -y direnv \
            || die "Could not install direnv with apt-get. Install it manually, then re-run the installer."
          ;;
        dnf|yum)
          "${elevate[@]+"${elevate[@]}"}" "$manager" install -y direnv \
            || die "Could not install direnv with $manager. Install it manually, then re-run the installer."
          ;;
        pacman)
          "${elevate[@]+"${elevate[@]}"}" pacman -S --needed --noconfirm direnv \
            || die "Could not install direnv with pacman. Install it manually, then re-run the installer."
          ;;
        zypper)
          "${elevate[@]+"${elevate[@]}"}" zypper --non-interactive install direnv \
            || die "Could not install direnv with zypper. Install it manually, then re-run the installer."
          ;;
        apk)
          "${elevate[@]+"${elevate[@]}"}" apk add direnv \
            || die "Could not install direnv with apk. Install it manually, then re-run the installer."
          ;;
      esac
    fi
    hash -r
  fi

  command -v direnv >/dev/null 2>&1 || die "direnv installation finished but the command is not on PATH. Add it to PATH and re-run the installer."
  direnv_version="$(direnv version 2>/dev/null)" \
    || die "direnv exists but could not run. Repair its installation and re-run the installer."
  [ -n "$direnv_version" ] || die "direnv returned no version. Repair its installation and re-run the installer."
  # status --json, used to propagate only existing trust, arrived in 2.33.0.
  [[ "$direnv_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] \
    || die "Could not understand direnv version '$direnv_version'. Install direnv 2.33.0 or newer."
  if [ "${BASH_REMATCH[1]}" -lt 2 ] || \
     { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -lt 33 ]; }; then
    die "direnv 2.33.0+ is required for status --json (found $direnv_version).
       Upgrade direnv with your package manager (on macOS: brew upgrade direnv),
       or install a current release from https://direnv.net/docs/installation.html,
       then re-run the installer. The existing ai-kit payload has not been replaced."
  fi
  ok "direnv $direnv_version (project environments enabled on Linux and macOS)"
}
