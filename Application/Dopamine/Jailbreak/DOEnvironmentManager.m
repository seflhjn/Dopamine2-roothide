//
//  EnvironmentManager.m
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import "DOEnvironmentManager.h"

#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <libgrabkernel/libgrabkernel.h>
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
            const char *jbRoot = jbclient_get_jbroot();
            gSystemInfo.jailbreakInfo.rootPath = jbRoot ? strdup(jbRoot) : NULL;
        }
        else if ([self isInstalledThroughTrollStore]) {
            [self locateJailbreakRoot];
        }
    }
    return self;
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
    if (!gSystemInfo.jailbreakInfo.rootPath) {
        NSString *activePrebootPath = [self activePrebootPath];
        
        NSString *randomizedJailbreakPath;
        
        // First attempt at finding jailbreak root, look for Dopamine 2.x path
        for (NSString *subItem in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:activePrebootPath error:nil]) {
            if (subItem.length == 15 && [subItem hasPrefix:@"dopamine-"]) {
                randomizedJailbreakPath = [activePrebootPath stringByAppendingPathComponent:subItem];
                break;
            }
        }
        
        // Second attempt at finding jailbreak root, look for Dopamine 1.x path, but as other jailbreaks use it too, make sure it is Dopamine
        // Some other jailbreaks also commit the sin of creating .installed_dopamine, for these we try to filter them out by checking for their installed_ file
        // If we find this and are sure it's from Dopamine 1.x, rename it so all Dopamine 2.x users will have the same path
        for (NSString *subItem in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:activePrebootPath error:nil]) {
            if (subItem.length == 9 && [subItem hasPrefix:@"jb-"]) {
                NSString *candidateLegacyPath = [activePrebootPath stringByAppendingPathComponent:subItem];
                
                BOOL installedDopamine = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.installed_dopamine"]];
                
                if (installedDopamine) {
                    // Hopefully all other jailbreaks that use jb-<UUID>?
                    // These checks exist because of dumb users (and jailbreak developers) creating .installed_dopamine on jailbreaks that are NOT dopamine...
                    BOOL installedNekoJB = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.installed_nekojb"]];
                    BOOL installedDefinitelyNotAGoodName = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.xia0o0o0o_jb_installed"]];
                    BOOL installedPalera1n = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.palecursus_strapped"]];
                    if (installedNekoJB || installedPalera1n || installedDefinitelyNotAGoodName) {
                        continue;
                    }
                    
                    randomizedJailbreakPath = candidateLegacyPath;
                    _bootstrapNeedsMigration = YES;
                }
            }
        }
        
        if (randomizedJailbreakPath) {
            NSString *jailbreakRootPath = [randomizedJailbreakPath stringByAppendingPathComponent:@"procursus"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:jailbreakRootPath]) {
                // This attribute serves as the primary source of what the root path is
                // Anything else in the jailbreak will get it from here
                gSystemInfo.jailbreakInfo.rootPath = strdup(jailbreakRootPath.fileSystemRepresentation);
            }
        }
    }
}

- (void)ensureJailbreakRootExists
{
    [self locateJailbreakRoot];
    
    if (!gSystemInfo.jailbreakInfo.rootPath || _bootstrapNeedsMigration) {
        NSString *activePrebootPath = [self activePrebootPath];

        NSString *characterSet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        NSUInteger stringLen = 6;
        NSMutableString *randomString = [NSMutableString stringWithCapacity:stringLen];
        for (NSUInteger i = 0; i < stringLen; i++) {
            NSUInteger randomIndex = arc4random_uniform((uint32_t)[characterSet length]);
            unichar randomCharacter = [characterSet characterAtIndex:randomIndex];
            [randomString appendFormat:@"%C", randomCharacter];
        }
        
        NSString *randomJailbreakFolderName = [NSString stringWithFormat:@"dopamine-%@", randomString];
        NSString *randomizedJailbreakPath = [activePrebootPath stringByAppendingPathComponent:randomJailbreakFolderName];
        NSString *jailbreakRootPath = [randomizedJailbreakPath stringByAppendingPathComponent:@"procursus"];
        
        if (_bootstrapNeedsMigration) {
            NSString *oldRandomizedJailbreakPath = [[NSString stringWithUTF8String:gSystemInfo.jailbreakInfo.rootPath] stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] moveItemAtPath:oldRandomizedJailbreakPath toPath:randomizedJailbreakPath error:nil];
        }
        else {
            if (![[NSFileManager defaultManager] fileExistsAtPath:jailbreakRootPath]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootPath withIntermediateDirectories:YES attributes:nil error:nil];
            }
        }
        
        gSystemInfo.jailbreakInfo.rootPath = strdup(jailbreakRootPath.UTF8String);
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

- (BOOL)isJailbroken
{
    static BOOL jailbroken = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t csFlags = 0;
        csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));
        jailbroken = csFlags & CS_PLATFORM_BINARY;
    });
    return jailbroken;
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
    if (orgUser == 0 && orgGroup == 0) {
        rootBlock();
        return;
    }

    int ur = 0, gr = 0;
    if (orgUser != 0) ur = setuid(0);
    if (orgGroup != 0) gr = setgid(0);
    if (ur == 0 && gr == 0) {
        rootBlock();
    }

    if (ur == 0 && orgUser != 0) seteuid(orgUser);
    if (gr == 0 && orgGroup != 0) setegid(orgGroup);
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

- (void)reboot
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            reboot3(0x8000000000000000, 0);
        }];
    }];
}

- (BOOL)isTweakInjectionEnabled
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:NSJBRootPath(@"/basebin/.safe_mode")];
}

- (void)setTweakInjectionEnabled:(BOOL)enabled
{
    NSString *safeModePath = NSJBRootPath(@"/basebin/.safe_mode");
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
    return [[NSFileManager defaultManager] fileExistsAtPath:NSJBRootPath(@"/basebin/.idownloadd_enabled")];
}

- (void)setIDownloadEnabled:(BOOL)enabled
{
    NSString *idownloaddEnabledPath = NSJBRootPath(@"/basebin/.idownloadd_enabled");
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                if (enabled) {
                    [[NSData data] writeToFile:idownloaddEnabledPath atomically:YES];
                    exec_cmd(JBRootPath("/usr/bin/launchctl"), "load", JBRootPath("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
                }
                else {
                    [[NSFileManager defaultManager] removeItemAtPath:idownloaddEnabledPath error:nil];
                    exec_cmd(JBRootPath("/usr/bin/launchctl"), "unload", JBRootPath("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
                }
            }];
        }];
    }
}

- (BOOL)isJailbreakHidden
{
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
}

- (void)setJailbreakHidden:(BOOL)hidden
{
    if (hidden && ![self isJailbroken] && getuid() != 0) {
        [self runTrollStoreAction:@"hide-jailbreak"];
        return;
    }
    
    BOOL alreadyHidden = [self isJailbreakHidden];
    if (hidden != alreadyHidden) {
        if (hidden) {
            [[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:@"/basebin/.fakelib/dyld" error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:@"/basebin/.fakelib/systemhook.dylib" error:nil];
            carbonCopy(NSJBRootPath(@"/basebin/.dyld.orig"), NSJBRootPath(@"/basebin/.fakelib/dyld"));
        }
        else {
            [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb" withDestinationPath:NSJBRootPath(@"/") error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:@"/basebin/.fakelib/dyld" error:nil];
            carbonCopy(NSJBRootPath(@"/basebin/.dyld.patched"), NSJBRootPath(@"/basebin/.fakelib/dyld"));
            carbonCopy(NSJBRootPath(@"/basebin/systemhook.dylib"), NSJBRootPath(@"/basebin/systemhook.dylib"));
        }
    }
}

- (NSString *)accessibleKernelPath
{
    if ([self isInstalledThroughTrollStore]) {
        NSString *kernelcachePath = [[self activePrebootPath] stringByAppendingPathComponent:@"System/Library/Caches/com.apple.kernelcaches/kernelcache"];
        return kernelcachePath;
    }
    else {
        NSString *kernelInApp = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelInApp]) {
            return kernelInApp;
        }
        
        [[DOUIManager sharedInstance] sendLog:@"Downloading Kernel" debug:NO];
        NSString *kernelcachePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kernelcache"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            if (grabkernel((char *)kernelcachePath.fileSystemRepresentation, 0) != 0) return nil;
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
    cpu_subtype_t cpuFamily = 0;
    size_t cpuFamilySize = sizeof(cpuFamily);
    sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
    if (cpuFamily == CPUFAMILY_ARM_TYPHOON) return false; // A8X is unsupported for now (due to 4k page size)
    
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
