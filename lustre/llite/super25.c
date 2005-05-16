/* -*- mode: c; c-basic-offset: 8; indent-tabs-mode: nil; -*-
 * vim:expandtab:shiftwidth=8:tabstop=8:
 *
 * Lustre Light Super operations
 *
 *  Copyright (c) 2002, 2003 Cluster File Systems, Inc.
 *
 *   This file is part of Lustre, http://www.lustre.org.
 *
 *   Lustre is free software; you can redistribute it and/or
 *   modify it under the terms of version 2 of the GNU General Public
 *   License as published by the Free Software Foundation.
 *
 *   Lustre is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with Lustre; if not, write to the Free Software
 *   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#define DEBUG_SUBSYSTEM S_LLITE

#include <linux/module.h>
#include <linux/types.h>
#include <linux/random.h>
#include <linux/version.h>
#include <linux/lustre_lite.h>
#include <linux/lustre_ha.h>
#include <linux/lustre_dlm.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/lprocfs_status.h>
#include <linux/obd_support.h>
#include "llite_internal.h"

struct super_block * ll_get_sb(struct file_system_type *fs_type,
                               int flags, const char *devname, void * data)
{
        /* calls back in fill super */
        return get_sb_nodev(fs_type, flags, data, ll_fill_super);
}

struct super_block * lustre_get_sb(struct file_system_type *fs_type,
                               int flags, const char *devname, void * data)
{
        /* calls back in fill super */
        return get_sb_nodev(fs_type, flags, data, lustre_fill_super);
}

static kmem_cache_t *ll_inode_cachep;

static struct inode *ll_alloc_inode(struct super_block *sb)
{
        struct ll_inode_info *lli;
        lprocfs_counter_incr((ll_s2sbi(sb))->ll_stats, LPROC_LL_ALLOC_INODE);
        OBD_SLAB_ALLOC(lli, ll_inode_cachep, SLAB_KERNEL, sizeof *lli);
        if (lli == NULL)
                return NULL;

        inode_init_once(&lli->lli_vfs_inode);
        ll_lli_init(lli);

        return &lli->lli_vfs_inode;
}

static void ll_destroy_inode(struct inode *inode)
{
        struct ll_inode_info *ptr = ll_i2info(inode);
        OBD_SLAB_FREE(ptr, ll_inode_cachep, sizeof(*ptr));
}

static void init_once(void * foo, kmem_cache_t * cachep, unsigned long flags)
{
        struct ll_inode_info *lli = foo;

        if ((flags & (SLAB_CTOR_VERIFY|SLAB_CTOR_CONSTRUCTOR)) ==
            SLAB_CTOR_CONSTRUCTOR)
                inode_init_once(&lli->lli_vfs_inode);
}

int ll_init_inodecache(void)
{
        ll_inode_cachep = kmem_cache_create("lustre_inode_cache",
                                            sizeof(struct ll_inode_info),
                                            0, SLAB_HWCACHE_ALIGN,
                                            init_once, NULL);
        if (ll_inode_cachep == NULL)
                return -ENOMEM;
        return 0;
}

void ll_destroy_inodecache(void)
{
        LASSERTF(kmem_cache_destroy(ll_inode_cachep) == 0,
                 "ll_inode_cache: not all structures were freed\n");
}

static void ll_umount_lustre(struct super_block *sb)
{
        struct ll_sb_info *sbi = ll_s2sbi(sb);
        ll_gns_check_mounts(sbi, LL_GNS_UMOUNT);
}

/* exported operations */
struct super_operations lustre_super_operations =
{
        .alloc_inode   = ll_alloc_inode,
        .destroy_inode = ll_destroy_inode,
        .clear_inode   = ll_clear_inode,
        .put_super     = lustre_put_super,
        .statfs        = ll_statfs,
        .umount_begin  = ll_umount_begin,
        .umount_lustre = ll_umount_lustre
};

struct file_system_type lustre_lite_fs_type = {
        .owner        = THIS_MODULE,
        .name         = "lustre_lite",
        .get_sb       = ll_get_sb,
        .kill_sb      = kill_anon_super,
        .fs_flags     = FS_REVAL_DOT|FS_BINARY_MOUNTDATA,
};

struct file_system_type lustre_fs_type = {
        .owner        = THIS_MODULE,
        .name         = "lustre",
        .get_sb       = lustre_get_sb,
        .kill_sb      = kill_anon_super,
        .fs_flags     = FS_REVAL_DOT|FS_BINARY_MOUNTDATA,
};

static int __init init_lustre_lite(void)
{
        int rc, cleanup = 0;

        printk(KERN_INFO "Lustre: Lustre Lite Client File System; "
               "info@clusterfs.com\n");

        rc = ll_init_inodecache();
        if (rc)
                return -ENOMEM;

        ll_file_data_slab = kmem_cache_create("ll_file_data",
                                              sizeof(struct ll_file_data), 0,
                                              SLAB_HWCACHE_ALIGN, NULL, NULL);
        if (ll_file_data_slab == NULL) {
                rc = -ENOMEM;
                goto out;
        }
        ll_intent_slab = kmem_cache_create("lustre_intent_data",
                                    	   sizeof(struct lustre_intent_data),
                                           0, SLAB_HWCACHE_ALIGN, NULL,
                                           NULL);
        if (ll_intent_slab == NULL) {
                kmem_cache_destroy(ll_file_data_slab);
                ll_destroy_inodecache();
                return -ENOMEM;
        }


        proc_lustre_fs_root = proc_lustre_root ?
                              proc_mkdir("llite", proc_lustre_root) : NULL;

        rc = register_filesystem(&lustre_lite_fs_type);
        if (rc)
                goto out;
        cleanup = 1;

        rc = register_filesystem(&lustre_fs_type);
        if (rc)
                goto out;
        cleanup = 2;

        rc = ll_gns_start_thread();
        if (rc)
                goto out;
        return 0;
out:
        switch (cleanup) {
        case 2:
                unregister_filesystem(&lustre_fs_type);
        case 1:
                unregister_filesystem(&lustre_lite_fs_type);
        case 0:
               ll_destroy_inodecache();
        }
        return rc;
}

static void __exit exit_lustre_lite(void)
{
        unregister_filesystem(&lustre_fs_type);
        unregister_filesystem(&lustre_lite_fs_type);

        ll_gns_stop_thread();
        ll_destroy_inodecache();
        
        LASSERTF(kmem_cache_destroy(ll_file_data_slab) == 0,
                 "couldn't destroy ll_file_data slab\n");
        LASSERTF(kmem_cache_destroy(ll_intent_slab) == 0,
                 "couldn't destroy ll_intent_slab slab\n");
        if (proc_lustre_fs_root) {
                lprocfs_remove(proc_lustre_fs_root);
                proc_lustre_fs_root = NULL;
        }
}

MODULE_AUTHOR("Cluster File Systems, Inc. <info@clusterfs.com>");
MODULE_DESCRIPTION("Lustre Lite Client File System");
MODULE_LICENSE("GPL");

module_init(init_lustre_lite);
module_exit(exit_lustre_lite);
