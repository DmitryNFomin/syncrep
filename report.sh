#!/usr/bin/env bash
# report.sh — Generate an added-latency report from syncrep benchmark result files.
#
# Usage:
#   bash report.sh [RESULTS_DIR]
#   RESULTS_DIR=./results bash report.sh
#
# Reads:  $RESULTS_DIR/s{N}_remote_write.log  and  s{N}_remote_apply.log
# Output: formatted report to stdout

set -euo pipefail

# Auto-source syncrep.conf for RESULTS_DIR if not already set.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${RESULTS_DIR:-}" && -f "$SCRIPT_DIR/syncrep.conf" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/syncrep.conf"
fi

# ── argument / defaults ───────────────────────────────────────────────────────
RESULTS_DIR="${1:-${RESULTS_DIR:-/tmp/syncrep_results}}"

# ── colour setup (disabled when stdout is not a terminal) ─────────────────────
if [ -t 1 ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_CYAN='\033[1;36m'
    C_YELLOW='\033[1;33m'
    C_GREEN='\033[0;32m'
    C_RED='\033[0;31m'
else
    C_RESET=''
    C_BOLD=''
    C_CYAN=''
    C_YELLOW=''
    C_GREEN=''
    C_RED=''
fi

# ── scenario metadata ─────────────────────────────────────────────────────────
scenario_name() {
    case "$1" in
        1)   echo "Index-heavy batch UPDATE (25 rows)" ;;
        2)   echo "Blocked replay (snapshot conflict)" ;;
        3)   echo "GIN + TOAST batch (8 rows)" ;;
        4)   echo "Schema migration (CREATE INDEX)" ;;
        5)   echo "Bulk INSERT / ETL" ;;
        6)   echo "FPI storm (HW-scale dependent)" ;;
        7)   echo "Reporting query (cross-table blast)" ;;
        8)   echo "Table rewrite / lock conflict" ;;
        9)   echo "Buffer pin (VACUUM FREEZE)" ;;
        10)  echo "Batch UPDATEs avg latency/txn (pgbench)" ;;
        10b) echo "Full-table UPDATE (wall clock)" ;;
        11)  echo "DROP 50-partition table (wall clock)" ;;
        12)  echo "VACUUM FULL + logical slot (wall clock)" ;;
        13)  echo "Hash VACUUM (snapshot + cleanup lock)" ;;
        14)  echo "Replay saturation (5-row × 4 idx)" ;;
        15)  echo "Anti-wraparound VACUUM FREEZE (wall clock)" ;;
        *)   echo "Unknown scenario $1" ;;
    esac
}

# ── parsing helpers ───────────────────────────────────────────────────────────
parse_pgbench_latency() {
    # Extracts X.X from "latency average = X.X ms"
    local file="$1"
    grep 'latency average' "$file" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}'
}

parse_wall_time() {
    # Extracts the number from "  xxx wall time (MODE): NUMBER ms"
    local file="$1" keyword="$2"
    grep "$keyword" "$file" 2>/dev/null | head -1 | awk '{print $(NF-1)}'
}

parse_blocking_stats() {
    local file="$1"
    local zero total
    zero=$(grep -c ', 0\.0 tps,' "$file" 2>/dev/null || echo 0)
    total=$(grep -c '^progress:' "$file" 2>/dev/null || echo 0)
    echo "$zero $total"
}

parse_pgbench_tps() {
    local file="$1"
    grep '^tps' "$file" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | awk '{print $1}'
}

# ── arithmetic helpers (awk for floating-point) ───────────────────────────────
awk_sub()  { awk "BEGIN {printf \"%.1f\", $1 - $2}"; }
awk_fmt1() { awk "BEGIN {printf \"%.1f\", $1}"; }

# ── bar chart helper ──────────────────────────────────────────────────────────
# render_bar ADDED_MS MAX_ADDED_MS
# Prints a bar of █ chars scaled to MAX_ADDED_MS, capped at 40.
# Returns the bar string on stdout; if capped also appends " (capped)".
render_bar() {
    local added="$1" max_added="$2"
    # Use awk to compute bar length (avoid bash floating-point limitations)
    local bar_len
    bar_len=$(awk "BEGIN {
        if ($max_added <= 0) { print 0; exit }
        v = int($added / $max_added * 40)
        if (v > 40) v = 40
        if (v < 0)  v = 0
        print v
    }")
    local capped
    capped=$(awk "BEGIN { print ($added > $max_added) ? 1 : 0 }")

    local bar=""
    local i
    for (( i = 0; i < bar_len; i++ )); do
        bar="${bar}█"
    done

    if [ "$capped" = "1" ]; then
        printf "%s%s%s (capped)" "${C_GREEN}" "$bar" "${C_RESET}"
    else
        printf "%s%s%s" "${C_GREEN}" "$bar" "${C_RESET}"
    fi
}

# ── divider lines ─────────────────────────────────────────────────────────────
WIDE_DIV="══════════════════════════════════════════════════════════════════════════════"
THIN_DIV="─────────────────────────────────────────────────────────────────────────────"

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    local generated
    generated=$(date '+%Y-%m-%d %H:%M:%S')

    # ── header ────────────────────────────────────────────────────────────────
    printf "${C_CYAN}${C_BOLD}%s\n" "$WIDE_DIV"
    printf "  SYNCREP BENCHMARK — ADDED LATENCY REPORT\n"
    printf "  Results: %s\n" "$RESULTS_DIR"
    printf "  Generated: %s\n" "$generated"
    printf "%s${C_RESET}\n" "$WIDE_DIV"
    printf "\n"

    # ──────────────────────────────────────────────────────────────────────────
    # Collect data for all pgbench scenarios: 1-9, 13
    # ──────────────────────────────────────────────────────────────────────────
    # Arrays indexed 0..N-1 in order of display
    local -a pb_ids=()        # scenario number (string)
    local -a pb_names=()
    local -a pb_rw=()         # remote_write latency (ms)
    local -a pb_ra=()         # remote_apply latency (ms)
    local -a pb_added=()      # added latency (ms, float string)
    local -a pb_negative=()   # "1" if added < 0
    local -a pb_missing=()    # "1" if files missing

    local -a missing_list=()  # human-readable list of unavailable scenario IDs

    for N in 1 2 3 4 6 7 8 9 14; do
        local rw_f="${RESULTS_DIR}/s${N}_remote_write.log"
        local ra_f="${RESULTS_DIR}/s${N}_remote_apply.log"
        local name
        name=$(scenario_name "$N")

        if [ ! -f "$rw_f" ] || [ ! -f "$ra_f" ]; then
            missing_list+=("S${N}")
            continue
        fi

        local rw ra
        rw=$(parse_pgbench_latency "$rw_f")
        ra=$(parse_pgbench_latency "$ra_f")

        if [ -z "$rw" ] || [ -z "$ra" ]; then
            # Files exist but could not be parsed — treat as parse error
            pb_ids+=("$N")
            pb_names+=("$name")
            pb_rw+=("ERR")
            pb_ra+=("ERR")
            pb_added+=("ERR")
            pb_negative+=("0")
            pb_missing+=("1")
            continue
        fi

        local added
        added=$(awk_sub "$ra" "$rw")
        local neg
        neg=$(awk "BEGIN { print ($added < 0) ? 1 : 0 }")

        pb_ids+=("$N")
        pb_names+=("$name")
        pb_rw+=("$rw")
        pb_ra+=("$ra")
        pb_added+=("$added")
        pb_negative+=("$neg")
        pb_missing+=("0")
    done

    # ── compute max non-capped added for bar scale ─────────────────────────────
    # "capped" for our purposes means added_ms > some very large threshold
    # (e.g. 30000 ms, which is the pgbench statement_timeout cap seen in run.sh).
    # We cap bar at 40 chars total; scale to the maximum non-capped value present.
    # Define "would be capped" as: bar would need > 40 cells if we used global max.
    # Algorithm: find max added that is < 30000 ms (the timeout sentinel).
    local CAP_THRESHOLD=29000   # values >= this are considered "timeout/capped"

    local max_added_for_scale="0"
    local idx
    for (( idx = 0; idx < ${#pb_ids[@]}; idx++ )); do
        [ "${pb_missing[$idx]}" = "1" ] && continue
        [ "${pb_negative[$idx]}" = "1" ] && continue
        local val="${pb_added[$idx]}"
        [ "$val" = "ERR" ] && continue
        # Only use values below the cap threshold for scaling
        local is_big
        is_big=$(awk "BEGIN { print ($val >= $CAP_THRESHOLD) ? 1 : 0 }")
        if [ "$is_big" = "0" ]; then
            local bigger
            bigger=$(awk "BEGIN { print ($val > $max_added_for_scale) ? 1 : 0 }")
            if [ "$bigger" = "1" ]; then
                max_added_for_scale="$val"
            fi
        fi
    done

    # ── pgbench section header ─────────────────────────────────────────────────
    printf "${C_YELLOW}  ── pgbench scenarios (avg commit latency per transaction) ──────────────────${C_RESET}\n"
    printf "\n"
    printf "   %-3s  %-36s  %7s  %8s  %8s  %s\n" \
        "#" "Scenario" "rw_ms" "ra_ms" "added_ms" "bar"
    printf "  ${C_BOLD}%s${C_RESET}\n" "$THIN_DIV"

    local -a pgbench_rows_for_summary=()  # indices into pb_* arrays, valid only

    for (( idx = 0; idx < ${#pb_ids[@]}; idx++ )); do
        local sid="${pb_ids[$idx]}"
        local sname="${pb_names[$idx]}"
        local rw_v="${pb_rw[$idx]}"
        local ra_v="${pb_ra[$idx]}"
        local added_v="${pb_added[$idx]}"
        local is_neg="${pb_negative[$idx]}"
        local is_miss="${pb_missing[$idx]}"

        if [ "$is_miss" = "1" ] && [ "$added_v" = "ERR" ]; then
            # parse error row
            printf "  ${C_RED} %-3s  %-36s  %7s  %8s  %8s${C_RESET}\n" \
                "$sid" "$sname" "ERR" "ERR" "parse error"
            continue
        fi

        # Format the numeric columns
        local rw_fmt ra_fmt added_fmt
        rw_fmt=$(awk_fmt1 "$rw_v")
        ra_fmt=$(awk_fmt1 "$ra_v")

        # Check for blocking (0-TPS intervals in remote_apply progress)
        local ra_file="${RESULTS_DIR}/s${sid}_remote_apply.log"
        local rw_file="${RESULTS_DIR}/s${sid}_remote_write.log"
        local b_zero b_total
        read -r b_zero b_total <<< "$(parse_blocking_stats "$ra_file")"
        if [ "$b_zero" -gt 0 ] 2>/dev/null; then
            local blocked_s=$(( b_zero * 5 ))
            local total_s=$(( b_total * 5 ))
            local tps_rw_v tps_ra_v tps_ratio_v
            tps_rw_v=$(parse_pgbench_tps "$rw_file")
            tps_ra_v=$(parse_pgbench_tps "$ra_file")
            tps_ratio_v=$(awk "BEGIN {printf \"%.0f\", $tps_rw_v / $tps_ra_v}")
            printf "  %4s  %-36s  %7s  ${C_RED}%8s${C_RESET}  ← 0 TPS for %d/%ds (%sx TPS drop)\n" \
                "$sid" "$sname" "$rw_fmt" "BLOCKED" "$blocked_s" "$total_s" "$tps_ratio_v"
            continue
        fi

        if [ "$is_neg" = "1" ]; then
            added_fmt=$(printf "%s" "$added_v")
            printf "   %-3s  %-36s  %7s  %8s  %8s  ${C_RED}— (apply faster)${C_RESET}\n" \
                "$sid" "$sname" "$rw_fmt" "$ra_fmt" "$added_fmt"
        else
            added_fmt=$(printf "+%s" "$added_v")
            # Determine if this value is "capped"
            local is_capped
            is_capped=$(awk "BEGIN { print ($added_v >= $CAP_THRESHOLD) ? 1 : 0 }")

            local bar_str
            if [ "$is_capped" = "1" ]; then
                # Print 40 full blocks + (capped)
                local full_bar=""
                local b
                for (( b = 0; b < 40; b++ )); do full_bar="${full_bar}█"; done
                bar_str="${C_GREEN}${full_bar}${C_RESET} (capped)"
            else
                bar_str=$(render_bar "$added_v" "$max_added_for_scale")
            fi

            printf "  %4s  %-36s  %7s  %8s  %8s   %b\n" \
                "$sid" "$sname" "$rw_fmt" "$ra_fmt" "$added_fmt" "$bar_str"

            pgbench_rows_for_summary+=("$idx")
        fi
    done

    printf "\n"

    # ──────────────────────────────────────────────────────────────────────────
    # Wallclock section: S10a (pgbench), S10b (wall), S11 (wall), S12 (wall)
    # ──────────────────────────────────────────────────────────────────────────
    printf "${C_YELLOW}  ── single-operation wall time (total time for the operation itself) ────────${C_RESET}\n"
    printf "\n"
    printf "   %-4s %-36s  %7s  %8s  %8s\n" \
        "#" "Scenario" "rw_ms" "ra_ms" "added_ms"
    printf "  ${C_BOLD}%s${C_RESET}\n" "$THIN_DIV"

    # S10a — pgbench part of scenario 10
    local s10_rw_f="${RESULTS_DIR}/s10_remote_write.log"
    local s10_ra_f="${RESULTS_DIR}/s10_remote_apply.log"
    local s10a_available=0
    local s10b_available=0

    if [ -f "$s10_rw_f" ] && [ -f "$s10_ra_f" ]; then
        # Part A: pgbench latency
        local s10a_rw s10a_ra
        s10a_rw=$(parse_pgbench_latency "$s10_rw_f")
        s10a_ra=$(parse_pgbench_latency "$s10_ra_f")
        if [ -n "$s10a_rw" ] && [ -n "$s10a_ra" ]; then
            s10a_available=1
            local s10a_added
            s10a_added=$(awk_sub "$s10a_ra" "$s10a_rw")
            local s10a_added_fmt
            local s10a_neg
            s10a_neg=$(awk "BEGIN { print ($s10a_added < 0) ? 1 : 0 }")
            if [ "$s10a_neg" = "1" ]; then
                s10a_added_fmt="$s10a_added"
            else
                s10a_added_fmt="+${s10a_added}"
            fi
            printf "  %4s  %-36s  %7s  %8s  %8s\n" \
                "10a" "$(scenario_name 10)" \
                "$(awk_fmt1 "$s10a_rw")" "$(awk_fmt1 "$s10a_ra")" "$s10a_added_fmt"
        else
            printf "  ${C_RED}%4s  %-36s  %7s  %8s  %8s${C_RESET}\n" \
                "10a" "$(scenario_name 10)" "ERR" "ERR" "parse error"
        fi

        # Part B: wall time
        local s10b_rw s10b_ra
        s10b_rw=$(parse_wall_time "$s10_rw_f" "full-table UPDATE wall time")
        s10b_ra=$(parse_wall_time "$s10_ra_f" "full-table UPDATE wall time")
        if [ -n "$s10b_rw" ] && [ -n "$s10b_ra" ]; then
            s10b_available=1
            local s10b_added
            s10b_added=$(awk_sub "$s10b_ra" "$s10b_rw")
            local s10b_added_fmt
            local s10b_neg
            s10b_neg=$(awk "BEGIN { print ($s10b_added < 0) ? 1 : 0 }")
            if [ "$s10b_neg" = "1" ]; then
                s10b_added_fmt="$s10b_added"
            else
                s10b_added_fmt="+${s10b_added}"
            fi
            printf "  %4s  %-36s  %7s  %8s  %8s\n" \
                "10b" "$(scenario_name 10b)" \
                "$s10b_rw" "$s10b_ra" "$s10b_added_fmt"
        else
            printf "  ${C_RED}%4s  %-36s  %7s  %8s  %8s${C_RESET}\n" \
                "10b" "$(scenario_name 10b)" "ERR" "ERR" "parse error"
        fi
    else
        missing_list+=("S10")
    fi

    # S11 — DROP TABLE wall time
    local s11_rw_f="${RESULTS_DIR}/s11_remote_write.log"
    local s11_ra_f="${RESULTS_DIR}/s11_remote_apply.log"
    if [ -f "$s11_rw_f" ] && [ -f "$s11_ra_f" ]; then
        local s11_rw s11_ra
        s11_rw=$(parse_wall_time "$s11_rw_f" "DROP TABLE wall time")
        s11_ra=$(parse_wall_time "$s11_ra_f" "DROP TABLE wall time")
        if [ -n "$s11_rw" ] && [ -n "$s11_ra" ]; then
            local s11_added
            s11_added=$(awk_sub "$s11_ra" "$s11_rw")
            local s11_added_fmt
            local s11_neg
            s11_neg=$(awk "BEGIN { print ($s11_added < 0) ? 1 : 0 }")
            if [ "$s11_neg" = "1" ]; then
                s11_added_fmt="$s11_added"
            else
                s11_added_fmt="+${s11_added}"
            fi
            printf "  %4s  %-36s  %7s  %8s  %8s\n" \
                "11" "$(scenario_name 11)" \
                "$s11_rw" "$s11_ra" "$s11_added_fmt"
        else
            printf "  ${C_RED}%4s  %-36s  %7s  %8s  %8s${C_RESET}\n" \
                "11" "$(scenario_name 11)" "ERR" "ERR" "parse error"
        fi
    else
        missing_list+=("S11")
    fi

    # S12 — VACUUM FULL wall time
    local s12_rw_f="${RESULTS_DIR}/s12_remote_write.log"
    local s12_ra_f="${RESULTS_DIR}/s12_remote_apply.log"
    if [ -f "$s12_rw_f" ] && [ -f "$s12_ra_f" ]; then
        local s12_rw s12_ra
        s12_rw=$(parse_wall_time "$s12_rw_f" "VACUUM FULL wall time")
        s12_ra=$(parse_wall_time "$s12_ra_f" "VACUUM FULL wall time")
        if [ -n "$s12_rw" ] && [ -n "$s12_ra" ]; then
            local s12_added
            s12_added=$(awk_sub "$s12_ra" "$s12_rw")
            local s12_added_fmt
            local s12_neg
            s12_neg=$(awk "BEGIN { print ($s12_added < 0) ? 1 : 0 }")
            if [ "$s12_neg" = "1" ]; then
                s12_added_fmt="$s12_added"
            else
                s12_added_fmt="+${s12_added}"
            fi
            printf "  %4s  %-36s  %7s  %8s  %8s\n" \
                "12" "$(scenario_name 12)" \
                "$s12_rw" "$s12_ra" "$s12_added_fmt"
        else
            printf "  ${C_RED}%4s  %-36s  %7s  %8s  %8s${C_RESET}\n" \
                "12" "$(scenario_name 12)" "ERR" "ERR" "parse error"
        fi
    else
        missing_list+=("S12")
    fi

    # S15 — VACUUM FREEZE wall time
    local s15_rw_f="${RESULTS_DIR}/s15_remote_write.log"
    local s15_ra_f="${RESULTS_DIR}/s15_remote_apply.log"
    if [ -f "$s15_rw_f" ] && [ -f "$s15_ra_f" ]; then
        local s15_rw s15_ra
        s15_rw=$(parse_wall_time "$s15_rw_f" "VACUUM FREEZE wall time")
        s15_ra=$(parse_wall_time "$s15_ra_f" "VACUUM FREEZE wall time")
        if [ -n "$s15_rw" ] && [ -n "$s15_ra" ]; then
            local s15_added s15_added_fmt s15_neg
            s15_added=$(awk_sub "$s15_ra" "$s15_rw")
            s15_neg=$(awk "BEGIN { print ($s15_added < 0) ? 1 : 0 }")
            if [ "$s15_neg" = "1" ]; then
                s15_added_fmt="$s15_added"
            else
                s15_added_fmt="+${s15_added}"
            fi
            printf "  %4s  %-36s  %7s  %8s  %8s\n" \
                "15" "$(scenario_name 15)" \
                "$s15_rw" "$s15_ra" "$s15_added_fmt"
        else
            printf "  ${C_RED}%4s  %-36s  %7s  %8s  %8s${C_RESET}\n" \
                "15" "$(scenario_name 15)" "ERR" "ERR" "parse error"
        fi
    else
        missing_list+=("S15")
    fi

    printf "\n"

    # ── summary header ─────────────────────────────────────────────────────────
    printf "${C_CYAN}${C_BOLD}%s\n" "$WIDE_DIV"
    printf "  ADDED LATENCY SUMMARY\n"
    printf "%s${C_RESET}\n" "$WIDE_DIV"
    printf "\n"

    # ── pgbench summary: min / median / max of valid added values ─────────────
    printf "  pgbench scenarios (avg ms per commit):\n"

    # Gather valid (non-negative, non-error, non-capped) added values with labels
    local -a sum_vals=()
    local -a sum_ids=()
    local -a sum_names=()

    for (( idx = 0; idx < ${#pb_ids[@]}; idx++ )); do
        [ "${pb_missing[$idx]}" = "1" ] && continue
        [ "${pb_negative[$idx]}" = "1" ] && continue
        [ "${pb_added[$idx]}" = "ERR" ] && continue
        # Skip blocking scenarios — their avg latency is meaningless
        local chk_file="${RESULTS_DIR}/s${pb_ids[$idx]}_remote_apply.log"
        local chk_zero
        chk_zero=$(grep -c ', 0\.0 tps,' "$chk_file" 2>/dev/null || echo 0)
        [ "$chk_zero" -gt 0 ] && continue
        sum_vals+=("${pb_added[$idx]}")
        sum_ids+=("${pb_ids[$idx]}")
        sum_names+=("${pb_names[$idx]}")
    done

    if [ ${#sum_vals[@]} -eq 0 ]; then
        printf "    ${C_RED}No valid pgbench results found.${C_RESET}\n"
    else
        # Sort indices by value (bubble sort — N is small)
        local -a sort_idx=()
        local si
        for (( si = 0; si < ${#sum_vals[@]}; si++ )); do sort_idx+=("$si"); done

        local n_vals=${#sum_vals[@]}
        local i j tmp_i
        for (( i = 0; i < n_vals - 1; i++ )); do
            for (( j = i + 1; j < n_vals; j++ )); do
                local ai="${sort_idx[$i]}" aj="${sort_idx[$j]}"
                local should_swap
                should_swap=$(awk "BEGIN { print (${sum_vals[$ai]} > ${sum_vals[$aj]}) ? 1 : 0 }")
                if [ "$should_swap" = "1" ]; then
                    tmp_i="${sort_idx[$i]}"
                    sort_idx[$i]="${sort_idx[$j]}"
                    sort_idx[$j]="$tmp_i"
                fi
            done
        done

        # Min
        local min_i="${sort_idx[0]}"
        printf "    Minimum added:   S%-2s  %-36s  +%s ms\n" \
            "${sum_ids[$min_i]}" "${sum_names[$min_i]}" "${sum_vals[$min_i]}"

        # Median (lower-middle for even count)
        local med_pos=$(( (n_vals - 1) / 2 ))
        local med_i="${sort_idx[$med_pos]}"
        printf "    Median added:    S%-2s  %-36s  +%s ms\n" \
            "${sum_ids[$med_i]}" "${sum_names[$med_i]}" "${sum_vals[$med_i]}"

        # Max
        local max_i="${sort_idx[$(( n_vals - 1 ))]}"
        # For display, strip trailing zeros but keep one decimal
        local max_added_disp="${sum_vals[$max_i]}"
        # Shorten name for capped scenarios
        local max_name="${sum_names[$max_i]}"
        # Abbreviate long names in summary (snapshot conflict → snapshot)
        local max_name_short
        max_name_short=$(echo "$max_name" | sed 's/ (snapshot conflict)/ (snapshot)/')
        printf "    Maximum added:   S%-2s  %-36s  +%s ms\n" \
            "${sum_ids[$max_i]}" "$max_name_short" "$max_added_disp"
    fi

    printf "\n"

    # ── missing scenarios ──────────────────────────────────────────────────────
    if [ ${#missing_list[@]} -eq 0 ]; then
        printf "  Scenarios not available (log files missing): (none)\n"
    else
        local missing_str
        missing_str=$(IFS=' '; echo "${missing_list[*]}")
        printf "  ${C_RED}Scenarios not available (log files missing): %s${C_RESET}\n" "$missing_str"
    fi

    printf "\n"

    # ── interpretation ─────────────────────────────────────────────────────────
    printf "  Interpretation:\n"
    printf "    added_ms > 0  → remote_apply costs that many extra ms per commit vs remote_write\n"
    printf "    added_ms = 0  → no measurable difference (same speed)\n"
    printf "    Bar chart is capped at 40 chars; \"(capped)\" means actual ratio is larger\n"

    printf "\n"
    printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "$WIDE_DIV"
}

main "$@"
