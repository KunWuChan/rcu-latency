#include <linux/module.h>
#define INCLUDE_VERMAGIC
#include <linux/build-salt.h>
#include <linux/elfnote-lto.h>
#include <linux/export-internal.h>
#include <linux/vermagic.h>
#include <linux/compiler.h>

#ifdef CONFIG_UNWINDER_ORC
#include <asm/orc_header.h>
ORC_HEADER;
#endif

BUILD_SALT;
BUILD_LTO_INFO;

MODULE_INFO(vermagic, VERMAGIC_STRING);
MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

#ifdef CONFIG_RETPOLINE
MODULE_INFO(retpoline, "Y");
#endif



static const char ____versions[]
__used __section("__versions") =
	"\x24\x00\x00\x00\x9d\xb9\xf6\x86"
	"synchronize_rcu_expedited\0\0\0"
	"\x10\x00\x00\x00\xf9\x82\xa4\xf9"
	"msleep\0\0"
	"\x14\x00\x00\x00\x2f\x7a\x25\xa6"
	"complete\0\0\0\0"
	"\x18\x00\x00\x00\x32\x2c\xc1\x01"
	"cpu_bit_bitmap\0\0"
	"\x14\x00\x00\x00\x45\xb5\x25\x20"
	"pcpu_hot\0\0\0\0"
	"\x20\x00\x00\x00\x19\xa5\xec\x8c"
	"set_cpus_allowed_ptr\0\0\0\0"
	"\x28\x00\x00\x00\xb3\x1c\xa2\x87"
	"__ubsan_handle_out_of_bounds\0\0\0\0"
	"\x18\x00\x00\x00\x14\x27\x52\x8d"
	"__rcu_read_lock\0"
	"\x1c\x00\x00\x00\xb3\x51\x73\xc0"
	"__SCT__cond_resched\0"
	"\x1c\x00\x00\x00\x0f\x81\x69\x24"
	"__rcu_read_unlock\0\0\0"
	"\x20\x00\x00\x00\xb5\x41\x87\x60"
	"__init_swait_queue_head\0"
	"\x20\x00\x00\x00\x1a\x0f\x3a\xbb"
	"kthread_create_on_node\0\0"
	"\x18\x00\x00\x00\xf9\x9c\x91\x41"
	"wake_up_process\0"
	"\x1c\x00\x00\x00\x00\x40\x97\x25"
	"wait_for_completion\0"
	"\x14\x00\x00\x00\x45\x3a\x23\xeb"
	"__kmalloc\0\0\0"
	"\x10\x00\x00\x00\x43\xf4\xc0\xb7"
	"sort\0\0\0\0"
	"\x10\x00\x00\x00\xba\x0c\x7a\x03"
	"kfree\0\0\0"
	"\x1c\x00\x00\x00\xcb\xf6\xfd\xf0"
	"__stack_chk_fail\0\0\0\0"
	"\x18\x00\x00\x00\x37\x39\xbd\x2f"
	"param_ops_int\0\0\0"
	"\x18\x00\x00\x00\xbf\x2b\x5f\xa6"
	"param_ops_uint\0\0"
	"\x14\x00\x00\x00\xbb\x6d\xfb\xbd"
	"__fentry__\0\0"
	"\x1c\x00\x00\x00\xca\x39\x82\x5b"
	"__x86_return_thunk\0\0"
	"\x10\x00\x00\x00\x7e\x3a\x2c\x12"
	"_printk\0"
	"\x18\x00\x00\x00\x7f\x79\x91\x60"
	"synchronize_rcu\0"
	"\x14\x00\x00\x00\x65\x93\x3f\xb4"
	"ktime_get\0\0\0"
	"\x1c\x00\x00\x00\x6e\x64\xf7\xb3"
	"kthread_should_stop\0"
	"\x18\x00\x00\x00\xe8\xd8\x3d\xf5"
	"module_layout\0\0\0"
	"\x00\x00\x00\x00\x00\x00\x00\x00";

MODULE_INFO(depends, "");


MODULE_INFO(srcversion, "98E89480471972892FC81A3");
