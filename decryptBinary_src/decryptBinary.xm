#import <Foundation/Foundation.h>
#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <string.h>
#import <fcntl.h>
#import <errno.h>

static NSString* getOutputPath(const char* appName) {
    // Get Documents directory (more accessible)
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *documentsPath = paths[0];
        NSLog(@"[DecryptBinary] Using Documents path: %@", documentsPath);
        return [NSString stringWithFormat:@"%@/%s.decrypted", documentsPath, appName];
    }

    return nil;
}

static void dumpBinary(const char* targetName, const char* appName) {
    uint32_t imageCount = _dyld_image_count();
    const struct mach_header *targetHeader = NULL;
    const char *targetPath = NULL;

    // Find target module
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imagePath = _dyld_get_image_name(i);
        if (strstr(imagePath, targetName)) {
            targetHeader = _dyld_get_image_header(i);
            targetPath = imagePath;
            break;
        }
    }

    if (!targetHeader || !targetPath) {
        NSLog(@"[DecryptBinary] Cannot find module: %s", targetName);
        return;
    }

    NSString *outputPath = getOutputPath(appName);
    if (outputPath == nil) {
        NSLog(@"[DecryptBinary] Cannot determine output path");
        return;
    }
    NSLog(@"[DecryptBinary] Source path: %s", targetPath);
    NSLog(@"[DecryptBinary] Output path: %@", outputPath);

    // Open files
    int oldFile = open(targetPath, O_RDONLY);
    if (oldFile < 0) {
        NSLog(@"[DecryptBinary] Cannot open source file: %s (errno: %d - %s)", targetPath, errno, strerror(errno));
        return;
    }

    int newFile = open([outputPath UTF8String], O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (newFile < 0) {
        NSLog(@"[DecryptBinary] Cannot open output file: %@ (errno: %d - %s)", outputPath, errno, strerror(errno));
        close(oldFile);
        return;
    }

    NSLog(@"[DecryptBinary] Files opened successfully");

    // Get file size
    struct stat st;
    if (fstat(oldFile, &st) < 0) {
        NSLog(@"[DecryptBinary] Cannot get file size");
        close(oldFile);
        close(newFile);
        return;
    }

    // Copy entire file
    char buffer[4096];
    ssize_t bytesRead;
    off_t totalBytes = 0;
    while ((bytesRead = read(oldFile, buffer, sizeof(buffer))) > 0) {
        write(newFile, buffer, bytesRead);
        totalBytes += bytesRead;
    }

    NSLog(@"[DecryptBinary] Copied %lld bytes", totalBytes);

    // Parse Mach-O header
    BOOL is64bit = NO;
    uint32_t magic = *(uint32_t*)targetHeader;
    uint32_t headerSize = 0;

    if (magic == MH_MAGIC || magic == MH_CIGAM) {
        is64bit = NO;
        headerSize = sizeof(struct mach_header);
    } else if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        is64bit = YES;
        headerSize = sizeof(struct mach_header_64);
    } else {
        NSLog(@"[DecryptBinary] Unknown magic: 0x%x", magic);
        close(oldFile);
        close(newFile);
        return;
    }

    uint32_t ncmds = 0;
    if (is64bit) {
        ncmds = ((struct mach_header_64*)targetHeader)->ncmds;
    } else {
        ncmds = targetHeader->ncmds;
    }

    // Find encryption info
    uint32_t offset = headerSize;
    uint32_t cryptoffset = 0;
    uint32_t cryptsize = 0;
    uint32_t cryptoffset_offset = 0;

    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command *lc = (struct load_command*)((uint8_t*)targetHeader + offset);

        if (lc->cmd == LC_ENCRYPTION_INFO || lc->cmd == LC_ENCRYPTION_INFO_64) {
            struct encryption_info_command *eic = (struct encryption_info_command*)lc;
            cryptoffset = eic->cryptoff;
            cryptsize = eic->cryptsize;
            cryptoffset_offset = offset + 16; // offset to cryptid field
            break;
        }

        offset += lc->cmdsize;
    }

    // Decrypt
    if (cryptoffset_offset > 0 && cryptsize > 0) {
        NSLog(@"[DecryptBinary] Found encrypted segment at offset: 0x%x, size: 0x%x", cryptoffset, cryptsize);

        // Clear cryptid in the new file
        uint32_t zero = 0;
        lseek(newFile, cryptoffset_offset, SEEK_SET);
        write(newFile, &zero, sizeof(zero));

        // Overwrite encrypted section with decrypted data from memory
        lseek(newFile, cryptoffset, SEEK_SET);
        ssize_t written = write(newFile, (uint8_t*)targetHeader + cryptoffset, cryptsize);

        if (written == cryptsize) {
            NSLog(@"[DecryptBinary] Successfully decrypted %d bytes", cryptsize);
        } else {
            NSLog(@"[DecryptBinary] Warning: only wrote %zd of %d bytes", written, cryptsize);
        }
    } else {
        NSLog(@"[DecryptBinary] No encryption found or already decrypted");
    }

    fchmod(newFile, 0644);

    NSLog(@"[DecryptBinary] ======= DUMP COMPLETE =======");
    NSLog(@"[DecryptBinary] Saved to: %@", outputPath);

    close(oldFile);
    close(newFile);
}

static NSString* getCurrentBundleID() {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundleID = [mainBundle bundleIdentifier];
    return bundleID;
}

static NSString* getCurrentAppName() {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *appName = [mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (!appName) {
        appName = [mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
    }
    return appName;
}

%ctor {
    NSString *bundleID = getCurrentBundleID();
    NSString *appName = getCurrentAppName();

    NSLog(@"[DecryptBinary] ======= TWEAK LOADED =======");
    NSLog(@"[DecryptBinary] PID: %d", getpid());
    NSLog(@"[DecryptBinary] App Name: %@", appName);
    NSLog(@"[DecryptBinary] Bundle ID: %@", bundleID);
    NSLog(@"[DecryptBinary] Process: %s", _dyld_get_image_name(0));

    // Since MobileSubstrate only injects into the target app via Filter,
    // we can dump immediately when loaded
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[DecryptBinary] ======= DUMP TRIGGERED =======");
        NSLog(@"[DecryptBinary] Target Bundle ID: %@", bundleID);

        const char *executablePath = _dyld_get_image_name(0);
        const char *executableName = strrchr(executablePath, '/');
        if (executableName) executableName++;
        else executableName = executablePath;

        NSLog(@"[DecryptBinary] Dumping executable: %s", executableName);
        dumpBinary(executableName, [appName UTF8String]);

        NSLog(@"[DecryptBinary] ======= DUMP FINISHED =======");
    });
}
