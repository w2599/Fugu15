//
//  EnvironmentManager.m
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import "DOEnvironmentManager.h"

#import <sys/sysctl.h>
#include <sys/mount.h>
#import <mach-o/dyld.h>
#import <libgrabkernel2/libgrabkernel2.h>
#import <libjailbreak/info.h>
#import <libjailbreak/codesign.h>
#import <libjailbreak/util.h>
#import <libjailbreak/machine_info.h>
#import <libjailbreak/carboncopy.h>

#import <IOKit/IOKitLib.h>
#import "DOUIManager.h"
#import "DOExploitManager.h"
#import "NSData+Hex.h"

int reboot3(uint64_t flags, ...);

@implementation DOEnvironmentManager

@synthesize bootManifestHash = _bootManifestHash;

+ (instancetype)sharedManager
{
    static DOEnvironmentManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DOEnvironmentManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bootstrapNeedsMigration = NO;
        _bootstrapper = [[DOBootstrapper alloc] init];
        if ([self isJailbroken]) {
            gSystemInfo.jailbreakInfo.rootPath = strdup(jbclient_get_jbroot() ?: "");
        }
        else if ([self isInstalledThroughTrollStore]) {
            [self locateJailbreakRoot];
        }
    }
    return self;
}

- (NSString *)nightlyHash
{
#ifdef NIGHTLY
    return [NSString stringWithUTF8String:COMMIT_HASH];
#else
    return nil;
#endif
}

- (NSString *)appVersion
{
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

- (NSString *)appVersionDisplayString
{
    NSString *nightlyHash = [self nightlyHash];
    if (nightlyHash) {
        return [NSString stringWithFormat:@"%@~%@", self.appVersion, [nightlyHash substringToIndex:6]];
    }
    else {
        return [self appVersion];
    }
}

- (NSData *)bootManifestHash
{
    if (!_bootManifestHash) {
        io_registry_entry_t registryEntry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
        if (registryEntry) {
            _bootManifestHash = (__bridge NSData *)IORegistryEntryCreateCFProperty(registryEntry, CFSTR("boot-manifest-hash"), NULL, 0);
        }
    }
    return _bootManifestHash;
}

- (NSString *)activePrebootPath
{
    return [@"/private/preboot" stringByAppendingPathComponent:[self bootManifestHash].hexString];
}

- (void)locateJailbreakRoot
{
    if(gSystemInfo.jailbreakInfo.rootPath) free(gSystemInfo.jailbreakInfo.rootPath);
    
    NSString* jbroot_path = find_jbroot();
    if(jbroot_path) {
        gSystemInfo.jailbreakInfo.rootPath = strdup(jbroot_path.fileSystemRepresentation);
        gSystemInfo.jailbreakInfo.jbrand = jbrand();
    }
}

- (BOOL)isArm64e
{
    cpu_subtype_t cpusubtype = 0;
    size_t len = sizeof(cpusubtype);
    if (sysctlbyname("hw.cpusubtype", &cpusubtype, &len, NULL, 0) == -1) { return NO; }
    return (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
}

- (NSString *)versionSupportString
{
    if ([self isArm64e]) {
        return @"iOS 15.0 - 16.5.1 (arm64e)";
    }
    else {
        return @"iOS 15.0 - 16.6.1 (arm64)";
    }
}

- (BOOL)isInstalledThroughTrollStore
{
    static BOOL trollstoreInstallation = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* trollStoreMarkerPath = [[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_TrollStore"];
        trollstoreInstallation = [[NSFileManager defaultManager] fileExistsAtPath:trollStoreMarkerPath];
    });
    return trollstoreInstallation;
}

- (BOOL)isRootlessDopamineJailbroken
{
     struct statfs fs;
     int sfsret = statfs("/usr/lib", &fs);
     if (sfsret == 0) {
         return strcmp(fs.f_mntonname, "/usr/lib")==0;
     }
     return NO;
}

- (BOOL)isJailbroken
{
    if([self isRootlessDopamineJailbroken])
        return NO;
    
    static BOOL jailbroken = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t csFlags = 0;
        csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));
        jailbroken = csFlags & CS_PLATFORM_BINARY;
    });
    return jailbroken;
}

- (NSString *)jailbrokenVersion
{
    if (!self.isJailbroken) return nil;

    __block NSString *version;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            version = [NSString stringWithContentsOfFile:NSJBRootPath(@"/basebin/.version") encoding:NSUTF8StringEncoding error:nil];
        }];
    }];
    return version;
}

- (BOOL)isBootstrapped
{
    return (BOOL)jbinfo(rootPath);
}

- (void)runUnsandboxed:(void (^)(void))unsandboxBlock
{
    if ([self isInstalledThroughTrollStore]) {
        unsandboxBlock();
    }
    else if([self isJailbroken]) {
        uint64_t labelBackup = 0;
        jbclient_root_set_mac_label(1, -1, &labelBackup);
        unsandboxBlock();
        jbclient_root_set_mac_label(1, labelBackup, NULL);
    }
    else {
        // Hope that we are already unsandboxed
        unsandboxBlock();
    }
}

- (void)runAsRoot:(void (^)(void))rootBlock
{
    uint32_t orgUser = getuid();
    uint32_t orgGroup = getgid();
    if (geteuid() == 0 && orgGroup == 0) {
        rootBlock();
        return;
    }

    int ur = 0, gr = 0;
    if (orgUser != 0) ur = setuid(0);
    if (orgGroup != 0) gr = setgid(0);
    if (ur == 0 && gr == 0) {
        rootBlock();
    }
    
    if (gr == 0 && orgGroup != 0) setgid(orgGroup);
    if (ur == 0 && orgUser != 0) seteuid(orgUser);
}

- (int)runTrollStoreAction:(NSString *)action
{
    if (![self isInstalledThroughTrollStore]) return -1;
    
    uint32_t selfPathSize = PATH_MAX;
    char selfPath[selfPathSize];
    _NSGetExecutablePath(selfPath, &selfPathSize);
    return exec_cmd_root(selfPath, "trollstore", action.UTF8String, NULL);
}

- (void)respring
{
    [self runAsRoot:^{
        __block int pid = 0;
        __block int r = 0;
        [self runUnsandboxed:^{
            r = exec_cmd_suspended(&pid, JBRootPath("/usr/bin/sbreload"), NULL);
            if (r == 0) {
                kill(pid, SIGCONT);
            }
        }];
        if (r == 0) {
            cmd_wait_for_exit(pid);
        }
    }];
}

- (void)rebootUserspace
{
    [self runAsRoot:^{
        __block int pid = 0;
        __block int r = 0;
        [self runUnsandboxed:^{
            r = exec_cmd_suspended(&pid, JBRootPath("/basebin/jbctl"), "reboot_userspace", NULL);
            if (r == 0) {
                // the original plan was to have the process continue outside of this block
                // unfortunately sandbox blocks kill aswell, so it's a bit racy but works

                // we assume we leave this unsandbox block before the userspace reboot starts
                // to avoid leaking the label, this seems to work in practice
                // and even if it doesn't work, leaking the label is no big deal
                kill(pid, SIGCONT);
            }
        }];
        if (r == 0) {
            cmd_wait_for_exit(pid);
        }
    }];
}

- (void)refreshJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd(JBRootPath("/usr/bin/uicache"), "-a", NULL);
        }];
    }];
}

- (void)unregisterJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSArray *jailbreakApps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSJBRootPath(@"/Applications") error:nil];
            if (jailbreakApps.count) {
                for (NSString *jailbreakApp in jailbreakApps) {
                    NSString *jailbreakAppPath = [NSJBRootPath(@"/Applications") stringByAppendingPathComponent:jailbreakApp];
                    exec_cmd(JBRootPath("/usr/bin/uicache"), "-u", jailbreakAppPath.fileSystemRepresentation, NULL);
                }
            }
        }];
    }];
}

- (void)doReboot
{
    if (reboot3(0x8000000000000000, 0) != 0) {
        sync();
        reboot(0);
    }
}

- (void)reboot
{
    if ([self isJailbroken] == true) {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                [self doReboot];
            }];
        }];
    }else{
        [self runTrollStoreAction:@"reboot"];
    }
}


- (void)changeMobilePassword:(NSString *)newPassword
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSString *dashCommand = [NSString stringWithFormat:@"printf \"%%s\\n\" \"%@\" | %@ usermod 501 -h 0", newPassword, NSJBRootPath(@"/usr/sbin/pw")];
            exec_cmd(JBRootPath("/usr/bin/dash"), "-c", dashCommand.UTF8String, NULL);
        }];
    }];
}

- (NSError*)updateEnvironment
{
    NSString *newBasebinTarPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"];
    int result = jbclient_platform_stage_jailbreak_update(newBasebinTarPath.fileSystemRepresentation);
    if (result == 0) {
        [self rebootUserspace];
        return nil;
    }
    return [NSError errorWithDomain:@"Dopamine" code:result userInfo:nil];
}

- (void)updateJailbreakFromTIPA:(NSString *)tipaPath
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            pid_t pid = 0;
            if (exec_cmd_suspended(&pid, JBRootPath("/basebin/jbctl"), "update", "tipa", tipaPath.fileSystemRepresentation, NULL) == 0) {
                kill(pid, SIGCONT);
            }
        }];
    }];
}

- (BOOL)isTweakInjectionEnabled
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:NSJBRootPath(@"/var/.safe_mode")];
}

- (void)setTweakInjectionEnabled:(BOOL)enabled
{
    NSString *safeModePath = NSJBRootPath(@"/var/.safe_mode");
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                if (enabled) {
                    [[NSFileManager defaultManager] removeItemAtPath:safeModePath error:nil];
                }
                else {
                    [[NSData data] writeToFile:safeModePath atomically:YES];
                }
            }];
        }];
    }
}

- (BOOL)isIDownloadEnabled
{
    __block BOOL isEnabled = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *disabledDict = [NSDictionary dictionaryWithContentsOfFile:@"/var/db/com.apple.xpc.launchd/disabled.plist"];
            NSNumber *idownloaddDisabledNum = disabledDict[@"com.opa334.Dopamine.idownloadd"];
            if (idownloaddDisabledNum) {
                isEnabled = ![idownloaddDisabledNum boolValue];
            }
            else {
                isEnabled = NO;
            }
        }];
    }];
    return isEnabled;
}

- (void)setIDownloadEnabled:(BOOL)enabled needsUnsandbox:(BOOL)needsUnsandbox
{
    void (^updateBlock)(void) = ^{
        if (enabled) {
            exec_cmd_trusted(JBRootPath("/usr/bin/launchctl"), "enable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
        else {
            exec_cmd_trusted(JBRootPath("/usr/bin/launchctl"), "disable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
    };

    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
}

- (void)setIDownloadLoaded:(BOOL)loaded needsUnsandbox:(BOOL)needsUnsandbox
{
    if (loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
    
    void (^updateBlock)(void) = ^{
        if (loaded) {
            exec_cmd(JBRootPath("/usr/bin/launchctl"), "load", JBRootPath("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
        else {
            exec_cmd(JBRootPath("/usr/bin/launchctl"), "unload", JBRootPath("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
    };
    
    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
    
    if (!loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
}

- (NSString *)accessibleKernelPath
{
    if ([self isInstalledThroughTrollStore]) {
        NSString *kernelcachePath = [[self activePrebootPath] stringByAppendingPathComponent:@"System/Library/Caches/com.apple.kernelcaches/kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            return kernelcachePath;
        }
        return @"/System/Library/Caches/com.apple.kernelcaches/kernelcache";
    }
    else {
        NSString *kernelInApp = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelInApp]) {
            return kernelInApp;
        }
        
        [[DOUIManager sharedInstance] sendLog:@"Downloading Kernel" debug:NO];
        NSString *kernelcachePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kernelcache"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            if (grab_kernelcache(kernelcachePath) == false) return nil;
        }
        return kernelcachePath;
    }
}

- (BOOL)isPACBypassRequired
{
    if (![self isArm64e]) return NO;
    
    if (@available(iOS 15.2, *)) {
        return NO;
    }
    return YES;
}

- (BOOL)isPPLBypassRequired
{
    return [self isArm64e];
}

- (BOOL)isSupported
{
    //cpu_subtype_t cpuFamily = 0;
    //size_t cpuFamilySize = sizeof(cpuFamily);
    //sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
    //if (cpuFamily == CPUFAMILY_ARM_TYPHOON) return false; // A8X is unsupported for now (due to 4k page size)
    
    DOExploitManager *exploitManager = [DOExploitManager sharedManager];
    if ([exploitManager availableExploitsForType:EXPLOIT_TYPE_KERNEL].count) {
        if (![self isPACBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PAC].count) {
            if (![self isPPLBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PPL].count) {
                return true;
            }
        }
    }
    
    return false;
}

- (NSError *)prepareBootstrap
{
    __block NSError *errOut;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_bootstrapper prepareBootstrapWithCompletion:^(NSError *error) {
        errOut = error;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    return errOut;
}

- (NSError *)finalizeBootstrap
{
    return [_bootstrapper finalizeBootstrap];
}

- (NSError *)deleteBootstrap
{
    if (![self isJailbroken] && getuid() != 0) {
        int r = [self runTrollStoreAction:@"delete-bootstrap"];
        if (r != 0) {
            // TODO: maybe handle error
        }
        return nil;
    }
    else if ([self isJailbroken]) {
        __block NSError *error;
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                error = [self->_bootstrapper deleteBootstrap];
            }];
        }];
        return error;
    }
    else {
        // Let's hope for the best
        return [_bootstrapper deleteBootstrap];
    }
}

- (NSError *)reinstallPackageManagers
{
    __block NSError *error;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            error = [self->_bootstrapper installPackageManagers];
        }];
    }];
    return error;
}


@end
