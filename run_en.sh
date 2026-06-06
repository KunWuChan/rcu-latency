#!/bin/bash
set -e

CGNAME="exp_rcu_test"
CGPATH="/sys/fs/cgroup/${CGNAME}"
DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
	cat <<EOF
Usage: $0 <command> [args]

Commands:
  build                        Build the kernel module
  baseline [duration]          Run baseline test (expedited GP, no cgroup), default 10s
  cgroup <cpu_max> [duration]  Run cgroup throttled test (expedited GP), default 10s
                               e.g.: cgroup "10000 100000" 10
  normal <sub> [args]          Run synchronize_rcu() comparison test
                               normal baseline [duration]
                               normal cgroup <cpu_max> [duration]
  clean                        Clean up cgroup and unload module
  results                      Extract latest results from dmesg

Module parameters (override via environment variables):
  READER_IN_CS_MS    busy_loop wall-clock target inside RCU CS (ms), default 50
  READER_IN_CS_US    busy_loop wall-clock target inside RCU CS (us), overrides MS when >0
  READER_OUT_CS_MS   sleep outside RCU CS (ms), default 10
  SYNCHER_INTERVAL_MS interval between GP calls (ms), default 0 (back-to-back)
  USE_NORMAL_GP      use synchronize_rcu() instead of expedited (0/1), default 0
  NO_COND_RESCHED    disable cond_resched() in busy_loop (0/1), default 0
  READER_CPU         CPU to pin reader kthread, default 0
  SYNCER_CPU         CPU to pin syncer kthread, default 1

Design:
  Reader executes busy_loop + cond_resched() inside rcu_read_lock().
  cond_resched() provides a preemption point so that cgroup throttling
  can schedule the reader out. Two metrics are collected:
    READER_CS: wall-clock time from rcu_read_lock() to rcu_read_unlock()
    SYNCER:    per-call latency of synchronize_rcu_expedited()

  Note: busy_loop uses ktime_get() (wall-clock), so under throttle the
  loop exits early — the reader does less CPU work, not more.

Examples:
  # Baseline: expedited GP, reader busy_loop 50ms, no cgroup
  $0 baseline 10

  # Cgroup throttled: expedited GP, cpu.max=10000 100000 (10%)
  READER_IN_CS_MS=20 $0 cgroup "10000 100000" 10

  # synchronize_rcu() comparison
  READER_IN_CS_MS=20 $0 normal baseline 10
  READER_IN_CS_MS=20 $0 normal cgroup "10000 100000" 10

  # View results
  $0 results
EOF
	exit 1
}

build_module() {
	echo "=== Building kernel module ==="
	cd "$DIR"
	make clean 2>/dev/null || true
	make
	echo "Build complete: $DIR/exp_rcu_test.ko"
}

setup_cgroup() {
	local cpu_max="$1"
	echo "=== Creating cgroup: /${CGNAME} ==="
	if [ -d "$CGPATH" ]; then
		cleanup_cgroup
	fi
	sudo mkdir -p "$CGPATH"
	sudo sh -c "echo '$cpu_max' > ${CGPATH}/cpu.max"
	echo "cpu.max = $(sudo cat ${CGPATH}/cpu.max)"
}

move_reader_to_cgroup() {
	echo "=== Moving reader kthread into cgroup ==="
	local pid
	for i in $(seq 1 10); do
		pid=$(pgrep -f exp_rcu_reader 2>/dev/null || true)
		if [ -n "$pid" ]; then
			break
		fi
		sleep 0.3
	done
	if [ -z "$pid" ]; then
		echo "Error: exp_rcu_reader kthread not found"
		return 1
	fi
	echo "reader pid=$pid"
	sudo sh -c "echo '$pid' > ${CGPATH}/cgroup.procs"
	echo "cgroup.procs: $(sudo cat ${CGPATH}/cgroup.procs)"
}

cleanup_cgroup() {
	if [ -d "$CGPATH" ]; then
		sudo cat "${CGPATH}/cgroup.procs" 2>/dev/null | while read p; do
			sudo sh -c "echo '$p' > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
		done
		sleep 1
		sudo rmdir "$CGPATH" 2>/dev/null || true
		echo "cgroup removed"
	fi
}

unload_module() {
	if lsmod | grep -q exp_rcu_test; then
		if sudo rmmod exp_rcu_test 2>/dev/null; then
			echo "Module unloaded"
			return 0
		fi
		echo "Error: rmmod exp_rcu_test failed"
		if lsmod | grep -q exp_rcu_test; then
			echo "Module still loaded, check: cat /sys/module/exp_rcu_test/refcnt"
			echo "Try force unload: sudo rmmod -f exp_rcu_test"
		fi
		return 1
	else
		echo "Module not loaded"
		return 0
	fi
}

get_module_params() {
	local params=""
	params+="reader_in_cs_ms=${READER_IN_CS_MS:-50} "
	params+="reader_in_cs_us=${READER_IN_CS_US:-0} "
	params+="reader_out_cs_ms=${READER_OUT_CS_MS:-10} "
	params+="syncer_interval_ms=${SYNCER_INTERVAL_MS:-0} "
	params+="use_normal_gp=${USE_NORMAL_GP:-0} "
	params+="no_cond_resched=${NO_COND_RESCHED:-0} "
	params+="reader_cpu=${READER_CPU:-0} "
	params+="syncer_cpu=${SYNCER_CPU:-1} "
	echo "$params"
}

run_baseline() {
	local duration="${1:-10}"

	echo "============================================"
	echo "  Baseline test (no cgroup throttling)"
	echo "  reader_in_cs_ms=${READER_IN_CS_MS:-50}"
	echo "  reader_out_cs_ms=${READER_OUT_CS_MS:-10}"
	echo "  duration=${duration}s"
	echo "============================================"

	build_module
	unload_module || true
	cleanup_cgroup

	local params
	params=$(get_module_params)

	echo "=== Loading module ==="
	sudo dmesg -C
	sudo insmod "$DIR/exp_rcu_test.ko" $params

	echo "=== Running ${duration}s ... ==="
	sleep "$duration"

	echo "=== Stopping test ==="
	unload_module

	echo ""
	echo "=== Results ==="
	extract_results
}

run_cgroup() {
	local cpu_max="$1"
	local duration="${2:-10}"

	if [ -z "$cpu_max" ]; then
		echo "Error: cpu_max argument required, e.g. \"10000 100000\""
		usage
	fi

	echo "============================================"
	echo "  Cgroup throttled test"
	echo "  cpu.max=$cpu_max"
	echo "  reader_in_cs_ms=${READER_IN_CS_MS:-50}"
	echo "  reader_out_cs_ms=${READER_OUT_CS_MS:-10}"
	echo "  duration=${duration}s"
	echo "============================================"

	build_module
	unload_module || true
	cleanup_cgroup

	setup_cgroup "$cpu_max"

	local params
	params=$(get_module_params)

	echo "=== Loading module ==="
	sudo dmesg -C
	sudo insmod "$DIR/exp_rcu_test.ko" $params

	move_reader_to_cgroup

	echo "=== Running ${duration}s ... ==="
	sleep "$duration"

	echo "=== Stopping test ==="
	unload_module
	show_cpu_stat "after test"
	cleanup_cgroup

	echo ""
	echo "=== Results ==="
	extract_results
}

show_cpu_stat() {
	local label="$1"
	if [ -n "$CGPATH" ] && [ -f "${CGPATH}/cpu.stat" ]; then
		echo "--- cpu.stat (${label}) ---"
		sudo cat "${CGPATH}/cpu.stat"
		echo ""
	fi
}

extract_results() {
	echo "--- dmesg output (summary) ---"
	sudo dmesg | grep "exp_rcu_test:" | head -200
}

cmd="$1"
shift || true

case "$cmd" in
	build)
		build_module
		;;
	baseline)
		run_baseline "$@"
		;;
	cgroup)
		run_cgroup "$@"
		;;
	normal)
		sub="$1"
		shift || true
		export USE_NORMAL_GP=1
		case "$sub" in
			baseline)
				run_baseline "$@"
				;;
			cgroup)
				run_cgroup "$@"
				;;
			*)
				usage
				;;
		esac
		;;
	clean)
		unload_module || true
		cleanup_cgroup
		;;
	results)
		extract_results
		;;
	*)
		usage
		;;
esac
