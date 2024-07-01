#include <CoreFoundation/CoreFoundation.h>
#include <spawn.h>
#include <xpc/xpc.h>

#include <stdlib.h>
#include <sys/syslog.h>
#define SYSLOG(progname, ...) do {if(strcmp(getprogname(),progname)!=0)break;openlog(progname,LOG_PID,LOG_AUTH);syslog(LOG_DEBUG, __VA_ARGS__);closelog();} while(0)

extern char HOOK_DYLIB_PATH[];
extern char *JB_BootUUID;
extern char *JB_RootPath;

bool stringStartsWith(const char *str, const char* prefix);
bool stringEndsWith(const char* str, const char* suffix);

int resolvePath(const char *file, const char *searchPath, int (^attemptHandler)(char *path));
int spawn_hook_common(pid_t *restrict pid, const char *restrict path,
					   const posix_spawn_file_actions_t *restrict file_actions,
					   const posix_spawnattr_t *restrict attrp,
					   char *const argv[restrict],
					   char *const envp[restrict],
					   void *orig,
					   int (*trust_binary)(const char *path, xpc_object_t preferredArchsArray),
					   int (*set_process_debugged)(uint64_t pid, bool fullyDebugged));