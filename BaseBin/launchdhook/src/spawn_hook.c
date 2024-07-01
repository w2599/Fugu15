#pragma clang diagnostic push
#pragma ide diagnostic ignored "bugprone-reserved-identifier"
#include <spawn.h>
#include "../systemhook/src/common.h"
#import "../systemhook/src/envbuf.h"
#include "boomerang.h"
#include "crashreporter.h"
#include "update.h"
#include <libjailbreak/log.h>
#include <libjailbreak/util.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <sys/param.h>
#include <sys/mount.h>

#include <libjailbreak/kernel.h>
#include <libjailbreak/deny.h>

#define POSIX_SPAWN_START_SUSPENDED_CUSTOMIZED 0x2000 // _POSIX_SPAWN_ALLOW_DATA_EXEC(0x2000) only used in DEBUG/DEVELOPMENT kernel

#define POSIX_SPAWN_PROC_TYPE_DRIVER 0x700

int posix_spawnattr_getprocesstype_np(const posix_spawnattr_t *__restrict, int *__restrict) __API_AVAILABLE(macos(10.8), ios(6.0));

extern char **environ;

extern int systemwide_trust_binary(const char *binaryPath, xpc_object_t preferredArchsArray);
extern int platform_set_process_debugged(uint64_t pid, bool fullyDebugged);

void *posix_spawn_orig;
extern bool gInEarlyBoot;

void early_boot_done(void)
{
	gInEarlyBoot = false;
}

int posix_spawn_orig_wrapper(pid_t *restrict pidp, const char *restrict path,
                             const posix_spawn_file_actions_t *restrict file_actions,
                             const posix_spawnattr_t *restrict attrp,
                             char *const argv[restrict],
                             char *const envp[restrict]) {
    int (*orig)(pid_t *restrict, const char *restrict, const posix_spawn_file_actions_t *restrict,
                const posix_spawnattr_t *restrict, char *const[restrict], char *const[restrict]) = posix_spawn_orig;

    short flags = 0;
    if (!attrp) {
        posix_spawnattr_getflags(attrp, &flags);
    }
    JBLogDebug("launchd spawn path=%s flags=%x", path, flags);
    if (argv) for (int i = 0; argv[i]; i++) JBLogDebug("\targs[%d] = %s", i, argv[i]);
    if (envp) for (int i = 0; envp[i]; i++) JBLogDebug("\tenvp[%d] = %s", i, envp[i]);

    int pid = 0;
    if (!pidp)
        pidp = &pid;

    // we need to disable the crash reporter during the orig call
    // otherwise the child process inherits the exception ports
    // and this would trip jailbreak detections
    crashreporter_pause();
    int r = orig(pidp, path, file_actions, attrp, argv, envp);
    crashreporter_resume();

    pid = *pidp;

    JBLogDebug("spawn ret=%d pid=%d", r, pid);

    return r;
}

int posix_spawn_hook(pid_t *restrict pidp, const char *restrict path,
                     const posix_spawn_file_actions_t *restrict file_actions,
                     const posix_spawnattr_t *restrict attrp,
                     char *const argv[restrict],
                     char *const envp[restrict]) {
    if (path) {
        char executablePath[1024];
        uint32_t bufsize = sizeof(executablePath);
        _NSGetExecutablePath(&executablePath[0], &bufsize);
        if (!strcmp(path, executablePath)) {
            // This spawn will perform a userspace reboot...
            // Instead of the ordinary hook, we want to reinsert this dylib
            // This has already been done in envp so we only need to call the original posix_spawn

            JBLogDebug("==== USERSPACE REBOOT ====\n");

            // But before, we want to stash the primitives in boomerang
            boomerang_stashPrimitives();

            // Fix Xcode debugging being broken after the userspace reboot
            unmount("/Developer", MNT_FORCE);

            // If there is a pending jailbreak update, apply it now
            const char *stagedJailbreakUpdate = getenv("STAGED_JAILBREAK_UPDATE");
            if (stagedJailbreakUpdate) {
                int r = jbupdate_basebin(stagedJailbreakUpdate);
                unsetenv("STAGED_JAILBREAK_UPDATE");
            }

            posix_spawnattr_t attr;
            if(!attrp) {
                attrp = &attr;
                posix_spawnattr_init(&attr);
            }

            // Suspend launchd and patch GET_TASK_ALLOW in boomerang
            short flags = 0;
            posix_spawnattr_getflags(attrp, &flags);
            posix_spawnattr_setflags(attrp, flags | POSIX_SPAWN_START_SUSPENDED);

            // Always use environ instead of envp, as boomerang_stashPrimitives calls setenv
            // setenv / unsetenv can sometimes cause environ to get reallocated
            // In that case envp may point to garbage or be empty
            // Say goodbye to this process
            return posix_spawn_orig_wrapper(pidp, path, file_actions, attrp, argv, environ);
        }
    }

	// We can't support injection into processes that get spawned before the launchd XPC server is up
	if (gInEarlyBoot) {
		if (!strcmp(path, "/usr/libexec/xpcproxy")) {
			// The spawned process being xpcproxy indicates that the launchd XPC server is up
			// All processes spawned including this one should be injected into
			early_boot_done();
		}
		else {
			return posix_spawn_orig_wrapper(pidp, path, file_actions, attrp, argv, envp);
		}
	}

    if (isBlacklisted(path)) {
        JBLogDebug("blacklisted app %s", path);

		char **envc = envbuf_mutcopy((const char **)envp);

		//choicy may set these 
		envbuf_unsetenv(&envc, "_SafeMode");
		envbuf_unsetenv(&envc, "_MSSafeMode");

        int ret = posix_spawn_orig_wrapper(pidp, path, file_actions, attrp, argv, envc);

		envbuf_free(envc);

        return ret;
    }

    posix_spawnattr_t attr = NULL;
    if (!attrp) {
        attrp = &attr;
        posix_spawnattr_init(&attr);
    }

    short flags = 0;
    posix_spawnattr_getflags(attrp, &flags);

    int proc_type = 0;
    posix_spawnattr_getprocesstype_np(attrp, &proc_type);

    bool suspend = (proc_type != POSIX_SPAWN_PROC_TYPE_DRIVER);

    if (suspend) {
        posix_spawnattr_setflags(attrp, flags | POSIX_SPAWN_START_SUSPENDED_CUSTOMIZED);
//        JBLogDebug("should suspend for patch: %s", path);
    }

    int ret = spawn_hook_common(pidp, path, file_actions, attrp, argv, envp, posix_spawn_orig_wrapper,
                                systemwide_trust_binary, platform_set_process_debugged);

    if (attr) {
        posix_spawnattr_destroy(&attr);
    }

    return ret;
}

// https://opensource.apple.com/source/xnu/xnu-4570.31.3/bsd/sys/spawn_internal.h
struct _posix_spawn_args_desc {
    size_t attr_size;    /* size of attributes block */
    posix_spawnattr_t attrp;        /* pointer to block */
};

int __posix_spawn(pid_t *pidp, const char *path, struct _posix_spawn_args_desc *ad, char *const argv, char *const envp);

int (*orig__posix_spawn)(pid_t *pidp, const char *path, struct _posix_spawn_args_desc *ad, char *const argv,
                         char *const envp);

int new__posix_spawn(pid_t *pidp, const char *path, struct _posix_spawn_args_desc *ad, char *const argv, char *const envp) {
    short flags = 0;
    if (ad && ad->attrp) {
        posix_spawnattr_getflags(&(ad->attrp), &flags);

        if ((flags & POSIX_SPAWN_START_SUSPENDED_CUSTOMIZED) != 0){
            posix_spawnattr_setflags(&(ad->attrp), (flags & ~POSIX_SPAWN_START_SUSPENDED_CUSTOMIZED) | POSIX_SPAWN_START_SUSPENDED);
        }
    }

    // suspend by debugserver or frida
    bool should_resume = (flags & POSIX_SPAWN_START_SUSPENDED) == 0;
    bool should_patch = (flags & POSIX_SPAWN_START_SUSPENDED) != 0 || (flags & POSIX_SPAWN_START_SUSPENDED_CUSTOMIZED) != 0;

    int pid = 0;
    if (!pidp)
        pidp = &pid;
    int ret = orig__posix_spawn(pidp, path, ad, argv, envp);
    pid = *pidp;

    if (ret != 0){
        JBLogDebug("spawn error ret=%d errno=%d err=%s", ret, errno, strerror(errno));
    }

    if (should_patch && ret == 0 && pid > 0) {
        // give get-task-allow entitlement to make dyld respect DYLD_INSERT_LIBRARIES
        // also frida will inject into launchd and inject agent into processes, so should enable jit for it
        proc_csflags_patch(pid);
        if (should_resume){
            kill(pid, SIGCONT);
        }
    }

    return ret;
}

void initSpawnHooks(void) {
    MSHookFunction(&posix_spawn, (void *) posix_spawn_hook, &posix_spawn_orig);
    MSHookFunction(&__posix_spawn, (void *) new__posix_spawn, (void **) &orig__posix_spawn);
}

#pragma clang diagnostic pop
