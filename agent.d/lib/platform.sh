# Prefer existing Homebrew tools on macOS, then retain the caller's/system PATH.
# Finding Homebrew does not install anything or change shell startup files.
ai_prefer_homebrew() {
  AI_HOMEBREW=""
  [ "$(uname -s)" = Darwin ] || return 0
  AI_HOMEBREW="$(command -v brew 2>/dev/null || true)"
  if [ -z "$AI_HOMEBREW" ]; then
    if [ -x /opt/homebrew/bin/brew ]; then AI_HOMEBREW=/opt/homebrew/bin/brew
    elif [ -x /usr/local/bin/brew ]; then AI_HOMEBREW=/usr/local/bin/brew
    fi
  fi
  local brew_prefix=""
  if [ -n "$AI_HOMEBREW" ]; then
    brew_prefix="$("$AI_HOMEBREW" --prefix 2>/dev/null)" || brew_prefix=""
    if [ -d "$brew_prefix/bin" ]; then
      case "$brew_prefix" in
        /*) export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH" ;;
      esac
    fi
  fi
}
