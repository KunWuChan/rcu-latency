#!/bin/bash
set -e

CGNAME="exp_rcu_test"
CGPATH="/sys/fs/cgroup/${CGNAME}"
DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
	cat <<EOF
用法: $0 <命令> [参数]

命令:
  build                    编译内核模块
  baseline [duration]      运行基线测试（expedited GP，无 cgroup），默认 10s
  cgroup <cpu_max> [duration]  运行 cgroup 限流测试（expedited GP），默认 10s
                              例如: cgroup "10000 100000" 10
  normal <sub> [args]      运行 synchronize_rcu() 对比测试
                              normal baseline [duration]
                              normal cgroup <cpu_max> [duration]
  clean                    清理 cgroup 和卸载模块
  results                  从 dmesg 提取最近一次结果

模块参数（通过环境变量覆盖）:
  READER_IN_CS_MS    reader 在 RCU 临界区内 busy_loop 时长（ms），默认 50
  READER_IN_CS_US    reader 在 RCU 临界区内 busy_loop 时长（us），>0 时覆盖 READER_IN_CS_MS
  READER_OUT_CS_MS   reader 在 RCU 临界区外时长（ms），默认 10
  SYNCHER_INTERVAL_MS syncer 调用间隔（ms），默认 0（连续调用）
  USE_NORMAL_GP      使用 synchronize_rcu() 替代 expedited（0/1），默认 0
  NO_COND_RESCHED    禁用 busy_loop 中的 cond_resched()（0/1），默认 0
  READER_CPU         reader 绑定的 CPU，默认 0
  SYNCER_CPU         syncer 绑定的 CPU，默认 1

原理:
  reader 在 rcu_read_lock() 内执行 busy_loop + cond_resched()
  cond_resched() 提供抢占点，使 cgroup 限流能将 reader 调度出去
  测量两组数据:
    READER_CS: rcu_read_lock() 到 rcu_read_unlock() 的墙钟时间
    SYNCER:    synchronize_rcu_expedited() 的调用延迟

示例:
  # 基线测试：expedited GP，reader busy_loop 50ms，无 cgroup
  $0 baseline 10

  # cgroup 限流：expedited GP，cpu.max=10000 100000 (10%)
  READER_IN_CS_MS=20 $0 cgroup "10000 100000" 10

  # synchronize_rcu() 对比测试
  READER_IN_CS_MS=20 $0 normal baseline 10
  READER_IN_CS_MS=20 $0 normal cgroup "10000 100000" 10

  # 查看结果
  $0 results
EOF
	exit 1
}

build_module() {
	echo "=== 编译内核模块 ==="
	cd "$DIR"
	make clean 2>/dev/null || true
	make
	echo "编译完成: $DIR/exp_rcu_test.ko"
}

setup_cgroup() {
	local cpu_max="$1"
	echo "=== 创建 cgroup: /${CGNAME} ==="
	if [ -d "$CGPATH" ]; then
		cleanup_cgroup
	fi
	sudo mkdir -p "$CGPATH"
	sudo sh -c "echo '$cpu_max' > ${CGPATH}/cpu.max"
	echo "cpu.max = $(sudo cat ${CGPATH}/cpu.max)"
}

move_reader_to_cgroup() {
	echo "=== 将 reader kthread 移入 cgroup ==="
	local pid
	for i in $(seq 1 10); do
		pid=$(pgrep -f exp_rcu_reader 2>/dev/null || true)
		if [ -n "$pid" ]; then
			break
		fi
		sleep 0.3
	done
	if [ -z "$pid" ]; then
		echo "错误: 找不到 exp_rcu_reader kthread"
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
		echo "cgroup 已删除"
	fi
}

unload_module() {
	if lsmod | grep -q exp_rcu_test; then
		if sudo rmmod exp_rcu_test 2>/dev/null; then
			echo "模块已卸载"
			return 0
		fi
		echo "错误: rmmod exp_rcu_test 失败"
		if lsmod | grep -q exp_rcu_test; then
			echo "模块仍在加载中，请检查: cat /sys/module/exp_rcu_test/refcnt"
			echo "可尝试强制卸载: sudo rmmod -f exp_rcu_test"
		fi
		return 1
	else
		echo "模块未加载"
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
	echo "  基线测试（无 cgroup 限制）"
	echo "  reader_in_cs_ms=${READER_IN_CS_MS:-50}"
	echo "  reader_out_cs_ms=${READER_OUT_CS_MS:-10}"
	echo "  duration=${duration}s"
	echo "============================================"

	build_module
	unload_module || true
	cleanup_cgroup

	local params
	params=$(get_module_params)

	echo "=== 加载模块 ==="
	sudo dmesg -C
	sudo insmod "$DIR/exp_rcu_test.ko" $params

	echo "=== 运行 ${duration}s ... ==="
	sleep "$duration"

	echo "=== 停止测试 ==="
	unload_module

	echo ""
	echo "=== 结果 ==="
	extract_results
}

run_cgroup() {
	local cpu_max="$1"
	local duration="${2:-10}"

	if [ -z "$cpu_max" ]; then
		echo "错误: 需要 cpu_max 参数，例如 \"10000 100000\""
		usage
	fi

	echo "============================================"
	echo "  cgroup 限流测试"
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

	echo "=== 加载模块 ==="
	sudo dmesg -C
	sudo insmod "$DIR/exp_rcu_test.ko" $params

	move_reader_to_cgroup

	echo "=== 运行 ${duration}s ... ==="
	sleep "$duration"

	echo "=== 停止测试 ==="
	unload_module
	show_cpu_stat "after test"
	cleanup_cgroup

	echo ""
	echo "=== 结果 ==="
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
