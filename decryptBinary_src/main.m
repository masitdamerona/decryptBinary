#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <spawn.h>

// libproc declarations (not available in iOS SDK headers)
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

extern char **environ;

// Get all running processes
static NSArray* getRunningProcesses() {
    NSMutableArray *processes = [NSMutableArray array];

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size;

    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) {
        return processes;
    }

    struct kinfo_proc *procs = malloc(size);
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return processes;
    }

    int count = size / sizeof(struct kinfo_proc);
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];

        if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0) {
            if (strstr(pathbuf, ".app/")) {
                NSMutableDictionary *info = [NSMutableDictionary dictionary];
                info[@"pid"] = @(pid);
                info[@"path"] = [NSString stringWithUTF8String:pathbuf];

                // Extract app name from path
                NSString *path = info[@"path"];
                NSArray *components = [path componentsSeparatedByString:@"/"];
                for (NSString *comp in components) {
                    if ([comp hasSuffix:@".app"]) {
                        NSString *appName = [comp stringByReplacingOccurrencesOfString:@".app" withString:@""];
                        info[@"name"] = appName;
                        break;
                    }
                }

                [processes addObject:info];
            }
        }
    }

    free(procs);
    return processes;
}

// Private API interfaces
@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (readonly, nonatomic) NSURL *dataContainerURL;
@property (readonly, nonatomic) NSURL *bundleURL;
@property (readonly, nonatomic) NSString *localizedName;
@property (readonly, nonatomic) NSString *bundleExecutable;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

// Load MobileCoreServices framework and return handle
static void* loadMobileCoreServices(void) {
    void *handle = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    if (!handle) {
        printf("[!] Error: Cannot load MobileCoreServices framework\n");
    }
    return handle;
}

// Launch app by bundle ID using LSApplicationWorkspace
static BOOL launchAppByBundleID(NSString *bundleID) {
    @try {
        void *handle = loadMobileCoreServices();
        if (!handle) {
            return NO;
        }

        // Get LSApplicationWorkspace class
        Class LSApplicationWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!LSApplicationWorkspaceClass) {
            printf("[!] Error: Cannot find LSApplicationWorkspace class\n");
            dlclose(handle);
            return NO;
        }

        // Get default workspace
        id workspace = [LSApplicationWorkspaceClass defaultWorkspace];
        if (!workspace) {
            printf("[!] Error: Cannot get default workspace\n");
            dlclose(handle);
            return NO;
        }

        // Open application with bundle ID
        BOOL result = NO;
        if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
            result = [workspace openApplicationWithBundleID:bundleID];
        }

        dlclose(handle);

        if (result) {
            // Give the app time to launch
            sleep(2);
        }

        return result;
    }
    @catch (NSException *exception) {
        printf("[!] Exception: %s\n", [[exception description] UTF8String]);
        return NO;
    }
}

// List all running apps
static void listApps() {
    NSArray *processes = getRunningProcesses();

    printf("%-8s %-20s %s\n", "PID", "Name", "Path");
    printf("--------------------------------------------------------------------------------\n");

    for (NSDictionary *proc in processes) {
        printf("%-8d %-20s %s\n",
               [proc[@"pid"] intValue],
               [proc[@"name"] UTF8String] ?: "unknown",
               [proc[@"path"] UTF8String]);
    }

    printf("\n");
}

// Print usage
static void printUsage() {
    printf("decryptbin - iOS App Binary Decryption Tool\n\n");
    printf("Usage:\n");
    printf("  decryptbin -l                List running apps\n");
    printf("  decryptbin -d <BundleID>   Dump binary (bundle ID)\n");
    printf("  decryptbin -h                Show this help\n\n");
    printf("Examples:\n");
    printf("  decryptbin -l\n");
    printf("  decryptbin -d com.apple.mobilesafari\n");
    printf("Output:\n");
    printf("  Decrypted binary will be saved to: <data_directory>/Documents/<appname>.decrypted\n\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Check if running as root
        if (getuid() != 0) {
            printf("[!] Warning: Not running as root. Some features may not work.\n\n");
        }

        if (argc < 2) {
            printUsage();
            return 1;
        }

        NSString *option = [NSString stringWithUTF8String:argv[1]];

        if ([option isEqualToString:@"-l"] || [option isEqualToString:@"--list"]) {
            // List apps
            listApps();

        } else if ([option isEqualToString:@"-d"] || [option isEqualToString:@"--dump"]) {
            // Dump by identifier
            if (argc < 3) {
                printf("[!] Error: Missing app identifier\n");
                printUsage();
                return 1;
            }

            NSString *bundleID = [NSString stringWithUTF8String:argv[2]];

            if (!bundleID) {
                printf("[!] Error: Cannot find bundle ID for: %s\n", argv[2]);
                printf("[*] Use -l to list running apps\n");
                return 1;
            }

            printf("[*] Target Bundle ID: %s\n", [bundleID UTF8String]);

            // Print app information using LSApplicationProxy
            NSString *executableName = nil;
            NSString *dataDirectory = nil;
            NSString *bundlePath = nil;
            NSString *appName = nil;

            // Load MobileCoreServices framework
            void *handle = loadMobileCoreServices();
            if (!handle) {
                return 1;
            }

            // Get app information using LSApplicationProxy
            LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
            if (appProxy) {
                // Get bundle path first
                bundlePath = [[appProxy.bundleURL path] stringByStandardizingPath];
                if (!bundlePath) {
                    printf("[!] Error: Bundle path not found\n");
                    return 1;
                }

                appName = appProxy.localizedName; 
                if (!appName) {
                    NSString *lastComponent = [bundlePath lastPathComponent];
                    if (lastComponent) {
                        appName = [lastComponent stringByReplacingOccurrencesOfString:@".app" withString:@""];
                    }
                }
                if (!appName) {
                    printf("[!] Error: Cannot determine app name\n");
                    return 1;
                }
                printf("[*] App Name: %s\n", [appName UTF8String]);
                printf("[*] Bundle Path: %s\n", [bundlePath UTF8String]);

                executableName = appProxy.bundleExecutable;
                if (!executableName) {
                    printf("[!] Error: Cannot determine executable name\n");
                    return 1;
                }
                printf("[*] Executable Name: %s\n", [executableName UTF8String]);
                
                dataDirectory = [[appProxy.dataContainerURL path] stringByStandardizingPath];
                if (!dataDirectory) {
                    printf("[!] Error: Data directory not found or inaccessible\n");
                    return 1;
                }
                printf("[*] Data Directory: %s\n", [dataDirectory UTF8String]);
                
            } else {
                printf("[!] Error: Could not get application proxy for %s\n", [bundleID UTF8String]);
                return 1;
            }
            
            // Close the framework handle
            dlclose(handle);

            // Create dynamic plist filter for MobileSubstrate
#ifdef PLIST_PATH
            NSString *plistPath = @PLIST_PATH;
#else
            NSString *plistPath = @"/Library/MobileSubstrate/DynamicLibraries/decryptBinaryDylib.plist";
#endif
            NSDictionary *filter = @{
                @"Filter": @{
                    @"Bundles": @[bundleID]
                }
            };

            if (![filter writeToFile:plistPath atomically:YES]) {
                printf("[!] Error: Cannot write plist filter file\n");
                return 1;
            }

            printf("[*] Filter configured for: %s\n", [bundleID UTF8String]);
            printf("[*] Reloading MobileSubstrate...\n");

            // Kill any existing app instance to reload with new filter
            pid_t killpid;
            const char *killArgs[] = {"/usr/bin/killall", "-9", [executableName UTF8String], NULL};
            posix_spawn(&killpid, "/usr/bin/killall", NULL, NULL, (char *const *)killArgs, environ);
            waitpid(killpid, NULL, 0);
            sleep(1);

            printf("[*] Launching app: %s\n", [bundleID UTF8String]);

            // Launch the app
            if (launchAppByBundleID(bundleID)) {
                printf("[+] App launched successfully\n");
                printf("[*] Waiting for binary dump...\n");

                // Wait 2 seconds for the tweak to dump the binary
                sleep(2);

                // Check if the decrypted binary was created
                NSString *decryptedPath = [NSString stringWithFormat:@"%@/Documents/%@.decrypted",
                                          dataDirectory, appName];

                if ([[NSFileManager defaultManager] fileExistsAtPath:decryptedPath]) {
                    printf("[+] Success: %s\n", [decryptedPath UTF8String]);
                } else {
                    printf("[!] Error: Failed to dump app binary\n");
                    printf("[*] Expected output: %s\n", [decryptedPath UTF8String]);
                }
            } else {
                printf("[!] Error: Failed to launch app\n");
            }

            filter = @{
                @"Filter": @{
                    @"Bundles": @[]
                }
            };

            if (![filter writeToFile:plistPath atomically:YES]) {
                printf("[!] Warning: Cannot reset plist filter file\n");
            }

        } else if ([option isEqualToString:@"-h"] || [option isEqualToString:@"--help"]) {
            printUsage();

        } else {
            printf("[!] Error: Unknown option: %s\n\n", argv[1]);
            printUsage();
            return 1;
        }
    }

    return 0;
}
