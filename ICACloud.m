//
//  ICACloud
//  iCloud Access
//
//  Created by Drew McCormack on 18/01/14.
//  Copyright (c) 2014 Drew McCormack. All rights reserved.
//

#import "ICACloud.h"

NSString *ICAException = @"ICAException";
NSString *ICAErrorDomain = @"ICAErrorDomain";


@interface ICACloudDirectory : NSObject

@property (copy) NSString *path;
@property (copy) NSArray *contents;
@property (copy) NSString *name;

@end


@interface ICACloudFile : NSObject <NSCoding, NSCopying>

@property (copy) NSString *path;
@property (copy) NSString *name;
@property unsigned long long size;

@end


@implementation ICACloudDirectory

- (NSString *)description
{
    NSMutableString *result = [NSMutableString string];
    [result appendFormat:@"%@\r", super.description];
    NSArray *keys = @[@"path", @"name", @"contents"];
    for (NSString *key in keys) {
        [result appendFormat:@"%@: %@; \r", key, [[self valueForKey:key] description]];
    }
    return result;
}

@end


@implementation ICACloudFile

@synthesize path = path;
@synthesize name = name;
@synthesize size = size;

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super init];
    if (self) {
        path = [aDecoder decodeObjectForKey:@"file"];
        name = [aDecoder decodeObjectForKey:@"name"];
        size = [[aDecoder decodeObjectForKey:@"sizeNumber"] unsignedLongLongValue];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [aCoder encodeInteger:0 forKey:@"classVersion"];
    [aCoder encodeObject:path forKey:@"path"];
    [aCoder encodeObject:name forKey:@"name"];
    [aCoder encodeObject:[NSNumber numberWithUnsignedLongLong:size] forKey:@"sizeNumber"];
}

- (id)copyWithZone:(NSZone *)zone
{
    ICACloudFile *copy = [ICACloudFile new];
    copy->path = [self->path copy];
    copy->name = [self->name copy];
    copy->size = self->size;
    return copy;
}

- (NSString *)description
{
    NSMutableString *result = [NSMutableString string];
    [result appendFormat:@"%@\r", super.description];
    NSArray *keys = @[@"path", @"name", @"size"];
    for (NSString *key in keys) {
        [result appendFormat:@"%@: %@; \r", key, [[self valueForKey:key] description]];
    }
    return result;
}

@end


@implementation ICACloud {
    NSFileManager *fileManager;
    NSURL *rootDirectoryURL;
    NSMetadataQuery *metadataQuery;
    NSOperationQueue *operationQueue;
    NSString *ubiquityContainerIdentifier;
    dispatch_queue_t timeOutQueue;
    id ubiquityIdentityObserver;
}

@synthesize rootDirectoryPath = rootDirectoryPath;

// Designated
- (instancetype)initWithUbiquityContainerIdentifier:(NSString *)newIdentifier rootDirectoryPath:(NSString *)newPath
{
    self = [super init];
    if (self) {
        fileManager = [[NSFileManager alloc] init];
        
        rootDirectoryPath = [newPath copy] ? : @"";
        
        operationQueue = [[NSOperationQueue alloc] init];
        operationQueue.maxConcurrentOperationCount = 1;
        
        timeOutQueue = dispatch_queue_create("com.mentalfaculty.cloudaccess.queue.icloudtimeout", DISPATCH_QUEUE_SERIAL);
        
        rootDirectoryURL = nil;
        metadataQuery = nil;
        ubiquityContainerIdentifier = [newIdentifier copy];
        ubiquityIdentityObserver = nil;
        
        [self performInitialPreparation:NULL];
    }
    return self;
}

- (instancetype)initWithUbiquityContainerIdentifier:(NSString *)newIdentifier
{
    return [self initWithUbiquityContainerIdentifier:newIdentifier rootDirectoryPath:nil];
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:ICAException reason:@"iCloud initializer requires container identifier" userInfo:nil];
    return nil;
}

- (void)dealloc
{
    [self removeUbiquityContainerNotificationObservers];
    [self stopMonitoring];
    [operationQueue cancelAllOperations];
}

#pragma mark - User Identity

- (id <NSObject, NSCoding, NSCopying>)identityToken
{
    return [fileManager ubiquityIdentityToken];
}

#pragma mark - Initial Preparation

- (void)performInitialPreparation:(void(^)(NSError *error))completion
{
    if (fileManager.ubiquityIdentityToken) {
        [self setupRootDirectory:^(NSError *error) {
            [self startMonitoringMetadata];
            [self addUbiquityContainerNotificationObservers];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(error);
            });
        }];
    }
    else {
        [self addUbiquityContainerNotificationObservers];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil);
        });
    }
}

#pragma mark - Root Directory

- (void)setupRootDirectory:(void(^)(NSError *error))completion
{
    [operationQueue addOperationWithBlock:^{
        NSURL *newURL = [fileManager URLForUbiquityContainerIdentifier:ubiquityContainerIdentifier];
        newURL = [newURL URLByAppendingPathComponent:rootDirectoryPath];
        rootDirectoryURL = newURL;
        if (!rootDirectoryURL) {
            NSError *error = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileAccessFailed userInfo:@{NSLocalizedDescriptionKey : @"Could not retrieve URLForUbiquityContainerIdentifier. Check container id for iCloud."}];
            [self dispatchCompletion:completion withError:error];
            return;
        }
        
        NSError *error = nil;
        __block BOOL fileExistsAtPath = NO;
        __block BOOL existingFileIsDirectory = NO;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:rootDirectoryURL options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *newURL) {
            fileExistsAtPath = [fileManager fileExistsAtPath:newURL.path isDirectory:&existingFileIsDirectory];
        }];
        if (error) {
            [self dispatchCompletion:completion withError:error];
            return;
        }
        
        if (!fileExistsAtPath) {
            [coordinator coordinateWritingItemAtURL:rootDirectoryURL options:0 error:&error byAccessor:^(NSURL *newURL) {
                [fileManager createDirectoryAtURL:newURL withIntermediateDirectories:YES attributes:nil error:NULL];
            }];
        }
        else if (fileExistsAtPath && !existingFileIsDirectory) {
            [coordinator coordinateWritingItemAtURL:rootDirectoryURL options:NSFileCoordinatorWritingForReplacing error:&error byAccessor:^(NSURL *newURL) {
                [fileManager removeItemAtURL:newURL error:NULL];
                [fileManager createDirectoryAtURL:newURL withIntermediateDirectories:YES attributes:nil error:NULL];
            }];
        }
        
        [self dispatchCompletion:completion withError:error];
    }];
}

- (void)dispatchCompletion:(void(^)(NSError *error))completion withError:(NSError *)error
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (completion) completion(error);
    });
}

- (NSString *)fullPathForPath:(NSString *)path
{
    return [rootDirectoryURL.path stringByAppendingPathComponent:path];
}

#pragma mark - Notifications

- (void)removeUbiquityContainerNotificationObservers
{
    [[NSNotificationCenter defaultCenter] removeObserver:ubiquityIdentityObserver];
    ubiquityIdentityObserver = nil;
}

- (void)addUbiquityContainerNotificationObservers
{
    [self removeUbiquityContainerNotificationObservers];
    
    __weak typeof(self) weakSelf = self;
    ubiquityIdentityObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSUbiquityIdentityDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf stopMonitoring];
        [strongSelf willChangeValueForKey:@"identityToken"];
        [strongSelf didChangeValueForKey:@"identityToken"];
    }];
}

#pragma mark - Connection

- (BOOL)isConnected
{
    return fileManager.ubiquityIdentityToken != nil;
}

- (void)connect:(void(^)(NSError *error))completion
{
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL loggedIn = fileManager.ubiquityIdentityToken != nil;
        NSError *error = loggedIn ? nil : [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeAuthenticationFailure userInfo:@{NSLocalizedDescriptionKey : NSLocalizedString(@"User is not logged into iCloud.", @"")} ];
        if (loggedIn) [self performInitialPreparation:NULL];
        if (completion) completion(error);
    });
}

#pragma mark - Metadata Query to download new files

- (void)startMonitoringMetadata
{
    [self stopMonitoring];
 
    if (!rootDirectoryURL) return;
    
    // Determine downloading key and set the appropriate predicate. This is OS dependent.
    NSPredicate *metadataPredicate = nil;
    
#if (__IPHONE_OS_VERSION_MIN_REQUIRED < 70000) && (__MAC_OS_X_VERSION_MIN_REQUIRED < 1090)
    metadataPredicate = [NSPredicate predicateWithFormat:@"%K = FALSE AND %K = FALSE AND %K BEGINSWITH %@",
        NSMetadataUbiquitousItemIsDownloadedKey, NSMetadataUbiquitousItemIsDownloadingKey, NSMetadataItemPathKey, rootDirectoryURL.path];
#else
    metadataPredicate = [NSPredicate predicateWithFormat:@"%K != %@ AND %K = FALSE AND %K BEGINSWITH %@",
        NSMetadataUbiquitousItemDownloadingStatusKey, NSMetadataUbiquitousItemDownloadingStatusCurrent, NSMetadataUbiquitousItemIsDownloadingKey, NSMetadataItemPathKey, rootDirectoryURL.path];
#endif
    
    metadataQuery = [[NSMetadataQuery alloc] init];
    metadataQuery.notificationBatchingInterval = 10.0;
    metadataQuery.searchScopes = [NSArray arrayWithObject:NSMetadataQueryUbiquitousDataScope];
    metadataQuery.predicate = metadataPredicate;
    
    NSNotificationCenter *notifationCenter = [NSNotificationCenter defaultCenter];
    [notifationCenter addObserver:self selector:@selector(initiateDownloads:) name:NSMetadataQueryDidFinishGatheringNotification object:metadataQuery];
    [notifationCenter addObserver:self selector:@selector(initiateDownloads:) name:NSMetadataQueryDidUpdateNotification object:metadataQuery];
    
    [metadataQuery startQuery];
}

- (void)stopMonitoring
{
    if (!metadataQuery) return;
    
    [metadataQuery disableUpdates];
    [metadataQuery stopQuery];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidFinishGatheringNotification object:metadataQuery];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidUpdateNotification object:metadataQuery];
    
    metadataQuery = nil;
}

- (void)initiateDownloads:(NSNotification *)notif
{
    [metadataQuery disableUpdates];
    
    NSUInteger count = [metadataQuery resultCount];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    for ( NSUInteger i = 0; i < count; i++ ) {
        @autoreleasepool {
            NSURL *url = [metadataQuery valueOfAttribute:NSMetadataItemURLKey forResultAtIndex:i];
            dispatch_async(queue, ^{
                NSError *error;
                [fileManager startDownloadingUbiquitousItemAtURL:url error:&error];
            });
        }
    }

    [metadataQuery enableUpdates];
}

#pragma mark - File Operations

static const NSTimeInterval ICAFileCoordinatorTimeOut = 10.0;

- (NSError *)specializedErrorForCocoaError:(NSError *)cocoaError
{
    NSError *error = cocoaError;
    if ([cocoaError.domain isEqualToString:NSCocoaErrorDomain] && cocoaError.code == NSUserCancelledError) {
        error = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
    }
    return error;
}

- (NSError *)notConnectedError
{
    NSError *error = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeConnectionError userInfo:@{NSLocalizedDescriptionKey : @"Attempted to access iCloud when not connected."}];
    return error;
}

- (void)fileExistsAtPath:(NSString *)path completion:(void(^)(BOOL exists, BOOL isDirectory, NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(NO, NO, [self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block BOOL coordinatorExecuted = NO;
        __block BOOL isDirectory = NO;
        __block BOOL exists = NO;
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });

        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&fileCoordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            exists = [fileManager fileExistsAtPath:newURL.path isDirectory:&isDirectory];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(exists, isDirectory, error);
        });
    }];
}

- (void)contentsOfDirectoryAtPath:(NSString *)path completion:(void(^)(NSArray *contents, NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(nil, [self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        __block NSArray *contents = nil;
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&fileCoordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            
            NSDirectoryEnumerator *dirEnum = [fileManager enumeratorAtPath:[self fullPathForPath:path]];
            if (!dirEnum) fileManagerError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileAccessFailed userInfo:nil];
            
            NSString *filename;
            NSMutableArray *mutableContents = [[NSMutableArray alloc] init];
            while ((filename = [dirEnum nextObject])) {
                if ([filename hasPrefix:@"."]) continue; // Skip .DS_Store and other system files
                NSString *filePath = [path stringByAppendingPathComponent:filename];
                if ([dirEnum.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) {
                    [dirEnum skipDescendants];
                    
                    ICACloudDirectory *dir = [[ICACloudDirectory alloc] init];
                    dir.name = filename;
                    dir.path = filePath;
                    [mutableContents addObject:dir];
                }
                else {
                    ICACloudFile *file = [ICACloudFile new];
                    file.name = filename;
                    file.path = filePath;
                    file.size = dirEnum.fileAttributes.fileSize;
                    [mutableContents addObject:file];
                }
            }
            
            if (!fileManagerError) contents = mutableContents;
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(contents, error);
        });
    }];

}

- (void)createDirectoryAtPath:(NSString *)path completion:(void(^)(NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block([self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        [coordinator coordinateWritingItemAtURL:url options:0 error:&fileCoordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            [fileManager createDirectoryAtPath:newURL.path withIntermediateDirectories:YES attributes:nil error:&fileManagerError];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(error);
        });
    }];
}

- (void)removeItemAtPath:(NSString *)path completion:(void(^)(NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block([self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;

        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForDeleting error:&fileCoordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            [fileManager removeItemAtPath:newURL.path error:&fileManagerError];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(error);
        });
    }];
}

- (void)uploadLocalFile:(NSString *)fromPath toPath:(NSString *)toPath completion:(void(^)(NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block([self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;

        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        NSURL *fromURL = [NSURL fileURLWithPath:fromPath];
        NSURL *toURL = [NSURL fileURLWithPath:[self fullPathForPath:toPath]];
        [coordinator coordinateReadingItemAtURL:fromURL options:0 writingItemAtURL:toURL options:NSFileCoordinatorWritingForReplacing error:&fileCoordinatorError byAccessor:^(NSURL *newReadingURL, NSURL *newWritingURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            [fileManager removeItemAtPath:newWritingURL.path error:NULL];
            [fileManager copyItemAtPath:newReadingURL.path toPath:newWritingURL.path error:&fileManagerError];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(error);
        });
    }];
}

- (void)downloadFromPath:(NSString *)fromPath toLocalFile:(NSString *)toPath completion:(void(^)(NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block([self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        NSURL *fromURL = [NSURL fileURLWithPath:[self fullPathForPath:fromPath]];
        NSURL *toURL = [NSURL fileURLWithPath:toPath];
        [coordinator coordinateReadingItemAtURL:fromURL options:0 writingItemAtURL:toURL options:NSFileCoordinatorWritingForReplacing error:&fileCoordinatorError byAccessor:^(NSURL *newReadingURL, NSURL *newWritingURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            [fileManager removeItemAtPath:newWritingURL.path error:NULL];
            [fileManager copyItemAtPath:newReadingURL.path toPath:newWritingURL.path error:&fileManagerError];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(error);
        });
    }];
}

@end