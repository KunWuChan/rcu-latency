// SPDX-License-Identifier: GPL-2.0-only
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/ktime.h>
#include <linux/sched.h>
#include <linux/rcupdate.h>
#include <linux/slab.h>
#include <linux/sort.h>
#include <linux/completion.h>

#define MAX_SAMPLES 10000

static unsigned int reader_in_cs_ms = 50;
module_param(reader_in_cs_ms, uint, 0644);
MODULE_PARM_DESC(reader_in_cs_ms, "ms reader stays inside RCU CS (default: 50)");

static unsigned int reader_out_cs_ms = 10;
module_param(reader_out_cs_ms, uint, 0644);
MODULE_PARM_DESC(reader_out_cs_ms, "ms reader stays outside RCU CS (default: 10)");

static unsigned int syncer_interval_ms = 0;
module_param(syncer_interval_ms, uint, 0644);
MODULE_PARM_DESC(syncer_interval_ms, "ms between GP calls (0 = back-to-back)");

static unsigned int use_normal_gp = 0;
module_param(use_normal_gp, uint, 0644);
MODULE_PARM_DESC(use_normal_gp, "use synchronize_rcu() instead of synchronize_rcu_expedited()");

static unsigned int no_cond_resched = 0;
module_param(no_cond_resched, uint, 0644);
MODULE_PARM_DESC(no_cond_resched, "disable cond_resched() in busy_loop (default: 0)");

static unsigned int reader_in_cs_us;
module_param(reader_in_cs_us, uint, 0644);
MODULE_PARM_DESC(reader_in_cs_us, "us reader stays inside RCU CS (when >0, overrides reader_in_cs_ms)");

static int reader_cpu = 0;
module_param(reader_cpu, int, 0644);
MODULE_PARM_DESC(reader_cpu, "CPU to pin reader kthread (-1 = no pin)");

static int syncer_cpu = 1;
module_param(syncer_cpu, int, 0644);
MODULE_PARM_DESC(syncer_cpu, "CPU to pin syncer kthread (-1 = no pin)");

static struct task_struct *reader_task;
static struct task_struct *syncer_task;
static struct completion reader_done, syncer_done;

struct latency_sample {
	ktime_t start;
	ktime_t end;
};

static struct latency_sample reader_samples[MAX_SAMPLES];
static atomic_t reader_sample_total = ATOMIC_INIT(0);

static struct latency_sample syncer_samples[MAX_SAMPLES];
static atomic_t syncer_sample_total = ATOMIC_INIT(0);

static atomic_t test_running = ATOMIC_INIT(1);

static int cmp_u64(const void *a, const void *b)
{
	u64 va = *(const u64 *)a;
	u64 vb = *(const u64 *)b;
	if (va < vb) return -1;
	if (va > vb) return 1;
	return 0;
}

static void do_busy_loop_ms(unsigned int ms)
{
	ktime_t start = ktime_get();
	unsigned long iter = 0;

	while (ktime_ms_delta(ktime_get(), start) < ms) {
		cpu_relax();
		if (!no_cond_resched && ++iter % 10000 == 0)
			cond_resched();
	}
}

static void do_busy_loop_us(unsigned int us)
{
	ktime_t start = ktime_get();
	unsigned long iter = 0;

	while (ktime_us_delta(ktime_get(), start) < us) {
		cpu_relax();
		if (!no_cond_resched && ++iter % 1000 == 0)
			cond_resched();
	}
}

static int reader_thread(void *arg)
{
	ktime_t cs_start, cs_end;
	int idx;

	if (reader_cpu >= 0)
		set_cpus_allowed_ptr(current, cpumask_of(reader_cpu));

	pr_info("exp_rcu_test: reader on CPU%d, in_cs=%ums/%uus, out_cs=%ums\n",
		reader_cpu, reader_in_cs_ms, reader_in_cs_us, reader_out_cs_ms);

	while (atomic_read(&test_running) && !kthread_should_stop()) {
		cs_start = ktime_get();
		rcu_read_lock();

		if (reader_in_cs_us > 0)
			do_busy_loop_us(reader_in_cs_us);
		else
			do_busy_loop_ms(reader_in_cs_ms);

		rcu_read_unlock();
		cs_end = ktime_get();

		idx = atomic_fetch_inc(&reader_sample_total);
		reader_samples[idx % MAX_SAMPLES].start = cs_start;
		reader_samples[idx % MAX_SAMPLES].end = cs_end;

		if (reader_out_cs_ms)
			msleep(reader_out_cs_ms);
	}

	pr_info("exp_rcu_test: reader stopped\n");
	complete(&reader_done);
	return 0;
}

static int syncer_thread(void *arg)
{
	int idx;
	ktime_t start, end;
	int count = 0;

	if (syncer_cpu >= 0)
		set_cpus_allowed_ptr(current, cpumask_of(syncer_cpu));

	pr_info("exp_rcu_test: syncer on CPU%d, interval=%ums, gp_type=%s\n",
		syncer_cpu, syncer_interval_ms,
		use_normal_gp ? "normal" : "expedited");

	while (atomic_read(&test_running) && !kthread_should_stop()) {
		start = ktime_get();
		if (use_normal_gp)
			synchronize_rcu();
		else
			synchronize_rcu_expedited();
		end = ktime_get();

		idx = atomic_fetch_inc(&syncer_sample_total);
		syncer_samples[idx % MAX_SAMPLES].start = start;
		syncer_samples[idx % MAX_SAMPLES].end = end;

		count++;
		if (syncer_interval_ms)
			msleep(syncer_interval_ms);
	}

	pr_info("exp_rcu_test: syncer stopped, %d total calls\n", count);
	complete(&syncer_done);
	return 0;
}

static void print_stats(const char *name, struct latency_sample *samps, int total)
{
	u64 *vals;
	int i, n, valid;
	u64 sum, avg, p50, p90, p95, p99, min_val, max_val;

	if (total <= 0) {
		pr_info("exp_rcu_test: %s: no samples\n", name);
		return;
	}

	n = (total > MAX_SAMPLES) ? MAX_SAMPLES : total;
	vals = kmalloc_array(n, sizeof(u64), GFP_KERNEL);
	if (!vals) {
		pr_err("exp_rcu_test: out of memory for %s results\n", name);
		return;
	}

	sum = 0;
	valid = 0;
	for (i = 0; i < n; i++) {
		int src = (total - n + i) % MAX_SAMPLES;
		u64 us = ktime_us_delta(samps[src].end, samps[src].start);
		if (us > 0) {
			vals[valid++] = us;
			sum += us;
		}
	}

	if (valid == 0) {
		pr_info("exp_rcu_test: %s: no valid samples\n", name);
		kfree(vals);
		return;
	}

	sort(vals, valid, sizeof(u64), cmp_u64, NULL);

	avg = sum / valid;
	p50 = vals[valid * 50 / 100];
	p90 = vals[valid * 90 / 100];
	p95 = vals[valid * 95 / 100];
	p99 = vals[valid * 99 / 100];
	min_val = vals[0];
	max_val = vals[valid - 1];

	pr_info("exp_rcu_test: ===== %s RESULTS (%d valid / %d total) =====\n",
		name, valid, total);
	pr_info("exp_rcu_test: %s min=%llu us  avg=%llu us  max=%llu us\n",
		name, min_val, avg, max_val);
	pr_info("exp_rcu_test: %s P50=%llu us  P90=%llu us  P95=%llu us  P99=%llu us\n",
		name, p50, p90, p95, p99);
	pr_info("exp_rcu_test: %s min=%llu ms  avg=%llu ms  max=%llu ms\n",
		name, min_val / 1000, avg / 1000, max_val / 1000);
	pr_info("exp_rcu_test: %s P50=%llu ms  P90=%llu ms  P95=%llu ms  P99=%llu ms\n",
		name, p50 / 1000, p90 / 1000, p95 / 1000, p99 / 1000);

	{
		int hist[6] = {0};
		u64 bounds_us[6] = {100, 1000, 10000, 50000, 100000, (u64)-1};
		char *labels[6] = {"<=100us", "100us-1ms", "1ms-10ms", "10ms-50ms", "50ms-100ms", ">100ms"};
		for (i = 0; i < valid; i++) {
			int b;
			for (b = 0; b < 6; b++)
				if (vals[i] <= bounds_us[b]) { hist[b]++; break; }
		}
		pr_info("exp_rcu_test: ===== %s HISTOGRAM =====\n", name);
		for (i = 0; i < 6; i++)
			pr_info("exp_rcu_test: %s %10s: %d (%d%%)\n", name, labels[i], hist[i],
				hist[i] * 100 / valid);
	}

	kfree(vals);
}

static void __exit exp_rcu_test_exit(void)
{
	atomic_set(&test_running, 0);

	if (reader_task)
		wake_up_process(reader_task);
	if (syncer_task)
		wake_up_process(syncer_task);

	if (reader_task)
		wait_for_completion(&reader_done);
	if (syncer_task)
		wait_for_completion(&syncer_done);

	print_stats("READER_CS", reader_samples, atomic_read(&reader_sample_total));
	print_stats("SYNCER", syncer_samples, atomic_read(&syncer_sample_total));
	pr_info("exp_rcu_test: unloaded\n");
}

static int __init exp_rcu_test_init(void)
{
	atomic_set(&reader_sample_total, 0);
	atomic_set(&syncer_sample_total, 0);
	atomic_set(&test_running, 1);
	init_completion(&reader_done);
	init_completion(&syncer_done);

	pr_info("exp_rcu_test: loading, reader_in=%ums reader_out=%ums\n",
		reader_in_cs_ms, reader_out_cs_ms);

	reader_task = kthread_run(reader_thread, NULL, "exp_rcu_reader");
	if (IS_ERR(reader_task)) {
		pr_err("exp_rcu_test: failed to create reader\n");
		return PTR_ERR(reader_task);
	}

	syncer_task = kthread_run(syncer_thread, NULL, "exp_rcu_syncer");
	if (IS_ERR(syncer_task)) {
		pr_err("exp_rcu_test: failed to create syncer\n");
		atomic_set(&test_running, 0);
		wake_up_process(reader_task);
		wait_for_completion(&reader_done);
		return PTR_ERR(syncer_task);
	}

	pr_info("exp_rcu_test: running (rmmod to stop and print results)\n");
	return 0;
}

module_init(exp_rcu_test_init);
module_exit(exp_rcu_test_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("RCU expedited grace period latency test");
