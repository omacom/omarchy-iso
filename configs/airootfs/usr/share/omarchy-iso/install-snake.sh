# Sourced by the dashboard. Static path only; never generate artwork at install.
SNAKE_LENGTH=1
SNAKE_ENABLED=0
SNAKE_FLASH=0
SNAKE_PATH_FILE="${OMARCHY_SNAKE_PATH:-/usr/share/omarchy-iso/install-snake.path}"
declare -a SNAKE_ORDER=() SNAKE_ROWS=() SNAKE_CELL_ROW=()
SNAKE_DRAWN=0
SNAKE_DRAW_KEY=""
SNAKE_PREV_FLASH=0

snake_init() {
  local r c index=0
  [[ -r $SNAKE_PATH_FILE ]] || return 0
  while read -r r c; do
    [[ $r =~ ^[0-9]+$ && $c =~ ^[0-9]+$ ]] || return 0
    (( r < 30 && c < 30 )) || return 0
    [[ -z ${SNAKE_ORDER[r * 30 + c]:-} ]] || return 0
    index=$((index + 1))
    SNAKE_ORDER[r * 30 + c]=$index
    SNAKE_CELL_ROW[index]=$((r / 2))
  done <"$SNAKE_PATH_FILE"
  (( index == 380 )) || return 0

  # Linux VT: check the actual loaded Unicode map, not the developer's font.
  # Unknown or missing glyphs retain the existing wordmark/bar display.
  if [[ ${TERM:-} == linux ]]; then
    local mappings glyph
    mappings=$(getunimap 2>/dev/null) || return 0
    for glyph in 2580 2584 2588; do
      [[ ${mappings^^} == *"U+$glyph"* ]] || return 0
    done
  elif [[ ${TERM:-dumb} == dumb || ${TERM:-} == vt100 ]]; then
    return 0
  fi
  [[ $(locale charmap 2>/dev/null) == UTF-8 ]] || return 0
  SNAKE_ENABLED=1
}

snake_advance() {
  local target=$((1 + PROGRESS_PM * 379 / 1000))
  # One call per >=100ms: <=60 cells/sec. Catch up to work, never predict it.
  (( target > SNAKE_LENGTH + 6 )) && target=$((SNAKE_LENGTH + 6))
  (( target > SNAKE_LENGTH )) && SNAKE_LENGTH=$target
  return 0
}

snake_render() {
  local r c top bottom a b row head=$SNAKE_LENGTH col key i
  local -a dirty=()
  local green="$GREEN" white="$WHITE" reset="$RESET"
  (( SNAKE_FLASH )) && green="$WHITE"
  # A stalled head blinks without changing the body length or claiming work.
  (( SNAKE_LENGTH < 380 && NOW % 2 )) && head=-1
  col=$(( ($(term_cols) - 30) / 2 + 1 ))
  key="$SNAKE_LENGTH|$head|$SNAKE_FLASH|$TOP_ROW|$col"
  [[ $key != "$SNAKE_DRAW_KEY" || ${#SNAKE_ROWS[@]} == 0 ]] || return 0
  if (( ${#SNAKE_ROWS[@]} == 0 || SNAKE_FLASH != SNAKE_PREV_FLASH || SNAKE_DRAWN > SNAKE_LENGTH )); then
    for ((r=0; r<15; r++)); do dirty[r]=1; done
  else
    # Only the old/new head rows and rows receiving new cells can change.
    (( SNAKE_DRAWN == 0 )) || dirty[${SNAKE_CELL_ROW[SNAKE_DRAWN]}]=1
    dirty[${SNAKE_CELL_ROW[SNAKE_LENGTH]}]=1
    for ((i=SNAKE_DRAWN+1; i<=SNAKE_LENGTH; i++)); do
      dirty[${SNAKE_CELL_ROW[i]}]=1
    done
  fi
  for ((r=0; r<15; r++)); do
    [[ ${dirty[r]:-0} == 1 ]] || continue
    row=""
    for ((c=0; c<30; c++)); do
      a=${SNAKE_ORDER[r * 60 + c]:-0}
      b=${SNAKE_ORDER[r * 60 + 30 + c]:-0}
      top=0 bottom=0
      (( a > 0 && a <= SNAKE_LENGTH )) && top=1
      (( b > 0 && b <= SNAKE_LENGTH )) && bottom=1
      if (( SNAKE_LENGTH < 380 )); then
        (( a == SNAKE_LENGTH && head == -1 )) && top=0
        (( b == SNAKE_LENGTH && head == -1 )) && bottom=0
      fi
      if (( top && bottom )); then
        if [[ -z ${NO_COLOR:-} ]] && (( SNAKE_LENGTH < 380 && (a == head || b == head) )); then
          if (( a == head )); then row+="${CSI}37;42m▀${reset}"
          else row+="${CSI}32;47m▀${reset}"; fi
        else row+="${green}█${reset}"; fi
      elif (( top )); then
        if (( a == head && SNAKE_LENGTH < 380 )); then row+="${white}▀${reset}"
        else row+="${green}▀${reset}"; fi
      elif (( bottom )); then
        if (( b == head && SNAKE_LENGTH < 380 )); then row+="${white}▄${reset}"
        else row+="${green}▄${reset}"; fi
      else row+=" "; fi
    done
    if [[ ${SNAKE_ROWS[r]:-} != "$row" ]]; then
      printf '%s%d;%dH%s' "$CSI" "$((TOP_ROW + r))" "$col" "$row"
      SNAKE_ROWS[r]="$row"
    fi
  done
  SNAKE_DRAWN=$SNAKE_LENGTH
  SNAKE_DRAW_KEY=$key
  SNAKE_PREV_FLASH=$SNAKE_FLASH
  return 0
}
