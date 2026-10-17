/*
 * Husk: save and restore the whole machine, so Android boots once ever.
 *
 * Booting Android under emulation costs about ten minutes: dex2oat compiles the
 * system, a hundred services start, and every instruction of it is translated.
 * None of that work is interesting and none of it changes between runs, so the
 * answer is not to make booting faster but to stop doing it. Save the machine
 * once it is up, and every later launch restores RAM and device state from disk
 * -- seconds, not minutes, and dex2oat never runs again.
 *
 * The state lands inside vdb (userdata), which is the writable qcow2. vda holds
 * the system image and is effectively read-only; putting snapshots there would
 * grow the file we distribute.
 *
 * Both calls must run under the BQL on the main loop. Saving is asked for from
 * a plain thread, so it hops through a bottom half exactly as the balloon does;
 * the bottom half then already holds the BQL and must not take it again.
 * Loading is different: it runs straight after qemu_init(), which returns with
 * the BQL held by this very thread, so it needs no bottom half at all.
 *
 * Neither call stops the CPUs by hand. save_snapshot() and the load sequence
 * below do it at the points where it is correct to do it, and a stop issued
 * outside those points is not merely redundant -- it is recorded in the state
 * that gets written out, and the machine comes back paused.
 */
#include "qemu/osdep.h"
#include "qemu/main-loop.h"
#include "qemu/error-report.h"
#include "block/aio.h"
#include "qapi/error.h"
#include "migration/snapshot.h"
#include "system/runstate.h"

#include "hw/qdev-core.h"
#include "hw/sysbus.h"
#include "monitor/qdev.h"
#include "qobject/qdict.h"

#include "husk-snapshot.h"

#define HUSK_SNAPSHOT_NAME "husk-ready"
/* Node name of the userdata qcow2. Without naming a target QEMU writes the
 * VM state to whichever snapshot-capable drive comes first, which is the
 * UEFI variable store -- a 64 MiB file that grew past 2.6 GB. */
#define HUSK_VMSTATE_NODE "huskvmstate"

/*
 * Only userdata takes part in the snapshot.
 *
 * With no device list QEMU snapshots every snapshot-capable drive -- userdata,
 * the system image and the UEFI variable store -- and load_snapshot then
 * demands the snapshot be present on all of them. That makes a shipped
 * snapshot impossible: the system image arrives from a release and the
 * variable store from the app bundle, neither carrying one, so the restore
 * would always fail.
 *
 * Restricting it to userdata is also correct rather than merely convenient.
 * /system is mounted read-only, so the system image at restore time is
 * byte-identical to the one the snapshot was taken against, and the firmware
 * variable store is not needed once the machine is past firmware.
 */
static strList husk_snapshot_devices = {
    .value = (char *)HUSK_VMSTATE_NODE,
    .next  = NULL,
};

/*
 * No explicit device list.
 *
 * The first attempt named "vdb" and QEMU answered "No block device node 'vdb'":
 * that is the -drive id, while the devices argument wants block *node* names,
 * which are auto-generated here. Letting QEMU choose picks every snapshot-capable
 * disk by itself, which is what plain savevm does anyway.
 */

static husk_snapshot_cb husk_cb;

static void husk_report(bool ok, const char *what, Error *err)
{
    fprintf(stderr, "[husk-snap] %s %s%s%s\n", what, ok ? "OK" : "FAILED",
            err ? ": " : "", err ? error_get_pretty(err) : "");
    if (husk_cb) {
        husk_cb(ok, what);
    }
}

/*
 * HuskDroid: the sound card is a USB device plugged in at run time, never part of a saved machine.
 *
 * Both sound devices this guest can drive refuse to be saved (virtio-sound and usb-audio are
 * .unmigratable), and virtio-sound also stalls after its first few buffers. usb-audio plays
 * properly, and a USB device can be pulled and put back without the guest's help -- to Android it
 * is a USB headset unplugged for the moment of the save. So it is never on the command line: it is
 * attached once the machine is booted or restored, and detached around every save.
 */
#define HUSK_SOUND_ID "husksnd"
static bool husk_sound_wanted;

static DeviceState *husk_sound_device(void)
{
    return qdev_find_recursive(sysbus_get_default(), HUSK_SOUND_ID);
}

static bool husk_sound_plug(void)
{
    Error *err = NULL;
    QDict *opts;
    DeviceState *dev;

    if (husk_sound_device()) {
        return true;
    }
    opts = qdict_new();
    qdict_put_str(opts, "driver", "usb-audio");
    qdict_put_str(opts, "audiodev", "huskaudio");
    qdict_put_str(opts, "bus", "usb-bus.0");
    qdict_put_str(opts, "id", HUSK_SOUND_ID);
    dev = qdev_device_add_from_qdict(opts, false, &err);
    qobject_unref(opts);
    if (!dev) {
        fprintf(stderr, "[husk-snd] attaching the USB sound card FAILED: %s\n",
                err ? error_get_pretty(err) : "?");
        error_free(err);
        return false;
    }
    object_unref(OBJECT(dev));
    fprintf(stderr, "[husk-snd] USB sound card attached\n");
    return true;
}

static void husk_sound_unplug(void)
{
    Error *err = NULL;
    DeviceState *dev = husk_sound_device();

    if (!dev) {
        return;
    }
    qdev_unplug(dev, &err);
    fprintf(stderr, "[husk-snd] USB sound card detached%s%s\n",
            err ? ": " : "", err ? error_get_pretty(err) : "");
    error_free(err);
}

bool husk_sound_attach(void)
{
    husk_sound_wanted = true;
    return husk_sound_plug();
}

static void husk_save_bh(void *opaque)
{
    Error *err = NULL;
    bool ok;

    if (husk_sound_wanted) {
        husk_sound_unplug();
    }

    /*
     * No bql_lock() here. A bottom half on the main AIO context already runs
     * with the BQL held, and taking it a second time aborts the process:
     *
     *   ERROR: cpus.c:556:bql_lock_impl: assertion failed: (!bql_locked())
     *
     * No vm_stop()/vm_start() either, tempting as it looks. save_snapshot()
     * records the run state it found on entry, calls global_state_store() and
     * vm_stop(RUN_STATE_SAVE_VM) itself, and restores that state on the way
     * out. Stopping the machine first means the state it records -- and writes
     * into the snapshot -- is "stopped", so the restored machine comes back
     * paused and the screen never moves again.
     */
    ok = save_snapshot(HUSK_SNAPSHOT_NAME, true, HUSK_VMSTATE_NODE,
                       true, &husk_snapshot_devices, &err);

    if (husk_sound_wanted) {
        husk_sound_plug();
    }
    husk_report(ok, "save", err);
    error_free(err);
}

void husk_snapshot_save(husk_snapshot_cb cb)
{
    husk_cb = cb;
    aio_bh_schedule_oneshot(qemu_get_aio_context(), husk_save_bh, NULL);
}

bool husk_snapshot_load_at_startup(void)
{
    Error *err = NULL;
    RunState saved;
    bool ok;

    /*
     * Called straight after qemu_init(), which returns with the BQL held by
     * this thread -- upstream's main() unlocks it on the next line -- so there
     * is no bottom half here and no lock to take.
     *
     * The machine is however already *running* by this point: qemu_init() ends
     * in qmp_x_exit_preconfig(), which calls qmp_cont() unless -S was passed,
     * and vCPU threads are executing guest code. Loading a snapshot underneath
     * running vCPUs is not something load_snapshot() defends against, so stop
     * them first and resume afterwards -- the same order -loadvm uses.
     */
    saved = runstate_get();
    vm_stop(RUN_STATE_RESTORE_VM);

    ok = load_snapshot(HUSK_SNAPSHOT_NAME, HUSK_VMSTATE_NODE,
                       true, &husk_snapshot_devices, &err);
    if (!ok) {
        /*
         * Not an error worth shouting about: the common case is simply that no
         * snapshot exists yet, on the very first run. Put the machine back the
         * way it was and let it boot.
         */
        fprintf(stderr, "[husk-snap] no snapshot restored (%s); booting normally\n",
                err ? error_get_pretty(err) : "none found");
        error_free(err);
        vm_resume(saved);
        return false;
    }

    fprintf(stderr, "[husk-snap] restored '%s' -- Android is already booted\n",
            HUSK_SNAPSHOT_NAME);
    /*
     * Resume running whatever the machine was doing before, rather than
     * whatever state the snapshot happened to be taken in.
     */
    load_snapshot_resume(RUN_STATE_RUNNING);
    return true;
}
