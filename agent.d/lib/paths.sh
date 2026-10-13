# Portable path resolution for installer ownership checks. Bash 3.2+, no GNU
# readlink flags or Python dependency. Missing final components are supported.
ai_realpath() {
  local remaining="$1" resolved=/ part target links=0
  case "$remaining" in /*) ;; *) remaining="$PWD/$remaining" ;; esac
  remaining="${remaining#/}"
  while [ -n "$remaining" ]; do
    part="${remaining%%/*}"
    if [ "$remaining" = "$part" ]; then remaining=""; else remaining="${remaining#*/}"; fi
    case "$part" in
      ''|.) continue ;;
      ..) resolved="${resolved%/*}"; resolved="${resolved:-/}"; continue ;;
    esac
    if [ -L "${resolved%/}/$part" ]; then
      links=$((links + 1))
      [ "$links" -le 40 ] || return 1
      target="$(readlink "${resolved%/}/$part")" || return 1
      case "$target" in /*) resolved=/; target="${target#/}" ;; esac
      remaining="$target${remaining:+/$remaining}"
    else
      resolved="${resolved%/}/$part"
    fi
  done
  printf '%s\n' "$resolved"
}
